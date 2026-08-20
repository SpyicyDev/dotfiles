#!/usr/bin/env bash
# Agent tab indicator v2 — drive per-window tmux options from AI-agent
# lifecycle hooks so the Catppuccin tab bar reflects agent state.
#
# Options written (window scope; unset = no agent in window):
#   @agent_state    idle | running | needs-approval | needs-input | done
#                   (the two needs-* states share every behavior — they differ
#                   only in tint: red = blocked on your approval, yellow =
#                   blocked on your answer. Match them with a needs-* glob,
#                   never by listing one of them.)
#   @agent_summary  "<project>/<ultra-short title>" shown as the tab name;
#                   project = basename of the agent's cwd, title = the
#                   conversation title condensed to its 2-4 identifying
#                   words by a cached background copilot/haiku call
#                   (interim: the raw title until the condensation lands)
#   @agent_summary_cond  1 while @agent_summary holds a condensed label, unset
#                   while it holds raw stand-in text — see compose_summary
#   @agent_pending  epoch stamp: a needs-input window the user focused (went
#                   to answer its prompt). The next heartbeat consumes it to
#                   restore `running` when the answered turn resumes; every
#                   other lifecycle mode clears it so it can't go stale.
#
# Rendering happens entirely in tmux.conf: the Catppuccin window formats
# read these options via #{?…} conditionals (background tint per state,
# glyph, summary-with-#W-fallback). Catppuccin bakes its window formats
# ONCE at load from GLOBAL options, so per-window @catppuccin_* overrides
# can't work — per-window state must flow through user options like these.
#
# Callers:
#   Claude Code hooks (~/.claude/settings.json) and Codex hooks
#   (~/.codex/hooks.json) invoke:  agent-tab-indicator.sh <mode> <agent>
#   with the hook's JSON payload on stdin. Hook processes are children of
#   the agent process, so TMUX/TMUX_PANE identify the agent's pane.
#
#   tmux after-select-window hook invokes:  agent-tab-indicator.sh clear-current
#   (no stdin, no TMUX_PANE → operates on the now-active window).
#
#   agent-tab-watcher.sh (companion daemon) seeds `idle` for hook-less
#   agents and garbage-collects state when the agent process dies — this
#   script never has to handle crashed/killed agents.
#
# Modes:
#   idle         SessionStart        → mark present (skipped for compact
#                                      restarts); a fresh session with no title
#                                      yet shows "<project>/New Session"
#   running      UserPromptSubmit    → turn started; refresh @agent_summary
#   heartbeat    PostToolUse         → re-arm running mid-turn: from
#                                      running/needs-input, or from idle when
#                                      @agent_pending marks an answered
#                                      permission prompt — never from bare
#                                      idle/done, so a late tool call can't
#                                      resurrect a finished tab; skips stdin
#                                      entirely — payloads can be huge
#   needs-approval  PermissionRequest, and Notification(permission_prompt)
#                                    → blocked on a permission decision (red).
#                                      BOTH events describe the SAME gate —
#                                      PermissionRequest is the structural one
#                                      (always fires, carries the tool name),
#                                      the Notification is the "look over here"
#                                      that Claude suppresses while the
#                                      terminal is focused. They mapped to
#                                      different colors until 2026-08-19, so
#                                      one gate painted amber or red depending
#                                      on which event landed (and on focus);
#                                      a permission gate is unambiguously an
#                                      approval, so both are red now.
#   needs-input  StopFailure         → blocked on an answer (yellow): the turn
#                                      itself failed (529, overloaded) and
#                                      wants you to retry — NOT a tool gate.
#                                      Both attention states are always
#                                      asserted (focus ≠ answer) and are
#                                      discharged by the focus hook.
#                                      needs-input still never downgrades a
#                                      standing needs-approval (the guard now
#                                      only covers a StopFailure landing on a
#                                      live gate, but red must still win).
#   done         Stop                → turn finished; refresh @agent_summary;
#                                      not tinted if a client is watching it
#   clear        SessionEnd          → remove state (skipped for clear/resume,
#                                      which are followed by a new SessionStart)
#   clear-current  focus hook        → attention states → idle once seen;
#                                      needs-input also stamps @agent_pending
#
# "Seen-it" semantics: a tinted tab discharges to idle when you focus it
# (clear-current); `done` additionally isn't tinted if its window is already
# being watched. needs-input always tints so a prompt is never lost.
# Answering a permission prompt usually REQUIRES focusing the window, and the
# focus discharge destroys needs-input before any heartbeat can re-arm from
# it — so heartbeat's needs-input path alone left the tab idle for the rest
# of the turn (user-reported desync). The @agent_pending stamp bridges the
# gap: focus-discharge of needs-input stamps it, the next heartbeat consumes
# it and restores running.

set -euo pipefail

command -v tmux >/dev/null 2>&1 || exit 0
[ -n "${TMUX:-}" ] || exit 0

mode="${1:-}"
agent="${2:-}"

JQ="$(command -v jq || true)"

# Watchdog for the companion daemon. agent-tab-watcher.sh is spawned exactly
# once, from tmux.conf, so if it ever dies mid-session (stray pkill, OOM, a
# tmux hiccup) everything it drives silently stops — no blink (the glyph
# freezes on the @agent_blink=unset color), no workflow gear, no presence
# seeding, no GC — until the next `prefix r`, and nothing surfaces the failure.
# Hooks fire constantly, so re-assert it here: in the healthy case this is a
# file test plus a kill -0, no forks. Respawn goes through the tmux server so
# the daemon outlives this short-lived hook process. PIDFILE path must match
# the watcher's.
ensure_watcher() {
    local pidfile pid=""
    pidfile="${TMPDIR:-/tmp}/agent-tab-watcher.${UID:-$(id -u)}.pid"
    if [ -f "$pidfile" ]; then
        read -r pid < "$pidfile" 2>/dev/null || pid=""
    fi
    # `kill -0` alone answers "some process exists", not "the watcher is
    # alive": the daemon only unlinks its pidfile on a clean EXIT, and pids
    # here wrap in ~15 min, so a stale file usually points at an unrelated
    # live process. That reads as HEALTHY and the watchdog never fires —
    # the one failure it exists to catch, silently. Confirm identity before
    # believing it. This costs one ps against the "no forks in the healthy
    # case" goal, but hooks fire a few times per turn, not 86400 times a day
    # like the watcher's own tick, so it is the cheap place to pay.
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        case "$(ps -o command= -p "$pid" 2>/dev/null)" in
            *"/agent-tab-watcher.sh") return 0 ;;
        esac
    fi
    tmux run-shell -b "bash $HOME/.config/tmux/scripts/agent-tab-watcher.sh" 2>/dev/null || true
}
ensure_watcher

# ---------------------------------------------------------------- helpers

window_state() {
    tmux show-options -wqv -t "$1" @agent_state 2>/dev/null || true
}

set_state() {
    # Write + redraw only on change; heartbeat fires on every tool call and
    # must not churn the status line. Writes are best-effort: the window can
    # close between the read and the write, and a failed write must not make
    # the hook exit nonzero (codex treats hook exit status as a gate).
    local win="$1" new="$2" cur
    cur=$(window_state "$win")
    [ "$cur" = "$new" ] && return 0
    tmux set-option -w -t "$win" @agent_state "$new" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

clear_state() {
    local win="$1"
    local cur
    cur=$(window_state "$win")
    tmux set-option -uw -t "$win" @agent_state 2>/dev/null || true
    tmux set-option -uw -t "$win" @agent_summary 2>/dev/null || true
    tmux set-option -uw -t "$win" @agent_summary_cond 2>/dev/null || true
    tmux set-option -uw -t "$win" @agent_pending 2>/dev/null || true
    if [ -n "$cur" ]; then
        tmux refresh-client -S 2>/dev/null || true
    fi
}

clear_pending() {
    tmux set-option -uw -t "$1" @agent_pending 2>/dev/null || true
}

sanitize_summary() {
    # One line, no format-significant characters, bounded length. The value
    # lands in window-status-format via #{@agent_summary}; '#' starts a
    # format/style token and '%' is a strftime metacharacter under #{T:…}, so
    # strip both defensively even though the current render path is bare.
    # '/' becomes a space so the only slash in a tab name is the deliberate
    # "<project>/" separator — a model title or project basename can't add
    # its own (it would read as a second path segment).
    # $1 overrides the 60-char bound: a title is display text, but a prompt is
    # the condenser's *input* and wants more of the sentence (extract_summary).
    local max="${1:-60}"
    tr '\n\t/' '   ' | tr -d '#"%' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-"$max"
}

# $3=1 marks <summary> as a condensed (model-written) label; 0/absent marks it
# as raw stand-in text. Recorded in @agent_summary_cond so compose_summary can
# refuse to downgrade a finished label back to raw text on a later turn. The
# flag is written before the no-change short-circuit: re-asserting the same
# string must still correct the flag.
set_summary() {
    local win="$1" summary="$2" cond="${3:-0}" cur
    [ -n "$summary" ] || return 0
    if [ "$cond" = 1 ]; then
        tmux set-option -w -t "$win" @agent_summary_cond 1 2>/dev/null || true
    else
        tmux set-option -uw -t "$win" @agent_summary_cond 2>/dev/null || true
    fi
    cur=$(tmux show-options -wqv -t "$win" @agent_summary 2>/dev/null || true)
    [ "$cur" = "$summary" ] && return 0
    tmux set-option -w -t "$win" @agent_summary "$summary" 2>/dev/null || true
    tmux refresh-client -S 2>/dev/null || true
}

# --- summary composition: @agent_summary = "<project>/<ultra-short title>" -

# Cache rows are TAB-separated: <key> <short> <epoch>. A row with an empty
# <short> is a NEGATIVE entry (a failed/garbage condense) used to back off
# retries for NEG_TTL seconds instead of re-calling the model every turn.
CACHE="$HOME/.cache/agent-tab/titles.tsv"
NEG_TTL=600

# Condenser model. copilot's --model whitelist tracks the CLI version and the
# account's entitlements, and an id that vanishes fails EVERY condense: CLI
# 1.0.75 rejected claude-haiku-4.5 (and every other explicit id) with
# `Model "…" is not available`, so tabs silently kept their raw interim titles
# and the cache filled with negative entries — a broken renamer that looks
# exactly like a slow one. The pin is therefore best-effort: on rejection the
# condenser falls back to copilot's default model and drops MODEL_SKIP so
# later runs skip the doomed call, re-probing the pin once the marker ages out
# (models come back). Override the pin with AGENT_TAB_CONDENSE_MODEL; set it
# empty to always use copilot's default.
CONDENSE_MODEL="${AGENT_TAB_CONDENSE_MODEL-claude-haiku-4.5}"
MODEL_SKIP="${TMPDIR:-/tmp}/agent-tab-model-unavailable.${UID:-$(id -u)}"
MODEL_SKIP_TTL=86400

now_epoch() { date +%s 2>/dev/null || echo 0; }

title_key() {
    printf '%s' "$1" | /usr/bin/shasum -a 256 | cut -c1-16
}

# Last non-empty short for a title (skips negative rows; last writer wins).
cached_short() {
    [ -f "$CACHE" ] || return 0
    awk -F'\t' -v k="$(title_key "$1")" \
        '$1==k && $2!=""{v=$2} END{if(v!="")print v}' "$CACHE" 2>/dev/null || true
}

# True if the most recent row for this key is a negative within NEG_TTL —
# i.e. we failed to condense recently and shouldn't retry the model yet.
negative_fresh() {
    [ -f "$CACHE" ] || return 1
    awk -F'\t' -v k="$1" -v now="$(now_epoch)" -v ttl="$NEG_TTL" \
        '$1==k{s=$2;ts=$3} END{exit !(s=="" && ts!="" && (now-ts)<ttl)}' \
        "$CACHE" 2>/dev/null
}

cache_put() {
    mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$1" "$2" "$(now_epoch)" >> "$CACHE" 2>/dev/null || true
}

# Trim to <=N chars on whole-word boundaries (never mid-word unless the first
# word alone is longer than N).
fit_words() {
    local s="$1" n="${2:-24}"
    while [ "${#s}" -gt "$n" ] && [ "${s% *}" != "$s" ]; do s="${s% *}"; done
    printf '%s' "$s" | cut -c1-"$n"
}

# Gate model output before caching: accept only title-like text (1-4 words,
# <=24 chars, has a letter, no colon / sentence-final punctuation, not an
# apology / refusal / auth-error / first-person reply). This is what stops
# copilot error strings ("Credit balance is too…") from poisoning the cache.
valid_short() {
    local s="$1" lc wc
    [ -n "$s" ] || return 1
    [ "${#s}" -le 24 ] || return 1
    case "$s" in *:*|*.|*!|*\?) return 1 ;; esac
    case "$s" in *[A-Za-z]*) ;; *) return 1 ;; esac
    wc=$(printf '%s' "$s" | wc -w | tr -d ' ')
    [ "$wc" -ge 1 ] && [ "$wc" -le 4 ] || return 1
    # Refusal/error preambles START with these — anchor to the front so a
    # legit title that merely CONTAINS a word like "login" or "error"
    # ("Add login flow", "Error boundary component") isn't rejected. Errors
    # with a colon ("Error: …") are already caught by the *:* rule above.
    lc=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
    case "$lc" in
        "i "*|"i'"*|sorry*|apolog*|please*|unable*|"sure,"*|"here "* \
        |"credit balance"*|"not authenticated"*) return 1 ;;
    esac
    return 0
}

project_name() {
    # Basename of the hook payload's cwd (HOME → "~"), falling back to the
    # agent pane's current path.
    local payload="$1" cwd=""
    if [ -n "$JQ" ] && [ -n "$payload" ]; then
        cwd=$("$JQ" -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
    fi
    if [ -z "$cwd" ] && [ -n "${pane:-}" ]; then
        cwd=$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null || true)
    fi
    [ -n "$cwd" ] || return 0
    if [ "$cwd" = "$HOME" ]; then
        printf '~'
    else
        basename "$cwd" | sanitize_summary | cut -c1-20
    fi
}

compose_summary() {
    # Set "<project>/<short>" immediately from cache when we've condensed
    # this title before; otherwise show "<project>/<raw>" as an interim and
    # condense in a detached child (an LLM call must never block a hook).
    # $2 is extract_summary's tagged "<src>\t<title>" (bare text = final).
    local win="$1" tagged="$2" payload="$3" proj short src raw
    [ -n "$tagged" ] || return 0
    case "$tagged" in
        *$'\t'*) src="${tagged%%$'\t'*}"; raw="${tagged#*$'\t'}" ;;
        *)       src="final"; raw="$tagged" ;;
    esac
    [ -n "$raw" ] || return 0
    proj=$(project_name "$payload")
    short=$(cached_short "$raw")
    if [ -n "$short" ]; then
        set_summary "$win" "${proj:+$proj/}$short" 1
        return 0
    fi
    # Raw text is only ever a stand-in for the label the condenser is about to
    # write, so don't paint it over a label already condensed for this window.
    # Both sources get condensed (see $src below), so the second one to arrive
    # would otherwise flash the untrimmed title for a second or two mid-turn —
    # which reads as the tab breaking, not refining. With no condenser (or a
    # failing one) the flag never gets set and raw text still shows through.
    if [ "$(tmux show-options -wqv -t "$win" @agent_summary_cond 2>/dev/null || true)" != 1 ]; then
        set_summary "$win" "${proj:+$proj/}$(fit_words "$raw" 24)"
    fi
    # $src is condensed either way. The agent writes its own title only at the
    # END of the first turn, so gating on `final` meant a whole turn of raw
    # prompt text in the tab; condensing the `interim` prompt names the tab
    # from the moment the first message is sent, for one extra call per
    # session (the real title hashes to a different key). The cache read above
    # keeps repeats — and every later turn — free.
    command -v copilot >/dev/null 2>&1 || return 0
    ( nohup bash "$0" condense "$win" "$proj" "$raw" >/dev/null 2>&1 & ) 2>/dev/null || true
}

# Conversation title, best source first. Emits "<src>\t<title>", where <src>
# distinguishes the agent's own conversation title (`final`) from the turn's
# prompt standing in until that title exists (`interim`) — compose_summary
# spends a model call only on `final`. Empty output = no title at all.
# A tab is a safe delimiter: sanitize_summary maps tabs to spaces.
#   claude: latest ai-title entry near the transcript tail (cheap: last 64KB),
#           else session_title, else the prompt that started the turn.
#   codex:  threads.name from ~/.codex/state_5.sqlite keyed by session_id
#           (0.148 moved thread metadata off session_index.jsonl), else
#           threads.title (first user message), else the prompt.
extract_summary() {
    local payload="$1" title="" src="final"
    [ -n "$JQ" ] || return 0
    [ -n "$payload" ] || return 0

    case "$agent" in
        claude)
            local transcript
            transcript=$("$JQ" -r '.transcript_path // empty' <<<"$payload" 2>/dev/null || true)
            if [ -n "$transcript" ] && [ -f "$transcript" ]; then
                title=$(tail -c 65536 "$transcript" 2>/dev/null \
                    | grep '"type":"ai-title"' | tail -1 \
                    | "$JQ" -r '.aiTitle // empty' 2>/dev/null || true)
            fi
            if [ -z "$title" ]; then
                title=$("$JQ" -r '.session_title // empty' <<<"$payload" 2>/dev/null || true)
            fi
            if [ -z "$title" ]; then
                title=$("$JQ" -r '.prompt // empty' <<<"$payload" 2>/dev/null || true)
                src="interim"
            fi
            ;;
        codex)
            # codex ≥0.148 keeps thread metadata in sqlite (session_index.jsonl
            # is no longer written): threads.name is the model-written thread
            # title (lands after the first turn), threads.title is the first
            # user message — a prompt-grade stand-in, so it condenses like one.
            local session_id db="$HOME/.codex/state_5.sqlite"
            session_id=$("$JQ" -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
            case "$session_id" in *[!0-9a-fA-F-]*) session_id="" ;; esac
            if [ -n "$session_id" ] && [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
                title=$(sqlite3 -readonly "$db" \
                    "select coalesce(nullif(name,''),'') from threads where id='$session_id'" \
                    2>/dev/null || true)
                if [ -z "$title" ]; then
                    title=$(sqlite3 -readonly "$db" \
                        "select title from threads where id='$session_id'" \
                        2>/dev/null || true)
                    [ -n "$title" ] && src="interim"
                fi
            fi
            if [ -z "$title" ]; then
                title=$("$JQ" -r '.prompt // empty' <<<"$payload" 2>/dev/null || true)
                src="interim"
            fi
            ;;
    esac

    # An agent-written title is already short and is displayed as-is if the
    # condense fails; a prompt is a whole sentence whose first 60 chars can cut
    # off the identifying words the condenser exists to find, so give it room.
    # Display is unaffected — compose_summary trims to 24 chars either way.
    if [ "$src" = "interim" ]; then
        title=$(printf '%s' "$title" | sanitize_summary 200)
    else
        title=$(printf '%s' "$title" | sanitize_summary)
    fi
    [ -n "$title" ] || return 0
    printf '%s\t%s' "$src" "$title"
}

# ------------------------------------------------------------ entry modes

# Focus hook: attention discharged for the window the user just selected.
# The after-select-window hook passes the selected #{window_id} as $2 —
# an untargeted display-message resolves to the most-recently-active
# CLIENT, which can be a different one when several clients are attached.
if [ "$mode" = "clear-current" ]; then
    win="${2:-}"
    if [ -z "$win" ]; then
        win=$(tmux display-message -p '#{window_id}' 2>/dev/null || true)
    fi
    [ -n "$win" ] || exit 0
    case "$(window_state "$win")" in
        needs-*)
            # The user came to answer the prompt. Discharge the tint, but
            # stamp @agent_pending so the next heartbeat can restore
            # `running` once the answered turn resumes — the discharge
            # happens BEFORE any post-answer heartbeat, so heartbeat's own
            # needs-input re-arm can never fire in this flow.
            set_state "$win" idle
            tmux set-option -w -t "$win" @agent_pending "$(now_epoch)" 2>/dev/null || true
            ;;
        done) set_state "$win" idle ;;
    esac
    exit 0
fi

# Detached condenser (spawned by compose_summary): distill the raw title to
# its 2-4 identifying words with a one-shot copilot/haiku call, cache it,
# update the tab. argv: condense <window_id> <project> <raw-title>. Never
# invoked by hooks directly, so a slow/failed model call only delays the
# title swap.
if [ "$mode" = "condense" ]; then
    win="${2:-}"; proj="${3:-}"; raw="${4:-}"
    { [ -n "$win" ] && [ -n "$raw" ]; } || exit 0
    key=$(title_key "$raw")
    lock="${TMPDIR:-/tmp}/agent-tab-condense.$key.lock"
    mkdir "$lock" 2>/dev/null || exit 0   # another condenser owns this title
    # copilot's stderr is kept (not /dev/null'd) so a failure can be told
    # apart from a rejected --model, which is recoverable.
    ERRF="$lock/err"
    trap 'rm -f "$ERRF" 2>/dev/null; rmdir "$lock" 2>/dev/null' EXIT INT TERM

    short=$(cached_short "$raw")
    if [ -z "$short" ]; then
        # Back off if a recent attempt for this title failed, so a persistent
        # copilot error (not logged in, out of credit) isn't re-run every turn.
        negative_fresh "$key" && exit 0

        # gtimeout is coreutils' name when /usr/bin/timeout is absent (macOS).
        TO=$(command -v timeout || command -v gtimeout || true)
        PROMPT="From the coding-session title or first message below, output a 2-4 word tab label built from the MOST SPECIFIC, distinctive words in it: the concrete subject, target, feature, file, tech, or action unique to THIS task. Keep proper nouns and real names. DROP generic filler (project, code, app, task, session, various, deep, inspection, thing, stuff, update, changes, improve, and a bare fix/add/refactor when what it acts on is unnamed). Someone reading the label should be able to guess the task back. Prefer the unusual identifying word over the category word. Output ONLY the label - no punctuation, quotes, or explanation.

Examples:
- 'deep inspection of this project docs, I wanna open source it, make sure nothing reads like AI or oddly specific to me' => Open-source doc cleanup
- 'refactor the auth middleware to use JWTs instead of session cookies' => JWT auth refactor
- 'figure out why the websocket reconnect drops messages under load' => Websocket reconnect bug

Title: $raw"
        # Copilot prints the answer on stdout, stats on stderr; a pure text
        # prompt grants no tool permissions. Capture the exit code explicitly
        # — `|| true` would mask a failed call whose stdout is an error string.
        # Empty $1 = no --model flag, i.e. whatever copilot picks by default.
        copilot_condense() {
            ${TO:+"$TO" 90} copilot -p "$PROMPT" ${1:+--model "$1"} \
                --no-color </dev/null 2>"$ERRF"
        }

        model="$CONDENSE_MODEL"
        # A standing rejection marker means the pin was refused recently —
        # go straight to the default instead of burning a doomed call.
        if [ -n "$model" ] && [ -f "$MODEL_SKIP" ]; then
            mts=$(stat -f %m "$MODEL_SKIP" 2>/dev/null || echo 0)
            [ "$(( $(now_epoch) - mts ))" -lt "$MODEL_SKIP_TTL" ] && model=""
        fi

        ok=0
        if out=$(copilot_condense "$model"); then
            ok=1
        elif [ -n "$model" ] && grep -qiE 'not available|unknown model|invalid model' "$ERRF" 2>/dev/null; then
            # The pin is gone from this CLI/account. Remember it (so the next
            # condense skips straight to the default) and retry right now on
            # the default model — a renamed model must not cost a whole
            # session of raw tab titles.
            : > "$MODEL_SKIP" 2>/dev/null || true
            out=$(copilot_condense "") && ok=1
        fi

        if [ "$ok" = 1 ]; then
            # `|| true`: with set -e + pipefail, a completion that is empty or
            # newlines-only makes grep -m1 exit 1 and kills the whole script
            # here — before the negative cache entry below is written, so
            # nothing throttles the next attempt and the condenser respawns
            # in a loop (silently: the child is detached to /dev/null).
            short=$(printf '%s' "$out" | grep -m1 . | sanitize_summary | cut -d' ' -f1-4 || true)
            short=$(fit_words "$short" 24)
            valid_short "$short" || short=""
        else
            short=""
        fi

        if [ -n "$short" ]; then
            cache_put "$key" "$short"
        else
            cache_put "$key" ""   # negative entry → NEG_TTL backoff
            exit 0
        fi
    fi
    [ -n "$short" ] || exit 0
    set_summary "$win" "${proj:+$proj/}$short" 1
    exit 0
fi

# Everything below is an agent hook: resolve the agent's window from the
# pane the hook inherited. No TMUX_PANE = the hook has no pane identity
# (a ChatGPT-app codex thread, a background worker with a scrubbed env).
# The old fallback resolved an untargeted display-message to the *currently
# active* window, which painted a foreign agent's state and title onto
# whatever tab the user happened to be looking at. No pane, no tab.
pane="${TMUX_PANE:-}"
[ -n "$pane" ] || exit 0
win=$(tmux display-message -p -t "$pane" '#{window_id}' 2>/dev/null || true)
[ -n "$win" ] || exit 0

# Heartbeat is the hot path (every tool call): don't wait on stdin — the
# payload includes tool_response, which can be megabytes. A backgrounded
# drain consumes the pipe so the writer never sees EPIPE (codex's tolerance
# for a hook that abandons its stdin is undocumented), without blocking us.
# Only re-arm running from running/needs-input — a late PostToolUse landing
# after Stop's `done` (or a subagent tool firing past the turn boundary, which
# bypasses the agent_id guard below) must NOT resurrect a finished tab.
if [ "$mode" = "heartbeat" ]; then
    ( cat >/dev/null 2>&1 & ) 2>/dev/null
    case "$(window_state "$win")" in
        running|needs-*) set_state "$win" running ;;
        idle)
            # idle + @agent_pending = an answered permission prompt's turn
            # resuming (see clear-current). Single-use and age-gated, so a
            # stray late tool call can't resurrect a tab that merely sat
            # idle; bare idle (no stamp) stays inert as before.
            pend=$(tmux show-options -wqv -t "$win" @agent_pending 2>/dev/null || true)
            if [ -n "$pend" ]; then
                clear_pending "$win"
                case "$pend" in *[!0-9]*) pend=0 ;; esac
                if [ "$(( $(now_epoch) - pend ))" -lt 3600 ]; then
                    set_state "$win" running
                fi
            fi
            ;;
    esac
    exit 0
fi

payload=$(cat 2>/dev/null || true)

# Hooks also fire inside subagent contexts (payload carries agent_id); a
# subagent's Stop/PermissionRequest must not flip the main agent's tab.
if [ -n "$JQ" ] && [ -n "$payload" ]; then
    if [ -n "$("$JQ" -r '.agent_id // empty' <<<"$payload" 2>/dev/null || true)" ]; then
        exit 0
    fi
fi

# Codex background threads (subagents, review/guardian workers, the Memory
# Writing Agent) fire the same hooks as the interactive thread, from the same
# process — same TMUX_PANE — under their own session_id. Under codex 0.147 the
# memory writer's UserPromptSubmit repainted the user's tab title ("Memory
# Writing"); 0.148 stopped hooking memory workers, but subagent threads remain.
# Two guards: the thread registry marks non-user threads (thread_source), and
# the memory writer's prompt opener is recognizable even before a row exists.
# A session with no row yet is presumed interactive (rows land within the
# first turn, and a wrong "interactive" guess only refreshes the tab early).
if [ "$agent" = codex ] && [ -n "$JQ" ] && [ -n "$payload" ]; then
    case "$("$JQ" -r '.prompt // empty' <<<"$payload" 2>/dev/null | head -c 40)" in
        "You are a Memory Writing Agent"*) exit 0 ;;
    esac
    csid=$("$JQ" -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
    case "$csid" in *[!0-9a-fA-F-]*) csid="" ;; esac
    cdb="$HOME/.codex/state_5.sqlite"
    if [ -n "$csid" ] && [ -f "$cdb" ] && command -v sqlite3 >/dev/null 2>&1; then
        tsrc=$(sqlite3 -readonly "$cdb" \
            "select coalesce(thread_source,'') from threads where id='$csid'" 2>/dev/null || true)
        case "$tsrc" in ''|user) : ;; *) exit 0 ;; esac
    fi
fi

# Is the agent's own window currently being viewed by ≥1 client? window
# scope, so it's robust to multiple attached clients AND to detached sessions
# (an untargeted display-message would resolve to some other client's window;
# #{window_active} is 1 even for zero-client sessions — neither is correct).
watched=$(tmux display-message -p -t "$win" '#{window_active_clients}' 2>/dev/null || true)
case "$watched" in ''|*[!0-9]*) watched=0 ;; esac

case "$mode" in
    idle)
        # SessionStart with source=compact fires mid-turn after auto-compaction;
        # don't downgrade a running turn.
        src=""
        if [ -n "$JQ" ] && [ -n "$payload" ]; then
            src=$("$JQ" -r '.source // empty' <<<"$payload" 2>/dev/null || true)
            [ "$src" = "compact" ] && exit 0
        fi
        set_state "$win" idle
        clear_pending "$win"
        summary=$(extract_summary "$payload")
        if [ -n "$summary" ]; then
            compose_summary "$win" "$summary" "$payload"
        else
            # A fresh conversation (/clear, new startup) has no title yet —
            # show "<project>/New Session" as a placeholder until the first
            # turn generates a real title (set directly, not condensed). resume
            # keeps whatever title it had: that's still the right conversation.
            case "$src" in
                clear|startup)
                    proj=$(project_name "$payload")
                    set_summary "$win" "${proj:+$proj/}New Session"
                    ;;
            esac
        fi
        ;;
    running)
        set_state "$win" running
        clear_pending "$win"
        compose_summary "$win" "$(extract_summary "$payload")" "$payload"
        ;;
    needs-approval)
        # Always assert — focusing a window is not answering its prompt. The
        # focus hook (clear-current) discharges needs-*→idle once seen, so
        # a prompt is never silently lost by switching away.
        set_state "$win" needs-approval
        ;;
    needs-input)
        # Same, except a live permission gate (red) outranks a StopFailure
        # landing on top of it (see header).
        [ "$(window_state "$win")" = needs-approval ] && exit 0
        set_state "$win" needs-input
        ;;
    done)
        # Don't tint a window someone is actively watching — they saw it finish.
        if [ "$watched" -gt 0 ]; then
            set_state "$win" idle
        else
            set_state "$win" "done"
        fi
        clear_pending "$win"
        compose_summary "$win" "$(extract_summary "$payload")" "$payload"
        ;;
    clear)
        # SessionEnd reasons clear/resume are immediately followed by a new
        # SessionStart in the same pane — clearing would just flicker.
        if [ -n "$JQ" ] && [ -n "$payload" ]; then
            reason=$("$JQ" -r '.reason // empty' <<<"$payload" 2>/dev/null || true)
            case "$reason" in clear|resume) exit 0 ;; esac
        fi
        clear_state "$win"
        ;;
    *)
        echo "Usage: agent-tab-indicator.sh <idle|running|heartbeat|needs-approval|needs-input|done|clear|clear-current> [claude|codex]" >&2
        # exit 0, not 1: codex treats a hook's exit status as a GATE (see the
        # header), so a typo'd mode in hooks.json would block every codex
        # event rather than just failing to paint a tab. A silently inert
        # indicator is a far better failure than a wedged agent; the usage
        # line still goes to stderr for anyone running this by hand.
        exit 0
        ;;
esac
