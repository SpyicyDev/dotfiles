# Agent tab indicator

Each tmux tab (window) reflects the state of the AI agent (Claude Code or
Codex CLI) running inside it, rendered through the Catppuccin status bar:

Each tab carries **three independent channels**:

| Channel | Surface | Says |
|---|---|---|
| **number chip** | `@catppuccin_window_*_color` | *motion* — is this window in flight? |
| **tab body** | `@catppuccin_window_*_background` | *attention tier* — does it want you? |
| **glyph slot** | `@catppuccin_window_*_text` | *the exception* — a job the chip can't describe |

State by state (unselected tab):

| State | Trigger | Chip | Body | Glyph |
|---|---|---|---|---|
| *(none)* | no agent process in the window | blue, solid | stock | — |
| `idle` | agent open, not working | blue, solid | stock | — |
| `running` | agent mid-turn | **pink `#f5c2e7` ↔ blue `#89b4fa`, 1 s** | stock | — |
| `running` + cua | agent driving an app | **pink ↔ blue** | stock | blue `󰍽` pulsing |
| *background workflow* | a Claude Workflow still running after the turn ended | **pink ↔ blue** | stock (green "done" tint suppressed — it isn't really finished) | teal `󰒓` pulsing |
| `needs-input` | permission prompt / turn failed | crust (yellow digit) | yellow `#f9e2af` | — |
| `needs-approval` | blocked on a permission decision | crust (red digit) | red `#f38ba8` | — |
| `done` | turn finished | crust (green digit) | green `#a6e3a1` | — |
| any | agent has a conversation title | — | — | tab name = `project/short-title`, else `#W` |

**The selected tab never pulses**: solid peach `#fab387` for every ambient state (idle/running/cua/workflow). You are looking at it — the terminal itself is the progress indicator. Attention states still force the chip to crust even when selected, because the digit's fg *is* the bright body tint and needs a dark chip to read; focusing a prompt is not answering it.

**Priorities.** Chip: attention (`needs-*`, `done`) beats motion — a permission prompt raised mid-workflow is a red tab with a *still* chip. `done` + workflow is untinted, so it pulses like any other in-flight window. Glyph: `󰒓` workflow > `󰍽` cua > nothing; on a tinted tab the glyph goes crust and stops pulsing (teal on yellow is unreadable, and a tab at maximum urgency doesn't need a second animation).

There is deliberately **no "an agent lives here" marker** — the old mauve `󰚩` robot is gone, and so is the `●` that marked attention states (the body tint already says it, in three distinguishable hues; the same dot on all three added nothing but 2 cells). An idle agent tab is just a stock blue tab; presence stays legible from the tab *name*, which reads `project/short-title` for agent windows and `#W` (zsh, nvim…) for everything else.

Blue is both catppuccin's resting chip accent and the computer-use hue. On the chip blue reads as "at rest", so the pink↔blue pulse reads as working↔resting rather than as a third state — and computer use moves to the `󰍽` glyph. Glyphs still never blink between two hues (they'd read as another state mid-pulse); only the chip does, and only because its second hue means "nothing happening".

Tabs are **not** width-stabilised: the glyph slot's 2 cells appear and vanish with the workflow/cua flags. Those flip once per workflow rather than once per turn, so reserving a blank on every agent window would pad the common case to pay for the rare one.

**Seen-it semantics:** focusing a tinted tab discharges it to `idle`
(`after-select-window` → `clear-current`). `done` additionally isn't tinted
if a client is already watching its window (`#{window_active_clients}` > 0 —
you saw it finish). `needs-input` is *always* asserted, even on the focused
window: focusing a prompt is not answering it, so a prompt is never silently
lost by switching away before you respond.

## Architecture

Two per-window tmux user options are the single source of truth:

- `@agent_state` — `idle | running | needs-input | done` (unset = no agent)
- `@agent_summary` — short conversation title
- `@agent_workflow` — `1` while a background Claude Workflow is in flight (else unset); set by the watcher, orthogonal to `@agent_state`

Three components maintain and render them:

### 1. `scripts/agent-tab-indicator.sh` (event-driven)

Invoked as `agent-tab-indicator.sh <mode> <agent>` with the hook's JSON
payload on stdin. Hook processes are children of the agent, so
`TMUX_PANE` identifies the agent's window. Wired into:

**Claude Code** (`~/.claude/settings.json`):

| Hook | Mode |
|---|---|
| `SessionStart` | `idle` (skips `source=compact` — fires mid-turn; a fresh session shows `project/New Session` until the first turn titles it) |
| `UserPromptSubmit` | `running` |
| `PostToolUse` | `heartbeat` (re-arms `running` *only* from `running`/`needs-input`, so a late tool call can't resurrect a finished tab; never reads stdin — `tool_response` can be huge) |
| `PermissionRequest`, `Notification` (matcher `permission_prompt`), `StopFailure` | `needs-input` |
| `Stop` | `done` |
| `SessionEnd` | `clear` (skips reasons `clear`/`resume` — a new SessionStart follows) |

Note: only `permission_prompt` notifications tint the tab — Claude's
`idle_prompt` (fired after ~60 s of waiting) is deliberately *not* wired, so
a finished tab stays `done`/green rather than escalating to yellow.

**Codex** (`~/.codex/hooks.json` — native hooks; the legacy `notify` slot
stays untouched for SkyComputerUseClient): `SessionStart` (matcher
`startup|resume`) → `idle`, `UserPromptSubmit` → `running`, `PostToolUse` →
`heartbeat`, `PermissionRequest` → `needs-approval`, `Stop` → `done`,
`SessionEnd` → `clear` (best-effort — codex clamps its SessionEnd hook
timeout to 3s; the watcher still backstops cleanup). **Codex requires
interactive trust approval for new or edited hook entries** — run `codex`
and accept the "Hooks need review" prompt (or `/hooks` in the TUI). Until
approved the hooks silently don't fire (even under `codex exec`) and codex
windows only get watcher-driven `idle` presence. Codex 0.148 hook events:
PreToolUse, PermissionRequest, PostToolUse, PreCompact, PostCompact,
SessionStart, SessionEnd, UserPromptSubmit, SubagentStart, SubagentStop,
Stop — no `Notification`/`StopFailure`, so codex `needs-input` never fires;
its only blocked state is the red `needs-approval`.

Subagent-context events (payload has `agent_id`) are ignored so a
subagent's Stop can't flip the main agent's tab. Codex background threads
(subagents, review/guardian workers, the Memory Writing Agent) fire the
same hooks from the same process — the script drops events whose
`session_id` maps to a non-`user` `thread_source` in
`~/.codex/state_5.sqlite`, plus any prompt opening with "You are a Memory
Writing Agent" (codex 0.147's memory writer repainted tabs as "Memory
Writing" through exactly that hole). Hooks that arrive with no `TMUX_PANE`
are dropped outright — the old active-window fallback let pane-less codex
contexts (ChatGPT-app threads) paint whatever tab the user was looking at.

**Summary sources** (best first): Claude — last `ai-title` entry in the
transcript tail (`transcript_path` from the payload), else `session_title`,
else the submitted prompt; Codex — `threads.name` from
`~/.codex/state_5.sqlite` keyed by `session_id` (0.148 stopped writing
`session_index.jsonl`), else `threads.title` (the first user message,
treated as interim), else the prompt.
Sanitized (no `#`/`"`/`%`, one line, ≤60 chars). `extract_summary` tags its
output `final\t<title>` (the agent's own conversation title) or
`interim\t<title>` (the prompt, standing in until that title exists) — only
`final` is worth a model call, see below.

**Tab name format**: `project/short-title`. Project is the basename of the
hook's `cwd` (`~` for `$HOME`). The raw title is condensed to its 2–4 most
identifying words by a detached `copilot -p …` call (answer on stdout, stats
footer on stderr; a plain text prompt grants no tool permissions) and cached
in `~/.cache/agent-tab/titles.tsv` keyed by title hash. The model's output is
**validated** before caching (1–4 words, no colon/sentence punctuation, not an
apology/refusal/auth-error) so error strings can't poison the cache; a
failed/rejected condense writes a negative row that backs off retries for
`NEG_TTL` (600 s) instead of re-calling every turn. Until the condensation
lands (or if `copilot` fails), the tab shows `project/<raw title>`
(word-trimmed to 24 cells) as an interim.

**One condense per session.** Only a `final` title is condensed. The prompt
fallback was condensed too, which cost a *second* call every session for one
turn of prettier tab: the agent writes its real title during turn 1, and that
title hashes to a different cache key, so the prompt's label was thrown away
almost immediately — and it was distilled from the weaker source. So turn 1
now shows `project/<prompt>` verbatim and the short label lands once the real
title exists (typically that same turn's `Stop`). The cache read still happens
for interim titles, so a repeated prompt — or one condensed by an older
version — is reused for free.

**Model pin is best-effort.** `--model` is set from `CONDENSE_MODEL`
(default `claude-haiku-4.5`, override with `$AGENT_TAB_CONDENSE_MODEL`, empty
= always copilot's default). copilot's whitelist tracks the CLI version and
the account's entitlements, and a pin that disappears fails *every* condense —
CLI 1.0.75 rejected `claude-haiku-4.5` with `Model "…" is not available`, so
tabs sat on their raw interim titles and the cache filled with negatives. That
reads as "the renamer is slow" when it is actually dead, so the failure is now
recoverable: on a rejection the condenser retries immediately on copilot's
default model and touches `$TMPDIR/agent-tab-model-unavailable.$UID`, which
makes later runs skip the doomed call for 24 h (`MODEL_SKIP_TTL`) before
re-probing the pin.

### 2. `scripts/agent-tab-watcher.sh` (presence daemon)

Singleton, spawned from tmux.conf, polls every 1 s (doubling as the
running-glyph blink driver — it toggles the global `@agent_blink` option
each tick while any window is running). The singleton guard is
ownership-aware: each start reaps any prior instance (by PID file, plus a
`pgrep` sweep for stragglers whose PID file was lost — two live daemons would
both toggle `@agent_blink` per tick and cancel each other out) and only clears
the PID file if it still owns it, and signal traps route through `exit` so
`kill` actually stops the daemon — every `prefix r` reload converges back to
one watcher (the naive check-then-write version leaked a daemon per reload). It
matches agent processes to windows by TTY (`ps -o comm` basename
`claude`/`codex`, plus the bare `N.N.N` pattern — Claude's binary is
version-named and `#{pane_current_command}` reports that, so formats can't
detect presence). Reconciles:

- agent present, no state → seed `idle`
- no agent, state **or** summary set → unset both options (covers SIGKILL,
  `kill-pane`, crashes — SessionEnd is best-effort and codex has none; the
  summary is read separately so an orphaned title written by a slow
  condenser after the agent died is still reaped)

Hook-set states are never overridden while the agent lives. Known
limitation: a one-shot `claude -p` exits right after `Stop`, so its `done`
tint is GC'd within ~1 s. Per-window state also means two agents in one
window share a single state (last writer wins).

**Liveness.** The daemon is the single point of failure for the blink, the
workflow gear and the GC, and its death is silent — a frozen pulse is the only
tell, and it is now easy to *miss*: `@agent_blink` unset renders as the second
color of each pair, and for the chip that is plain blue — i.e. a dead watcher
makes every running tab look idle rather than looking broken. (A workflow gear
freezes on dim teal.) Two guards: it no longer
exits on the first failed tmux command (a transient failure is not a dead
server — it tolerates a streak and quits only once `tmux list-sessions`
confirms the server is gone), and `agent-tab-indicator.sh` re-asserts it on
every hook invocation (PID-file + `kill -0`; respawn via `tmux run-shell -b`
so it lands under the server, not under the hook process). So a death now
self-heals at the next agent event instead of persisting until `prefix r`.

**Background-workflow awareness** (Claude only — codex has no workflows): a
backgrounded Workflow keeps running after the main turn's `Stop` fires, and
there's no hook for it. But the Workflow runtime writes a live dir
`~/.claude/projects/<proj>/<session>/subagents/workflows/wf_<id>/` and only
writes the completion file `…/workflows/wf_<id>.json` when it finishes — so a
workflow is in flight iff its runtime dir exists *without* that completion
file. Each tick the watcher maps each claude window pane → pid →
`~/.claude/sessions/<pid>.json` → sessionId/cwd → that session's workflow
dirs, and sets/clears the per-window `@agent_workflow` flag (with a 600 s
recency backstop on the agent transcript mtime against a crashed-mid-run
dir). The blink driver also toggles while any workflow is in flight, not just
while a window is `running`.

### 3. Rendering (`tmux.conf`, Catppuccin v0.2.0)

Catppuccin builds `window-status-format` **once at load** from **global**
options — per-window `@catppuccin_*` overrides are impossible. Instead the
global `@catppuccin_window_default_background` / `_current_background`
options are set to a nested `#{?…}` conditional on `#{@agent_state}`.
Catppuccin pastes that string into all four tab segments that use
`$background` (number fg, middle-sep bg, text bg, right-sep fg), so the
whole tab tints consistently at render time. Constraints: the expression
must be space-free and quote-free (catppuccin's option reader splits on
spaces and strips quotes); tmux expands conditionals inside `#[…]` style
blocks (verified on tmux 3.6b).

Side effect of `fill=number`: the window NUMBER's fg is that same
expression, which would render a pastel digit on the blue/orange accent
(WCAG contrast 1.2–1.7 — illegible). The companion
`@catppuccin_window_*_color` conditionals darken the accent to crust
`#11111b` on attention states so the state-colored digit reads against it.

`@catppuccin_window_*_color` is also the number chip's *background*, which is
what makes it the motion channel: `_default_color` resolves to
`#{?#{@agent_blink},#f5c2e7,#89b4fa}` whenever the window is in flight
(`@agent_workflow` ‖ `@agent_cua` ‖ state `running`), and to plain `#89b4fa`
otherwise. `_current_color` has no blink branch at all — that is the whole
implementation of "the selected tab never pulses". Both keep the crust
override on attention states, which is checked *first* so attention beats
motion. Contrast holds on both phases: the unselected digit is surface0
`#313244` on pink (8.2:1) and on blue (6.5:1).

**Why pink and not mauve** (changed 2026-08-19): the first cut pulsed mauve
`#cba6f7` ↔ blue and read as too subtle — mauve and blue have near-identical
relative luminance (0.467 vs 0.449) and sit in the same blue-violet family, so
the pulse moved *hue only*. Pink is L 0.638: a 1.42:1 brightness step on top of
a ~100° hue swing, so the chip visibly lightens as well as shifts. It is also
the only mocha hue still free — lavender/sky/sapphire are the blue family
(mauve's failure, worse) and rosewater/flamingo/maroon are the red family.
Pink sits 27° from needs-approval red `#f38ba8`, which sounds close but cannot
collide: attention states force the chip to crust, so a red chip and a pink
chip never exist on the same surface (and pink is far lighter, 0.638 vs 0.404).

The text options add the exception glyph (teal `󰒓` workflow, blue `󰍽` cua,
nothing otherwise; crust and unpulsed on a tinted tab), a readable fg on bright
backgrounds (crust `#11111b`), and the summary with `#W` fallback:
`#{?#{n:#{@agent_summary}},#{@agent_summary},#W}`. The summary is
pre-shortened by the indicator script, so there is no render-side
truncation.

`rename-window` is deliberately **not** used for titles: it disables
`automatic-rename` per window and tmux-resurrect persists both the stale
name and that flag across restores. User options aren't saved by resurrect,
so stale summaries simply vanish.

## Troubleshooting

- **Tab stuck in a state, running tabs never pulse (they just look idle) / the
  workflow gear never appears** → the watcher is dead. All three symptoms have
  one cause; check
  with `pgrep -lf agent-tab-watcher`. Any agent hook now respawns it
  automatically (see *Liveness* above); to force it, `tmux run-shell -b "bash
  ~/.config/tmux/scripts/agent-tab-watcher.sh"` or reload with `prefix r`.
  Confirm it is driving the animation: `for i in 1 2 3 4; do tmux show -gv
  @agent_blink; sleep 0.5; done` should print alternating pairs — sampling on a
  whole-second boundary reads the same value twice and looks stuck.
- **Codex tabs only ever show idle** → hook trust not granted; run `codex`
  and approve, or check `[hooks.state]` entries in `~/.codex/config.toml`.
  (Installing the entries reserialized `hooks.json` — whitespace/`\/`
  escaping changed but existing groups kept their content and indices, so
  established trust hashes should survive; if codex unexpectedly re-prompts
  for chezmoi-guard/NotchBar, re-approving once is safe. Pre-merge backup:
  `~/.codex/hooks.json.bak-agent-tab`.)
- **No summary on a fresh Claude session** → no `ai-title` yet; the first
  prompt is used as fallback, the real title appears on later events.
- **Tabs keep the long raw title (renamer never shortens them)** → the
  condense is failing, not lagging. Check for negative rows piling up:
  `awk -F'\t' '$2==""' ~/.cache/agent-tab/titles.tsv | tail`. Then run one by
  hand — it prints copilot's own error:
  `bash ~/.config/tmux/scripts/agent-tab-indicator.sh condense @1 proj "some test title"`
  and `copilot -p hi --model "$AGENT_TAB_CONDENSE_MODEL"`. A dead pin
  self-heals onto the default model (see *Model pin* above); `rm
  $TMPDIR/agent-tab-model-unavailable.$UID` forces an immediate re-probe.
  Purge stale negatives with
  `awk -F'\t' '$2!=""' titles.tsv > t && mv t titles.tsv`.
- **Wrong/garbled tab title stuck** → a bad condense may be cached. Clear it
  with `rm ~/.cache/agent-tab/titles.tsv` (rebuilds on the next agent event);
  a single bad title backs off for 600 s on its own (`NEG_TTL`).
- **Inspect state**: `tmux list-windows -a -F '#{window_id} #{@agent_state} #{@agent_summary}'`
- All files are chezmoi-managed: edit the **source** under
  `~/.local/share/chezmoi/dot_config/tmux/…`, then `chezmoi apply`. Note the
  scripts are `executable_*.sh` and the rendering lives in `tmux.conf.tmpl`
  (a chezmoi *template*) — use `chezmoi source-path <deployed-file>` to find
  the source for any of them. (`~/.claude/settings.json` and
  `~/.codex/hooks.json` are *not* chezmoi-managed.)
