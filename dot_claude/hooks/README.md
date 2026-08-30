# chezmoi-guard (Claude Code native hook)

A single `bun` dispatcher (`chezmoi-guard.ts`) wired into four Claude Code hook
events. It is the Claude Code port of the opencode in-process plugin
(`~/.config/opencode/plugins/chezmoi-guard.ts`) and the codex native-hook port
(`~/.codex/hooks/chezmoi-guard.ts`). It keeps chezmoi the source of truth for
tracked dotfiles by hard-blocking direct edits to managed files and nudging the
agent to commit + push its chezmoi source changes before it stops.

The script is invoked fresh per hook call as
`/Users/mackhaymond/.bun/bin/bun /Users/mackhaymond/.claude/hooks/chezmoi-guard.ts`,
reads the hook JSON from stdin, and branches on `hook_event_name`.

## Behaviors

| Event | Matcher | Behavior |
|---|---|---|
| **PreToolUse** | `Edit\|Write\|MultiEdit\|NotebookEdit\|Bash\|mcp__pty__run\|mcp__pty__spawn_pty` | HARD-BLOCK (1) edit-class tools targeting a chezmoi-**managed** path (exact match), (2) shell commands that write to a managed live file (prefix-aware), and (3) destructive / history-rewriting git against the chezmoi source repo (see the git-hazard table below). Emits `permissionDecision:"deny"`. |
| **PostToolUse** | `Edit\|Write\|MultiEdit\|NotebookEdit\|Bash\|mcp__pty__run\|mcp__pty__spawn_pty` | Bookkeeping. Remembers chezmoi-**source** writes this session made and recomputes the dirty set via `git status` (self-healing). Also runs the managed-set TTL refresh. Empty stdout. |
| **UserPromptSubmit** | *(none)* | If session-touched chezmoi source paths are still uncommitted, injects an "uncommitted chezmoi changes" complaint as `additionalContext`. Per-turn analog of opencode's `system.transform`. Also runs the managed-set TTL refresh. |
| **Stop** | *(none)* | If session-touched chezmoi paths are still dirty, blocks the stop with a continuation prompt (`{"decision":"block","reason":...}`) telling the agent to commit + push. Loop-guarded. Also runs the managed-set TTL refresh. |

The shell tools are the built-in `Bash` **and** the MCP pty shell
(`mcp__pty__run`, `mcp__pty__spawn_pty`) — on this machine `Bash` is
deny-listed and every shell command goes through `mcp__pty__run`, so the
matcher must name it or the shell guard never runs. `mcp__pty__send_keys` is
not matched (its `keys`/`text` are keystrokes, not a command line).

### Block detail

- **Edit-class** (`Edit`/`Write`/`MultiEdit` -> `file_path`; `NotebookEdit` ->
  `notebook_path`, with a forward-compat fallback to `file_path`): **exact**
  match against the managed-files set. Never prefix — prefix would over-block
  directories.
- **Shell write targets**: **prefix-aware** match (`managed.has(p)` or any
  managed path under `p/`), gated by write-intent heuristics (`>`, `tee`, `cp`,
  `mv`, `rm`, `dd of=`, etc.). `sed`/`perl`/`ruby`/`awk` count as writes ONLY
  with an in-place flag (`sed -i`/`--in-place`, `perl -i`/`-pi`, `ruby -i`,
  `awk -i inplace`) or a `>` redirect at the managed path — bare `sed -n`,
  `awk '{print}' file`, `perl -ne`, `perl -Mstrict`, `ruby -Ilib` are reads
  and pass, and a later `| grep -i` cannot be mistaken for the editor's flag.
  BSD `sed -i ''`'s empty backup-suffix operand is skipped (it is not a
  target; it used to normalize to the cwd and deny everything under `$HOME`).
  Relative paths resolve
  against the hook's top-level `cwd`: neither CC's `Bash` nor `mcp__pty__run`
  carries a per-call workdir, and the persistent pty shell's real cwd is
  unknown to the hook (a relative write after a `cd` inside the pty can be
  misattributed; absolute/`~` paths and `cd <dir> && ...` chains are fine).
- **Git hazard**: aimed at the chezmoi source repo via `git -C <src>`,
  `--git-dir=`/`--work-tree=`, `GIT_DIR=` env, `chezmoi git -- ...`, the
  workdir, or `cd <src> && git ...`:

  | Blocked | Allowed |
  |---|---|
  | `reset`, `rebase`, `merge` (any form) | `add`, `commit`, non-force `push` |
  | `push --force` / `--force-with-lease` / `+ref` / `--mirror` | `status`, `diff`, `log`, `show` |
  | `restore` (any form) | `checkout <branch>`, `checkout -b <name>`, `checkout HEAD~1` |
  | `checkout -- <path>`, `checkout .`, `checkout <path-like>`, `checkout -f`/`-p`, `checkout <treeish> -- <path>`, `checkout HEAD .` | `clean -n` / `--dry-run` (anywhere in the command, incl. `-nd` / `-n -d`) |
  | `clean -f` / `-d` / `-x` / `--force` (without a dry-run flag) | `stash list`, `stash show` |
  | `stash` (push/pop/apply/drop/clear/bare — anchored to the subcommand, so `stash push -m 'list'` is still blocked) | `switch <branch>`, `switch -c <name>` |
  | `switch -f` / `--force` / `--discard-changes` | |
  | `commit --amend` | |

  "Path-like" for `checkout` means `.`, `./x`, `~`, anything containing `/`, or
  anything with a file extension — a branch named `feature/x` is therefore
  blocked too (conservative; the deny message says so). Other repos are never
  touched by this layer.

### Fail-open

Any parse/read/handler error -> exit 0 with empty stdout (tool allowed). The two
hard blocks depend only on `(tool_input, managed.json)` and never on session
state, so a corrupt/locked session file cannot weaken a block. A broken
bun/chezmoi binary disables the guard silently (by design — never wedge the
agent).

## State files

All runtime state lives under **`/Users/mackhaymond/.claude/.chezmoi-guard/`**
(created lazily; fully disposable; separate from CC's own `~/.claude` state and
from the codex `~/.codex/.tmp/chezmoi-guard` dir — they never share state).

| Path | Purpose |
|---|---|
| `chezmoi-guard.log` | Append-only best-effort debug log (never throws). Rotated once to `chezmoi-guard.log.1` (overwritten) when it exceeds 1 MB. Only deny / continuation / refresh / error lines are written by default; set `CHEZMOI_GUARD_DEBUG=1` in the hook's environment to also get the per-tool-call `pretool`/`posttool`/`userpromptsubmit` lines. |
| `chezmoi-guard.log.1` | Previous log generation. |
| `managed.json` | Managed-set cache `{ version, loadedAt, everLoaded, paths[] }`. TTL 300s steady / 15s cold. `everLoaded` latches true after the first success; a transient failure preserves stale paths and only advances the clock. **Who refreshes it**: PostToolUse, UserPromptSubmit and Stop each check the TTL and re-run `chezmoi managed` when it has lapsed (logged as `managed set refreshed`). PreToolUse only ever reads the cache (it spawns solely on a genuine cold start), so the block decision never waits on a refresh; a file added to chezmoi is guarded within ~5 min of the next tool call. |
| `managed.refresh.lock/` | `mkdir`-based de-dupe lock around the `chezmoi managed` spawn (avoids a cold-start herd). |
| `sessions/<key>.json` | Per-session state `{ version, touchedPaths[], continuationFiredAt, continuationCount, updatedAt }`. `key = sanitize(session_id) + "-" + sha256(session_id)[:16]`. |
| `sessions/<key>.lock/` | Per-session `mkdir` lock + `holder.json {pid,ts}`. Safe stale-break when age > 3s AND the holder pid is dead. |
| `*.tmp` | Orphaned atomic-write temp files (GC'd after 5 min). |

**Subagents share the parent `session_id`**, so parent + N subagents all read and
write the SAME `sessions/<key>.json`. This is intended: the parent Stop sees
dirty paths created by subagents. Continuation enforcement happens ONLY at
top-level **Stop** — `SubagentStop` is deliberately **not** registered (a
subagent cannot meaningfully commit/push mid-parent-task).

**GC**: every invocation runs an opportunistic, best-effort GC that removes
`*.tmp` orphans older than 5 min and `sessions/*.json` older than 7 days. Live
sessions are never touched. Deleting `STATE_DIR` forces a cold managed-set
re-fetch (<=15s) and drops continuation history — nothing else.

## Binaries (hardcoded)

- `bun`: `/Users/mackhaymond/.bun/bin/bun` (all four hook commands).
- `chezmoi`: `/opt/homebrew/bin/chezmoi`, with a PATH fallback to bare `chezmoi`.
  The interactive shell `chezmoi` function wrapper is absent in the
  non-interactive hook subprocess, so the real binary is resolved directly.
- `git`: `/usr/bin/git`.

If `bun` relocates, all four hooks silently fail-open and must be updated
together in `~/.claude/settings.json`.

## Configuration

The four hook groups live in `~/.claude/settings.json` under the `hooks` key.
**Do not edit the live file** — it is generated by the chezmoi `modify_`
script `dot_claude/modify_settings.json.tmpl` (chezmoi replaces the whole
`hooks` key on apply; Claude's own runtime keys like `model`/`effortLevel`
are passed through). Edit the JSON block in that script and `chezmoi apply`.
See OPERATIONS.md, "`modify_` files".

## Activation (manual — do NOT bypass)

Editing `settings.json` does **not** make these hooks fire immediately. Newly
added hook commands are held for review as an anti-tampering safeguard. To
activate, do **one** of:

1. **Restart the Claude Code session** (quit and relaunch), or
2. Run **`/hooks`** in Claude Code and review/approve the new chezmoi-guard
   entries.

Do not run anything that auto-trusts, auto-restarts, or programmatically
dismisses the hooks review — that approval is owned by you.

After activating, confirm with:

```
tail -f /Users/mackhaymond/.claude/.chezmoi-guard/chezmoi-guard.log
```

You should see a `managed set refreshed` line within a few tool calls (and
`deny ...` lines when a block fires). Per-tool-call `pretool`/`posttool` lines
only appear with `CHEZMOI_GUARD_DEBUG=1`.

Changing a hook's **matcher** in `settings.json` (e.g. adding `mcp__pty__run`)
is subject to the same hold-for-review: approve via `/hooks` or restart.
