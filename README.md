# STATE.md for Claude Code

A tiny, self-contained practice that stops Claude Code sessions from re-reading your whole repo just to remember what the project is and where it left off.

One file per project — `STATE.md` at the root — holds the current state: what's built, what changed recently, what's unfinished. Two hooks keep it useful automatically:

- **On session start** (and after `/clear` or `/compact`), the repo's `STATE.md` is injected into context, so the model starts already oriented.
- **On stop**, if files changed since `STATE.md` was last written, the model is sent back once to update it — so the summary can't silently rot.

It's a single install script that sets up user-level hooks, so it applies to every project you open Claude Code in. No dependencies beyond what's already on your machine.

## Why

A long-running project accumulates state that lives nowhere durable: which components exist, the decisions you'd otherwise re-litigate, what's half-finished. Without a summary, each new session rediscovers it by reading files — burning tokens and time on reorientation before any real work starts.

`STATE.md` front-loads that summary (capped at ~80 lines) plus an instruction to answer project questions from it and open files only to edit them or when the summary is silent or stale on the exact point. A freshness/staleness flag on every injection is what makes it trustworthy enough to rely on.

## Benchmark

Two identical read-only agents were given the same two questions about the same unfamiliar ~production Python codebase (its working context lived in a ~700-line context file plus a README, and one question's answer lived in a 1,100-line module). One agent had a `STATE.md` injected; the other had nothing and had to explore.

| Metric | Without STATE.md | With STATE.md |
|---|---|---|
| Tokens used | 50,882 | **12,052** |
| Wall-clock | 70.6 s | **18.5 s** |
| Files opened | 6 | **0** |
| Answer correctness | correct | correct |

**~76% fewer tokens and ~4× faster, with no loss of correctness** on the everyday "what is this / what's the state / what's left" reorientation.

Honest caveat: a summary is only as detailed as what you write into it. For a question needing an exact constant or line number, the model should — and does — fall back to a single targeted file read. `STATE.md` shines at reorientation, not at replacing the code.

## Install

```bash
bash install-state-md.sh              # install or update
bash install-state-md.sh --uninstall  # remove hooks, the CLAUDE.md block, and helper files (your STATE.md files are left alone)
```

Then restart any open Claude Code sessions (hooks load at startup) and run `/hooks` to confirm the two entries.

It writes only under `~/.claude`:

- `~/.claude/hooks/state-inject.sh` — SessionStart hook
- `~/.claude/hooks/state-check.sh` — Stop hook
- `~/.claude/hooks/state-init.sh` — helper to create a `STATE.md` from the template
- `~/.claude/templates/STATE.md` — the template
- `~/.claude/CLAUDE.md` — a short block between `<!-- state-md:begin/end -->` markers
- `~/.claude/settings.json` — the two hook entries, merged in (a timestamped backup is written alongside; your other hooks are kept)

## Usage

In a git repo, it just works — create the file and fill it in:

```bash
~/.claude/hooks/state-init.sh    # scaffold STATE.md from the template
# then ask Claude to fill in "What exists" from what it knows, or write it yourself
```

Works in **non-git project folders** too — any folder that already has a `STATE.md`, or one you opt in with an empty marker:

```bash
touch .state-md-on     # treat this non-git folder as a project
touch .state-md-off    # opt back out
```

In git repos, change detection uses `git status`; in non-git folders it falls back to comparing file modification times (pruning `node_modules`, `.venv`, `__pycache__`, `dist`, `build`, and similar). Random directories with neither a `STATE.md` nor a marker stay completely silent, so they cost nothing.

Opt a git repo out at any time:

```bash
touch "$(git rev-parse --git-dir)/state-md-off"
```

## Tuning

Set these in your shell profile:

- `STATE_MD_MAX_LINES` — injection cap (default 80)
- `STATE_MD_GIT_LOG` — lines of `git log` to include on startup/clear (default 10; `0` disables)
- `STATE_MD_GRACE_SECONDS` — files written within this many seconds *after* STATE.md count as the same close-out
  batch and don't trigger the Stop nudge (default 180). Later changes still do.

## The template

```markdown
# STATE — {{PROJECT}}
Updated: {{DATE}} · one line: what this project is and who it's for

## What exists
- one line per component: what it does, entry point, status (done / partial / stub)

## Key decisions
- only the ones a future session would otherwise re-litigate, with the reason

## Recent changes
- newest first, keep the 5 most recent

## Unfinished / next
- [ ]

## Gotchas
- non-obvious things that bit us here; conventions belong in CLAUDE.md
```

Keep it under ~80 lines. `STATE.md` holds state, `CLAUDE.md` holds rules — don't copy between them.

## How it works

The hooks are plain Bash and read Claude Code's hook JSON from stdin. `state-inject.sh` prints the `STATE.md` (whole-line HTML comments stripped so the template guidance costs no tokens) with a freshness header; on startup/clear it also appends a short `git log`. `state-check.sh` compares changed files against `STATE.md`'s mtime and, at most once per session, asks the model to update the file before stopping. Everything is inspectable — read the script before you run it.

## License

MIT — see [LICENSE](LICENSE).
