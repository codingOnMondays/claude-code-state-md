#!/usr/bin/env bash
# install-state-md.sh — the STATE.md practice for every project on this machine (Claude Code, macOS/Linux).
#
#   bash install-state-md.sh              install or update
#   bash install-state-md.sh --uninstall  remove hooks, CLAUDE.md block, and helper files (repos' STATE.md files are left alone)
#
# What it sets up (all user-level, so it applies to every directory you open Claude Code in):
#   ~/.claude/hooks/state-inject.sh   SessionStart hook: injects STATE.md (≤80 lines, comments stripped) on startup/resume/clear/compact,
#                                     plus a 10-line git log only on startup/clear (git repos only). Works in non-git project
#                                     folders too: any folder with a STATE.md, or one opted in with a .state-md-on marker.
#   ~/.claude/hooks/state-check.sh    Stop hook: if files changed after STATE.md was last written, sends Claude back once to update it.
#                                     Never fires on turns that used no tools.
#   ~/.claude/hooks/state-init.sh     helper: creates STATE.md in the current repo from the template.
#   ~/.claude/templates/STATE.md      the template.
#   ~/.claude/CLAUDE.md               a short block between <!-- state-md:begin/end --> markers (replaced on re-install).
#   ~/.claude/settings.json           the two hook entries (merged; your other hooks are kept).
#
# Opt a git repo out:      touch "$(git rev-parse --git-dir)/state-md-off"
# Opt a non-git folder in: touch .state-md-on      (and back out with: touch .state-md-off)
# Tune the budget:         export STATE_MD_MAX_LINES=60 STATE_MD_GIT_LOG=0   (in your shell profile)
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS="$CLAUDE_DIR/hooks"
TPL_DIR="$CLAUDE_DIR/templates"
SETTINGS="$CLAUDE_DIR/settings.json"
CMD_FILE="$CLAUDE_DIR/CLAUDE.md"
INJ="\"$HOOKS/state-inject.sh\""
CHK="\"$HOOKS/state-check.sh\""
MODE="${1:-install}"

say() { printf '%s\n' "$*"; }

# ---- settings.json merge / strip (jq → node → python3 → manual) --------------------------------
edit_settings() {   # edit_settings add|remove
  local op="$1" tmp; tmp="$(mktemp)"
  [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
  if command -v jq >/dev/null 2>&1; then
    jq --arg inj "$INJ" --arg chk "$CHK" --arg op "$op" '
      def strip($cmd): map(select(((.hooks // []) | map(.command == $cmd) | any) | not));
      .hooks = (.hooks // {})
      | .hooks.SessionStart = ((.hooks.SessionStart // []) | strip($inj))
      | .hooks.Stop = ((.hooks.Stop // []) | strip($chk))
      | if $op == "add" then
          .hooks.SessionStart += [{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":$inj,"timeout":10}]}]
          | .hooks.Stop += [{"hooks":[{"type":"command","command":$chk,"timeout":15}]}]
        else . end
      | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
      | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    ' "$SETTINGS" > "$tmp"
  elif command -v node >/dev/null 2>&1; then
    INJ="$INJ" CHK="$CHK" OP="$op" node -e '
      const fs=require("fs"),f=process.argv[1],{INJ,CHK,OP}=process.env;
      const s=JSON.parse(fs.readFileSync(f,"utf8")||"{}"); s.hooks=s.hooks||{};
      const strip=(a,c)=>(a||[]).filter(e=>!((e.hooks||[]).some(h=>h.command===c)));
      s.hooks.SessionStart=strip(s.hooks.SessionStart,INJ); s.hooks.Stop=strip(s.hooks.Stop,CHK);
      if(OP==="add"){ s.hooks.SessionStart.push({matcher:"startup|resume|clear|compact",hooks:[{type:"command",command:INJ,timeout:10}]});
                      s.hooks.Stop.push({hooks:[{type:"command",command:CHK,timeout:15}]}); }
      if(!s.hooks.SessionStart.length) delete s.hooks.SessionStart; if(!s.hooks.Stop.length) delete s.hooks.Stop;
      if(!Object.keys(s.hooks).length) delete s.hooks;
      fs.writeFileSync(process.argv[2],JSON.stringify(s,null,2)+"\n");' "$SETTINGS" "$tmp"
  elif command -v python3 >/dev/null 2>&1; then
    INJ="$INJ" CHK="$CHK" OP="$op" python3 - "$SETTINGS" "$tmp" <<'PY'
import json,os,sys
src,dst=sys.argv[1],sys.argv[2]; INJ,CHK,OP=os.environ["INJ"],os.environ["CHK"],os.environ["OP"]
s=json.load(open(src)) if os.path.getsize(src) else {}; h=s.setdefault("hooks",{})
strip=lambda a,c:[e for e in (a or []) if not any(x.get("command")==c for x in e.get("hooks",[]))]
h["SessionStart"]=strip(h.get("SessionStart"),INJ); h["Stop"]=strip(h.get("Stop"),CHK)
if OP=="add":
    h["SessionStart"].append({"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":INJ,"timeout":10}]})
    h["Stop"].append({"hooks":[{"type":"command","command":CHK,"timeout":15}]})
for k in ("SessionStart","Stop"):
    if not h[k]: del h[k]
if not h: del s["hooks"]
json.dump(s,open(dst,"w"),indent=2); open(dst,"a").write("\n")
PY
  else
    rm -f "$tmp"
    say "!! No jq, node, or python3 found, so settings.json was NOT edited. Add this to $SETTINGS by hand:"
    cat <<EOF
{
  "hooks": {
    "SessionStart": [ { "matcher": "startup|resume|clear|compact",
                        "hooks": [ { "type": "command", "command": "$(printf '%s' "$INJ" | sed 's/"/\\"/g')", "timeout": 10 } ] } ],
    "Stop":         [ { "hooks": [ { "type": "command", "command": "$(printf '%s' "$CHK" | sed 's/"/\\"/g')", "timeout": 15 } ] } ]
  }
}
EOF
    return 0
  fi
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
  mv "$tmp" "$SETTINGS"
}

# ---- CLAUDE.md block insert / replace / remove ---------------------------------------------------
edit_claude_md() {   # edit_claude_md add|remove  (block text on stdin for add)
  local op="$1" tmp; tmp="$(mktemp)"; local block=""
  [ "$op" = add ] && block="$(cat)"
  touch "$CMD_FILE"
  BLOCK="$block" awk -v mode="$op" '
    BEGIN { block=ENVIRON["BLOCK"] }
    /<!-- state-md:begin -->/ { skipping=1; if (mode=="add") { print block; seen=1 } next }
    /<!-- state-md:end -->/   { skipping=0; next }
    !skipping { print }
    END { if (mode=="add" && !seen) { if (NR>0) print ""; print block } }
  ' "$CMD_FILE" > "$tmp"
  mv "$tmp" "$CMD_FILE"
}

# ==================================================================================================
if [ "$MODE" = "--uninstall" ]; then
  edit_settings remove
  edit_claude_md remove
  rm -f "$HOOKS/state-inject.sh" "$HOOKS/state-check.sh" "$HOOKS/state-init.sh" "$TPL_DIR/STATE.md"
  rm -rf "${TMPDIR:-/tmp}/claude-state-md"
  say "Removed the STATE.md hooks, CLAUDE.md block, and helper files. STATE.md files inside your repos were not touched."
  exit 0
fi
[ "$MODE" = install ] || { say "usage: bash install-state-md.sh [--uninstall]"; exit 1; }

mkdir -p "$HOOKS" "$TPL_DIR"

cat > "$HOOKS/state-inject.sh" <<'STATE_INJECT_EOF'
#!/usr/bin/env bash
# state-inject.sh — Claude Code SessionStart hook.
# Puts the repo's STATE.md (and, only when context is empty, a short git log) into context.
# Fires on: startup | resume | clear | compact. Plain-text stdout becomes context Claude can see.
#
# Context budget (defaults): STATE.md capped at 80 lines, comments stripped; git log 10 lines
# on startup/clear only. Override with STATE_MD_MAX_LINES / STATE_MD_GIT_LOG (0 disables the log).
set -u

MAX_LINES="${STATE_MD_MAX_LINES:-80}"
GIT_LOG_N="${STATE_MD_GIT_LOG:-10}"

input="$(cat 2>/dev/null || true)"

# json_field <key> — scalar value for a top-level key; jq if present, else a sed fallback.
json_field() {
  local key="$1" v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(printf '%s' "$input" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)"
  else
    v="$(printf '%s' "$input" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"((\\\\.|[^\"\\\\])*)\".*/\1/p" | head -n1)"
    [ -z "$v" ] && v="$(printf '%s' "$input" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*([0-9a-z.-]+).*/\1/p" | head -n1)"
  fi
  printf '%s' "$v"
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }  # GNU first; BSD/macOS falls through

src="$(json_field session_source)"
[ -z "$src" ] && src="$(json_field source)"
[ -z "$src" ] && src="startup"

cwd="$(json_field cwd)"
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
in_git=1
[ -z "$root" ] && { in_git=0; root="$PWD"; }

# Opt-out. Git repos: touch "$(git rev-parse --git-dir)/state-md-off".
# Non-git projects: touch ".state-md-off" at the project root.
if [ "$in_git" = 1 ]; then
  [ -e "$(git rev-parse --git-dir 2>/dev/null)/state-md-off" ] && exit 0
else
  [ -e "$root/.state-md-off" ] && exit 0
fi

state="$root/STATE.md"

if [ ! -f "$state" ]; then
  # Remind once in a git repo, or in a non-git folder explicitly opted in with a
  # .state-md-on marker. Silent in every other directory so random folders cost nothing.
  if [ "$in_git" = 1 ] || [ -e "$root/.state-md-on" ]; then
    echo "No STATE.md here. If you change files in this project, create one from ~/.claude/templates/STATE.md before finishing (see CLAUDE.md)."
  fi
  exit 0
fi

# Strip whole-line HTML comments so template guidance never costs tokens.
content="$(sed -E '/^[[:space:]]*<!--.*-->[[:space:]]*$/d' "$state")"
total="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"

smt="$(mtime "$state")"; smt="${smt:-0}"
now="$(date +%s)"
age_h=$(( (now - smt) / 3600 ))
if   [ "$age_h" -lt 1 ];  then age="<1h ago"
elif [ "$age_h" -lt 48 ]; then age="${age_h}h ago"
else                           age="$(( age_h / 24 ))d ago"; fi

# Staleness: what moved since STATE.md was last written?
stale=""
if [ "$in_git" = 1 ]; then
  commits="$(git log --format=%ct -n 200 2>/dev/null | awk -v t="$smt" '$1 > t' | wc -l | tr -d ' ')"
  dirty=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in STATE.md|.DS_Store|*/.DS_Store) continue ;; esac
    [ -e "$root/$f" ] || continue
    fm="$(mtime "$root/$f")"
    [ "${fm:-0}" -gt "$smt" ] && dirty=$((dirty + 1))
  done < <(git status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.. //; s/^.* -> //; s/^"(.*)"$/\1/')
  if [ "${commits:-0}" = 0 ] && [ "$dirty" = 0 ]; then
    stale="current"
  else
    stale="STALE: ${commits} commit(s) and ${dirty} uncommitted file(s) changed since. Trust it for structure; verify only the specifics that moved"
  fi
else
  # No git: compare file mtimes against STATE.md's, pruning heavy/generated dirs.
  dirty="$(find "$root" \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name env -o -name __pycache__ -o -name site-packages -o -name dist -o -name build -o -name .next -o -name target \) -prune -o -type f -newer "$state" ! -name STATE.md ! -name '.DS_Store' -print 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${dirty:-0}" = 0 ]; then
    stale="current"
  else
    stale="STALE: ${dirty} file(s) changed since STATE.md was written (by mtime). Trust it for structure; verify only the specifics that moved"
  fi
fi

case "$src" in
  compact) why="re-injected after compaction" ;;
  clear)   why="re-injected after /clear" ;;
  resume)  why="session resumed" ;;
  *)       why="session start" ;;
esac

echo "## STATE.md ($why) — updated $age${stale:+; $stale}"
echo "Authoritative for what's built, what changed, and what's unfinished. Answer project questions from this. Open files only to edit them, or when this is silent or flagged stale on the exact point asked."
echo
if [ "$total" -gt "$MAX_LINES" ]; then
  printf '%s\n' "$content" | head -n "$MAX_LINES"
  echo
  echo "[STATE.md is $total lines; only the first $MAX_LINES were injected. Condense it below $MAX_LINES lines when you next update it.]"
else
  printf '%s\n' "$content"
fi

# Git log only when context is actually empty (startup / clear). A resumed session has its
# transcript back and a compacted one has its summary; neither needs the history again.
if [ "$in_git" = 1 ] && [ "$GIT_LOG_N" -gt 0 ] && { [ "$src" = startup ] || [ "$src" = clear ]; }; then
  echo
  echo "## Recent commits"
  git log --oneline -n "$GIT_LOG_N" 2>/dev/null
fi
exit 0
STATE_INJECT_EOF

cat > "$HOOKS/state-check.sh" <<'STATE_CHECK_EOF'
#!/usr/bin/env bash
# state-check.sh — Claude Code Stop hook.
# If files changed after STATE.md was last written, send Claude back ONCE to update it.
#
# Never fires when: the turn used no tools (pure Q&A); the directory is neither a git repo
# nor an opted-in project (no STATE.md and no .state-md-on); it's opted out; or Claude was
# already sent back for this same STATE.md version.
set -u

MAX_LINES="${STATE_MD_MAX_LINES:-80}"
CACHE="${TMPDIR:-/tmp}/claude-state-md"
mkdir -p "$CACHE" 2>/dev/null || CACHE="/tmp"

input="$(cat 2>/dev/null || true)"

json_field() {
  local key="$1" v=""
  if command -v jq >/dev/null 2>&1; then
    v="$(printf '%s' "$input" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)"
  else
    v="$(printf '%s' "$input" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"((\\\\.|[^\"\\\\])*)\".*/\1/p" | head -n1)"
    [ -z "$v" ] && v="$(printf '%s' "$input" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*([0-9a-z.-]+).*/\1/p" | head -n1)"
  fi
  printf '%s' "$v"
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }  # GNU first; BSD/macOS falls through

[ "$(json_field stop_hook_active)" = "true" ] && exit 0   # already continuing because of a Stop hook
tools="$(json_field tool_use_count)"
[ "${tools:-1}" = "0" ] && exit 0                          # no tools used this turn: nothing changed

cwd="$(json_field cwd)"
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null

in_git=1
root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$root" ] && { in_git=0; root="$PWD"; }

# Opt-out (git: <git-dir>/state-md-off; non-git: .state-md-off at root)
if [ "$in_git" = 1 ]; then
  [ -e "$(git rev-parse --git-dir 2>/dev/null)/state-md-off" ] && exit 0
else
  [ -e "$root/.state-md-off" ] && exit 0
fi

state="$root/STATE.md"

# In a non-git dir, only act if this is really a tracked project: STATE.md already
# exists, or it's opted in with .state-md-on. Otherwise a tool-using turn in a random
# folder would nag, so stay silent.
if [ "$in_git" = 0 ] && [ ! -f "$state" ] && [ ! -e "$root/.state-md-on" ]; then exit 0; fi

smt=0
[ -f "$state" ] && smt="$(mtime "$state")"

sid="$(json_field session_id)"; [ -z "$sid" ] && sid="nosession"
marker="$CACHE/$sid"
find "$CACHE" -type f -mtime +3 -delete 2>/dev/null   # housekeeping

# Files written after STATE.md: git status when available, else an mtime scan.
changed=()
if [ "$in_git" = 1 ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in STATE.md|.DS_Store|*/.DS_Store) continue ;; esac
    [ -e "$root/$f" ] || continue
    fm="$(mtime "$root/$f")"
    [ "${fm:-0}" -gt "$smt" ] && changed+=("$f")
  done < <(git status --porcelain --untracked-files=all 2>/dev/null | sed -E 's/^.. //; s/^.* -> //; s/^"(.*)"$/\1/')
elif [ -f "$state" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    changed+=("${f#"$root"/}")
  done < <(find "$root" \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name env -o -name __pycache__ -o -name site-packages -o -name dist -o -name build -o -name .next -o -name target \) -prune -o -type f -newer "$state" ! -name STATE.md ! -name '.DS_Store' -print 2>/dev/null)
else
  # Opted-in project (.state-md-on) with no STATE.md yet: prompt to create one.
  changed+=("(project files)")
fi

[ "${#changed[@]}" -eq 0 ] && exit 0

# One nudge per (session, STATE.md version). If Claude ignores it, don't nag again.
sig="$smt"
if [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$sig" ]; then exit 0; fi
printf '%s' "$sig" > "$marker" 2>/dev/null

n="${#changed[@]}"
list="$(printf '%s, ' "${changed[@]:0:6}")"; list="${list%, }"
[ "$n" -gt 6 ] && list="$list, +$((n - 6)) more"

if [ -f "$state" ]; then
  cat >&2 <<EOF
STATE.md is out of date: $n file(s) changed after it was last written ($list).
Before stopping, update $state in place: refresh "What exists" if anything was added or finished, put this task's change at the top of "Recent changes" (keep 5), and adjust "Unfinished / next". Keep the file under $MAX_LINES lines. You already know what you changed; do not re-read the repo to write this. Then stop.
EOF
else
  cat >&2 <<EOF
This repo has no STATE.md and $n file(s) changed ($list).
Before stopping, create $state from ~/.claude/templates/STATE.md: fill "What exists" from what you know of this project (one line per component, no repo survey), record this task under "Recent changes", note anything unfinished. Keep it under $MAX_LINES lines. Then stop.
EOF
fi
exit 2
STATE_CHECK_EOF

cat > "$HOOKS/state-init.sh" <<'STATE_INIT_EOF'
#!/usr/bin/env bash
# state-init.sh — create STATE.md at the root of the current repo from the template.
# Usage: ~/.claude/hooks/state-init.sh   (run from anywhere inside the repo)
set -eu
TPL="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/templates/STATE.md"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dest="$root/STATE.md"
[ -f "$dest" ] && { echo "STATE.md already exists at $dest"; exit 1; }
[ -f "$TPL" ] || { echo "Template not found at $TPL — run the installer first."; exit 1; }
name="$(basename "$root")"
today="$(date +%Y-%m-%d)"
sed -e "s/{{PROJECT}}/$name/g" -e "s/{{DATE}}/$today/g" "$TPL" > "$dest"
echo "Created $dest — fill in 'What exists' (or ask Claude to, from what it knows)."
STATE_INIT_EOF

cat > "$TPL_DIR/STATE.md" <<'STATE_TEMPLATE_EOF'
# STATE — {{PROJECT}}
Updated: {{DATE}} · one line: what this project is and who it's for

<!-- Hard cap 80 lines. Edit sections in place; never append a log. Whole-line comments like this one are stripped before injection, so they cost nothing. -->

## What exists
<!-- one line per component: what it does, entry point, status (done / partial / stub) -->
- 

## Key decisions
<!-- only the ones a future session would otherwise re-litigate, with the reason -->
- 

## Recent changes
<!-- newest first, keep the 5 most recent -->
- {{DATE}}: STATE.md created

## Unfinished / next
- [ ] 

## Gotchas
<!-- non-obvious things that bit us here; conventions belong in CLAUDE.md -->
- 
STATE_TEMPLATE_EOF

chmod +x "$HOOKS/state-inject.sh" "$HOOKS/state-check.sh" "$HOOKS/state-init.sh"

edit_claude_md add <<'CLAUDE_MD_BLOCK'
<!-- state-md:begin -->
## Project state: STATE.md
- Projects keep a `STATE.md` at the root — git repos automatically, and non-git project folders that either already have a STATE.md or are opted in with an empty `.state-md-on` marker file. It is injected at session start and again after /clear or /compact, and it is the authoritative answer to what's built, what changed recently, and what's unfinished. Answer questions about the project from it. Open files only to edit them, or when STATE.md is silent or flagged stale on the exact point asked, and then look narrowly (grep, one file), not a survey of the project.
- Before finishing any task that changed files, and before any commit, update STATE.md: edit sections in place, keep "Recent changes" to the 5 newest, keep the file under 80 lines. You already know what you changed; don't re-read the project to write it.
- If a project (a git repo, or a non-git folder with a `.state-md-on` marker) has no STATE.md and you've just changed files in it, create one from `~/.claude/templates/STATE.md`.
- STATE.md holds state, CLAUDE.md holds rules, auto memory holds preferences. Don't copy between them.
<!-- state-md:end -->
CLAUDE_MD_BLOCK

edit_settings add

say "Installed."
say "  hooks     $HOOKS/state-inject.sh (SessionStart), $HOOKS/state-check.sh (Stop)"
say "  template  $TPL_DIR/STATE.md"
say "  rules     $CMD_FILE  (block between <!-- state-md:begin/end -->)"
say "  settings  $SETTINGS  (backup written alongside)"
say
say "Next:"
say "  1. Restart any open Claude Code sessions (hooks load at startup). Run /hooks to see the two entries."
say "  2. In a repo: ~/.claude/hooks/state-init.sh, then ask Claude to fill in 'What exists' from what it knows."
say "     Or just say 'create STATE.md' — the CLAUDE.md block tells it how."
say "  3. Opt a repo out any time:  touch \"\$(git rev-parse --git-dir)/state-md-off\""
