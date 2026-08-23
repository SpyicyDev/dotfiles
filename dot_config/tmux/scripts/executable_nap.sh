#!/usr/bin/env bash
# nap — put a Claude Code session to sleep in place, keeping its tmux tab.
#
# A Claude session that is merely sitting there is not free: measured on this
# machine, four idle tabs held ~4.0 GB RSS across 28 processes and burned
# 0.7-2.9% CPU each doing nothing. This reclaims that without losing the tab,
# the scrollback, or the conversation.
#
# WHY EXIT AND NOT FREEZE. The obvious move — SIGSTOP the process tree — was
# measured and rejected (2026-08-22). Two findings, both fatal:
#   1. It frees no memory. phys_footprint read 253 MB before a stop and 253 MB
#      after 120 s stopped; macOS does not reclaim a stopped process's pages.
#      CPU did go to exactly 0.0%, which is the only thing it buys.
#   2. It permanently breaks the session. After SIGCONT the TUI still rendered
#      but never read another keystroke — stty confirmed raw mode was still
#      intact, so it is Claude's own stdin reader that does not survive the
#      stop, not the terminal. A SIGWINCH did not repair it.
# SIGTERM, by contrast, exits cleanly AND reaps every MCP child (no orphans),
# freeing the whole ~830 MB; `claude --resume <id>` then restores full context.
# So sleep = terminate, wake = resume. There is no middle tier.
#
# WHY THE TAB SURVIVES. Every agent pane runs claude under a real login shell
# (`-zsh`), so when claude exits the pane falls back to that shell rather than
# closing. Wake just types the resume command into it. This is also why the
# system adopts already-running tabs with no restart and no wrapper process.
#
# STATE. Claude deletes its own ~/.claude/sessions/<pid>.json on exit, so the
# sessionId must be snapshotted BEFORE the kill — that snapshot is the nap file
# and it is the only thing standing between a sleeping tab and a lost session.
#
# Usage:
#   nap.sh sleep  [<window>]     put the window's agent to sleep (default: current)
#   nap.sh wake   [<window>]     resume it in place
#   nap.sh toggle [<window>]     sleep if awake, wake if asleep
#   nap.sh pin    [<window>]     toggle "never auto-sleep" for this window
#   nap.sh wake-on-focus <win>   debounced auto-wake, for the pane-focus-in hook
#   nap.sh sleep-idle [minutes]  sweep: sleep every eligible idle agent
#   nap.sh list                  show what is asleep and what is eligible
set -uo pipefail

NAP_DIR="$HOME/.claude/naps"
SESS_DIR="$HOME/.claude/sessions"
IDLE_MINUTES="${NAP_IDLE_MINUTES:-30}"
FOCUS_DEBOUNCE="${NAP_FOCUS_DEBOUNCE:-2}"
TERM_WAIT=12          # seconds to wait for a graceful exit before giving up
WAKE_CONFIRM_SECS=90  # how long a resume may take to register before we call it failed

# Field separator for every internal record. NOT a tab: bash treats space, tab
# and newline as "IFS whitespace", and collapses runs of them into a single
# delimiter even when IFS is set to just one of them — so a record with an
# empty field silently loses it and every later field shifts left. That is not
# theoretical: a session that has not yet reported a `status` produced an empty
# third field, which shifted its window id from @1 to %2 and fed "@1" to an
# integer comparison. Unit separator is non-whitespace, so empty fields survive.
SEP=$'\x1f'

mkdir -p "$NAP_DIR"

log() { printf 'nap: %s\n' "$*" >&2; }
# Always log as well as display: run from a keybind the tmux message is the
# only channel, but run from a shell (or the sweep) stderr is the only one, and
# a refusal you cannot see reads as a broken keybind.
msg() { tmux display-message "nap: $*" 2>/dev/null; log "$*"; }

# --- helpers -----------------------------------------------------------------

napfile() { printf '%s/%s.json' "$NAP_DIR" "${1#@}"; }

cur_window() { tmux display-message -p '#{window_id}' 2>/dev/null; }

# Window ids are unique only within one tmux server: after a restart they
# restart from @0, so a nap file left by a previous server can collide with a
# brand-new window and paint a live tab as permanently asleep. Stamping the
# server pid makes every nap file self-invalidating across a restart. (Not
# hypothetical — a reboot on 2026-08-22 renumbered every window on this
# machine while this was being built.)
server_pid() { tmux display-message -p '#{pid}' 2>/dev/null; }

# All live claude sessions, one per line, $SEP-delimited:
#   pid · sessionId · status · statusEpoch · window · pane · cwd
# `status` and `statusEpoch` are legitimately empty on a session that has not
# reported yet, which is why the delimiter is not a tab (see SEP).
# The session file's own "tmux" field is "session:@win.%pane", an authoritative
# pane address — far better than matching processes back to panes by TTY.
live_sessions() {
    python3 - "$SESS_DIR" <<'PY' 2>/dev/null
import json, os, sys, glob
d = sys.argv[1]
for f in glob.glob(os.path.join(d, "*.json")):
    try:
        s = json.load(open(f))
    except Exception:
        continue
    t = s.get("tmux") or ""
    win = pane = ""
    if ":" in t and "." in t:
        win, pane = t.split(":", 1)[1].split(".", 1)
    print(chr(31).join(str(x) for x in (
        s.get("pid", ""), s.get("sessionId", ""), s.get("status", ""),
        int(s.get("statusUpdatedAt", 0) or 0) // 1000,
        win, pane, s.get("cwd", ""))))
PY
}

# pid + pane + sessionId + cwd for a window, or empty if it holds no agent.
#
# EVERY loop variable is local, and that is load-bearing rather than tidiness.
# Callers legitimately hold variables of the same names — do_wake reads `pane`,
# `sid` and `cwd` out of the nap file and then calls this to check whether the
# window is already occupied. Without `local`, this loop's read would assign
# into the CALLER's scope and, on the no-match path, leave them all empty at
# EOF. That produced a `tmux send-keys -t ''`, which is not a no-op: an empty
# target resolves to the CURRENT pane, so waking a sleeping tab typed a resume
# command into whichever pane happened to be running the script.
session_for_window() {
    local win="$1" pid sid status supd w pane cwd
    while IFS="$SEP" read -r pid sid status supd w pane cwd; do
        [ "$w" = "$win" ] && { printf '%s' "$pid$SEP$sid$SEP$pane$SEP$cwd$SEP$status$SEP$supd"; printf '\n'; return 0; }
    done < <(live_sessions)
    return 1
}

# Claude spawns `caffeinate -i -t 300` as a child while it works. It tracks
# busy/idle well — but note the `-t 300`: the assertion is a FIVE MINUTE timer,
# so it outlives the turn that started it. That makes it a fine extra guard for
# the 30-minute sweep and a bad one for the keybind, where it would refuse to
# sleep a tab you had just finished using. Hence two separate predicates.
has_caffeinate() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    ps -eo ppid=,command= 2>/dev/null | awk -v r="$pid" '$1==r && /caffeinate/{f=1} END{exit !f}'
}

# The live "is a turn in flight" test. `status` is what Claude itself maintains
# and is authoritative while fresh; the transcript is appended per message, so a
# write in the last few seconds means something is happening right now
# regardless of what any field claims. Stale-BUSY is safe (it only over-refuses
# — seen reading busy with a 27-minute-old timestamp); stale-IDLE is the
# dangerous direction, which the mtime check is here to catch.
ACTIVE_WINDOW_SECS=15
is_working() {
    local pid="$1" status="${2:-}" sid="${3:-}" mt
    [ "$status" = "busy" ] && return 0
    if [ -n "$sid" ]; then
        mt=$(transcript_mtime "$sid")
        [ "$mt" -gt 0 ] && [ $(( $(date +%s) - mt )) -lt "$ACTIVE_WINDOW_SECS" ] && return 0
    fi
    return 1
}

# Refuse to sleep a session with text typed but not submitted — that text lives
# only in the TUI's buffer and dies with the process, and nothing else in this
# system can recover it.
#
# The composer is the band between the LAST TWO horizontal rules, not the text
# after the last one: the TUI draws rule / composer / rule / status, so reading
# "everything below the final rule" picks up the model-and-context status line,
# which is never empty and made this refuse every single time. Anything left in
# that band after stripping the ❯ prompt glyph is unsent input.
has_unsent_input() {
    local pane="$1"
    tmux capture-pane -p -t "$pane" 2>/dev/null | awk '
        { line[NR] = $0; if ($0 ~ /^─────/) { prev = last; last = NR } }
        END {
            if (!prev) exit 1            # no composer found — treat as clean
            for (i = prev + 1; i < last; i++) {
                s = line[i]
                gsub(/^[[:space:]]*❯[[:space:]]*/, "", s)
                gsub(/[[:space:]]+$/, "", s)
                gsub(/^[[:space:]]+/, "", s)
                if (s != "") exit 0      # something is typed
            }
            exit 1
        }'
}

# The transcript is appended per message, so its mtime is the truest "last
# activity" clock — independent of any status field the session maintains.
transcript_mtime() {
    local sid="$1" f
    f=$(find "$HOME/.claude/projects" -name "$sid.jsonl" -maxdepth 2 2>/dev/null | head -1)
    [ -n "$f" ] && stat -f %m "$f" 2>/dev/null || echo 0
}

is_pinned() { [ -n "$(tmux show -wqv -t "$1" @nap_pin 2>/dev/null)" ]; }

pane_alive() { tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$1"; }

# --- sleep -------------------------------------------------------------------

do_sleep() {
    local win="${1:-$(cur_window)}" quiet="${2:-}"
    [ -n "$win" ] || { log "no window"; return 1; }

    if [ -f "$(napfile "$win")" ]; then
        [ -n "$quiet" ] || msg "already asleep"
        return 0
    fi
    if is_pinned "$win"; then
        [ -n "$quiet" ] || msg "window is pinned (prefix+Z to unpin)"
        return 1
    fi

    local info pid sid pane cwd status supd
    if ! info=$(session_for_window "$win"); then
        [ -n "$quiet" ] || msg "no Claude session in this window"
        return 1
    fi
    IFS="$SEP" read -r pid sid pane cwd status supd <<<"$info"

    if is_working "$pid" "$status" "$sid"; then
        [ -n "$quiet" ] || msg "session is mid-turn — not sleeping it"
        return 1
    fi
    # A backgrounded Workflow keeps running after its turn's Stop fires, and
    # computer-use drives an app across turns — both outlive the signals above
    # (a workflow window can read idle, with no caffeinate, while a fleet is
    # still out). The watcher already tracks exactly this on the window, so
    # reuse its answer rather than re-deriving it. Killing here would take the
    # fleet down with the session.
    if [ -n "$(tmux show -wqv -t "$win" @agent_workflow 2>/dev/null)" ]; then
        [ -n "$quiet" ] || msg "a background workflow is still running — not sleeping it"
        return 1
    fi
    if [ -n "$(tmux show -wqv -t "$win" @agent_cua 2>/dev/null)" ]; then
        [ -n "$quiet" ] || msg "session is driving an app — not sleeping it"
        return 1
    fi
    if has_unsent_input "$pane"; then
        [ -n "$quiet" ] || msg "unsent input in the composer — not sleeping it"
        return 1
    fi

    # Preserve the tab's name across the sleep. @agent_summary is what the
    # status line renders (it falls back to bare #W without it), and the
    # watcher's GC would otherwise strip it the moment the process dies.
    local summary
    summary=$(tmux show -wqv -t "$win" @agent_summary 2>/dev/null)

    python3 - "$(napfile "$win")" "$win" "$pane" "$pid" "$sid" "$cwd" "$summary" "$(server_pid)" <<'PY'
import json, sys, time
p, win, pane, pid, sid, cwd, summary, server = sys.argv[1:9]
json.dump({"window": win, "pane": pane, "pid": int(pid), "sessionId": sid,
           "cwd": cwd, "summary": summary, "server": server,
           "sleptAt": int(time.time())}, open(p, "w"))
PY

    # Style the tab immediately rather than waiting up to a watcher tick.
    # @agent_nap is the render flag (set for BOTH sleeping and waking, which
    # look identical); @agent_state carries which of the two it is, for tooling.
    # Splitting them keeps the format expressions to a single short test, the
    # way @agent_workflow and @agent_cua already work — the alternative was an
    # 8-term ||-chain repeated across all six catppuccin options.
    tmux set-option -w -t "$win" @agent_state sleeping 2>/dev/null
    tmux set-option -w -t "$win" @agent_nap 1 2>/dev/null
    [ -n "$summary" ] && tmux set-option -w -t "$win" @agent_summary "$summary" 2>/dev/null

    kill -TERM "$pid" 2>/dev/null
    local i=0
    while [ "$i" -lt "$TERM_WAIT" ] && kill -0 "$pid" 2>/dev/null; do
        sleep 1; i=$((i + 1))
    done

    if kill -0 "$pid" 2>/dev/null; then
        # Never leave a nap file claiming a session is asleep when it is not —
        # that is the one lie that would strand a live session behind a
        # sleeping-looking tab.
        rm -f "$(napfile "$win")"
        tmux set-option -uw -t "$win" @agent_state 2>/dev/null
        tmux set-option -uw -t "$win" @agent_nap 2>/dev/null
        msg "session $pid did not exit — left it running"
        return 1
    fi

    [ -n "$quiet" ] || msg "slept ${summary:-$win}"
    return 0
}

# --- wake --------------------------------------------------------------------

do_wake() {
    local win="${1:-$(cur_window)}" quiet="${2:-}"
    local nf; nf=$(napfile "$win")
    [ -f "$nf" ] || { [ -n "$quiet" ] || msg "not asleep"; return 0; }

    local pane sid cwd summary server
    IFS="$SEP" read -r pane sid cwd summary server < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(chr(31).join([d["pane"], d["sessionId"], d["cwd"], d.get("summary",""), str(d.get("server",""))]))' "$nf")

    # Checked before anything is typed anywhere: a stale file from a previous
    # tmux server can carry a window/pane id that now belongs to something
    # entirely unrelated, and this is the path that would type a resume command
    # into it.
    if [ -n "$server" ] && [ "$server" != "$(server_pid)" ]; then
        rm -f "$nf"
        log "discarded nap state for $win (written by a previous tmux server)"
        return 1
    fi

    if ! pane_alive "$pane"; then
        rm -f "$nf"
        log "pane $pane is gone; discarded nap state for $win"
        return 1
    fi

    # If something already re-launched an agent here, just drop the nap state.
    if session_for_window "$win" >/dev/null; then
        rm -f "$nf"
        tmux set-option -uw -t "$win" @agent_state 2>/dev/null
        tmux set-option -uw -t "$win" @agent_nap 2>/dev/null
        return 0
    fi

    # `waking` renders exactly like `sleeping` — dim, no pulse. It exists to
    # stop a second wake racing the first, and the watcher clears it to idle as
    # soon as the process actually shows up.
    tmux set-option -w -t "$win" @agent_state waking 2>/dev/null
    tmux set-option -w -t "$win" @agent_nap 1 2>/dev/null
    [ -n "$summary" ] && tmux set-option -w -t "$win" @agent_summary "$summary" 2>/dev/null

    # Only ever type into a shell sitting at a prompt — otherwise the keys land
    # in whatever is running there, at best lost and at worst submitted to it.
    #
    # The test is "the pane's shell has no child process", NOT a name match on
    # #{pane_current_command}: Claude sets its process title to its own version
    # string, so that field reads e.g. `2.1.241` rather than `claude`, and it
    # keeps reading that for a moment after the process is gone. Matching names
    # made this refuse to wake a pane that was already an idle shell. Child
    # count is what "at a prompt" actually means, and no program can rename its
    # way out of it.
    local pane_pid
    pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
    if [ -z "$pane_pid" ] || pgrep -P "$pane_pid" >/dev/null 2>&1; then
        msg "pane is busy (not at a shell prompt) — not waking"
        tmux set-option -w -t "$win" @agent_state sleeping 2>/dev/null
        return 1
    fi

    local cmd rc
    printf -v cmd 'cd %q && claude --resume %q' "$cwd" "$sid"
    tmux send-keys -t "$pane" C-u          # clear any stray shell input
    tmux send-keys -t "$pane" "$cmd" Enter
    rc=$?
    if [ "$rc" -ne 0 ]; then
        msg "could not type into $pane (send-keys rc=$rc) — leaving it asleep"
        tmux set-option -w -t "$win" @agent_state sleeping 2>/dev/null
        return 1
    fi

    [ -n "$quiet" ] || msg "waking ${summary:-$win}…"

    # Confirm the wake actually took, and only then drop the nap file. A resume
    # can take a while — the largest transcript here is 20 MB / 5592 messages —
    # so this waits generously. The nap file is the ONLY record of the
    # sessionId, so deleting it on the optimistic assumption that keystrokes
    # became a running session is how a tab ends up dim, nameless and
    # unrecoverable. If the session never appears, put the tab back to sleeping
    # with its file intact so the next wake can retry.
    local waited=0
    while [ "$waited" -lt "$WAKE_CONFIRM_SECS" ]; do
        sleep 2; waited=$((waited + 2))
        if session_for_window "$win" >/dev/null; then
            rm -f "$nf"
            return 0
        fi
    done

    tmux set-option -w -t "$win" @agent_state sleeping 2>/dev/null
    msg "wake did not come up after ${WAKE_CONFIRM_SECS}s — still asleep, press prefix+W to retry"
    return 1
}

# Auto-wake from the pane-focus-in hook. Debounced so that merely passing
# through a tab does not trigger a rehydrate — a large session (20 MB / 5500
# messages) takes appreciably longer to come back than a small one.
do_wake_on_focus() {
    local win="${1:-}"
    [ -n "$win" ] || return 0
    [ -f "$(napfile "$win")" ] || return 0
    sleep "$FOCUS_DEBOUNCE"
    # Still asleep, and still the window being looked at?
    [ -f "$(napfile "$win")" ] || return 0
    [ "$(cur_window)" = "$win" ] || return 0
    do_wake "$win" quiet
}

# --- sweep -------------------------------------------------------------------

do_sleep_idle() {
    local mins="${1:-$IDLE_MINUTES}" now cutoff active_wins slept=0
    now=$(date +%s)
    cutoff=$((mins * 60))
    # Never sleep a window someone is actually looking at, in any client.
    active_wins=" $(tmux list-clients -F '#{window_id}' 2>/dev/null | tr '\n' ' ') "

    while IFS="$SEP" read -r pid sid status supd win pane cwd; do
        [ -n "$win" ] || continue
        [ -f "$(napfile "$win")" ] && continue
        case "$active_wins" in *" $win "*) continue ;; esac
        is_pinned "$win" && continue
        is_working "$pid" "$status" "$sid" && continue
        # Sweep-only extra guard: the 5-minute caffeinate tail is far shorter
        # than the idle threshold, so anything still holding one is not a
        # 30-minutes-quiet tab and something unusual is going on. Cheap belt.
        has_caffeinate "$pid" && continue

        # Belt-and-braces on the arithmetic: a malformed or half-written
        # session file must skip the window, never abort the sweep or — worse —
        # compare garbage and decide a live session is 30 minutes idle.
        case "$win" in @*) : ;; *) continue ;; esac
        local last mt
        mt=$(transcript_mtime "$sid")
        case "$supd" in ''|*[!0-9]*) supd=0 ;; esac
        case "$mt"   in ''|*[!0-9]*) mt=0 ;; esac
        last=$supd
        [ "$mt" -gt "$last" ] && last=$mt
        [ "$last" -gt 0 ] || continue
        [ $((now - last)) -ge "$cutoff" ] || continue

        do_sleep "$win" quiet && slept=$((slept + 1))
    done < <(live_sessions)

    [ "$slept" -gt 0 ] && log "slept $slept session(s) idle > ${mins}m"
    return 0
}

# --- misc --------------------------------------------------------------------

do_pin() {
    local win="${1:-$(cur_window)}"
    if is_pinned "$win"; then
        tmux set-option -uw -t "$win" @nap_pin 2>/dev/null
        msg "unpinned — this tab may auto-sleep"
    else
        tmux set-option -w -t "$win" @nap_pin 1 2>/dev/null
        msg "pinned — this tab will never auto-sleep"
    fi
}

do_toggle() {
    local win="${1:-$(cur_window)}"
    if [ -f "$(napfile "$win")" ]; then do_wake "$win"; else do_sleep "$win"; fi
}

# Variable-width fields go LAST so the output stays awk-parseable by column —
# a summary contains spaces, and putting it before the pid silently shifts $4
# into the middle of a tab name for anything scripting against this.
do_list() {
    printf '%-8s %-9s %-30s %s\n' WINDOW STATE DETAIL NAME
    local f
    for f in "$NAP_DIR"/*.json; do
        [ -e "$f" ] || continue
        python3 -c '
import json,sys,time
d=json.load(open(sys.argv[1]))
age=(int(time.time())-d.get("sleptAt",0))//60
print("%-8s %-9s %-30s %s" % (d["window"], "sleeping",
      "asleep %dm sid=%s" % (age, d["sessionId"][:8]), d.get("summary") or "-"))' "$f"
    done
    while IFS="$SEP" read -r pid sid status supd win pane cwd; do
        [ -n "$win" ] || continue
        [ -f "$(napfile "$win")" ] && continue
        local mark=""
        is_pinned "$win" && mark="$mark pinned"
        is_working "$pid" "$status" "$sid" && mark="$mark mid-turn"
        has_caffeinate "$pid" && mark="$mark caffeinated"
        printf '%-8s %-9s %-30s %s\n' "$win" "awake" "pid=$pid $status$mark" \
            "$(tmux show -wqv -t "$win" @agent_summary 2>/dev/null)"
    done < <(live_sessions)
    local o
    for o in "$NAP_DIR"/orphaned/*.json; do
        [ -e "$o" ] || continue
        python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("%-8s %-9s %-30s %s" % ("-", "orphaned",
      "resume-orphan %s" % d["sessionId"][:8], d.get("summary") or "-"))' "$o"
    done
}

# Retire nap files that can no longer refer to anything real: the tab was
# closed while asleep, or the tmux server has restarted since (see server_pid).
#
# These are ARCHIVED, not deleted, and that matters more than it looks.
# tmux-resurrect relaunches assistants from its assistant-sessions.json
# sidecar, which is rebuilt from live processes at save time — and a slept
# session has no live process, so it is absent from every save taken while it
# sleeps. After a restart its tab therefore comes back as a bare shell with
# nothing pointing at the conversation. The session itself is perfectly intact
# (`claude --resume` still lists it), but the sessionId is the only thread back
# to it, and this file is the only place that thread is written down.
# `nap list` surfaces the archive; `nap resume-orphan <id>` reattaches one here.
do_gc() {
    local f pane server now_server
    now_server=$(server_pid)
    mkdir -p "$NAP_DIR/orphaned"
    for f in "$NAP_DIR"/*.json; do
        [ -e "$f" ] || continue
        IFS="$SEP" read -r pane server < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(chr(31).join([d.get("pane",""), str(d.get("server",""))]))' "$f" 2>/dev/null)
        if [ -z "$pane" ] || { [ -n "$server" ] && [ -n "$now_server" ] && [ "$server" != "$now_server" ]; } \
           || ! pane_alive "$pane"; then
            mv -f "$f" "$NAP_DIR/orphaned/$(basename "$f" .json).$(date +%s).json" 2>/dev/null || rm -f "$f"
        fi
    done
}

# Reattach an orphaned (restart-stranded) session into the current window.
do_resume_orphan() {
    local want="${1:-}" f sid cwd summary
    [ -n "$want" ] || { log "usage: nap.sh resume-orphan <sessionId-prefix>"; return 1; }
    for f in "$NAP_DIR"/orphaned/*.json; do
        [ -e "$f" ] || continue
        IFS="$SEP" read -r sid cwd summary < <(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(chr(31).join([d["sessionId"], d["cwd"], d.get("summary","")]))' "$f" 2>/dev/null)
        case "$sid" in
            "$want"*)
                local cmd
                printf -v cmd 'cd %q && claude --resume %q' "$cwd" "$sid"
                tmux send-keys C-u 2>/dev/null
                tmux send-keys "$cmd" Enter 2>/dev/null
                rm -f "$f"
                msg "reattaching ${summary:-$sid}…"
                return 0 ;;
        esac
    done
    log "no orphaned session matching '$want'"
    return 1
}

case "${1:-}" in
    sleep)         shift; do_sleep "${1:-}" ;;
    wake)          shift; do_wake "${1:-}" ;;
    toggle)        shift; do_toggle "${1:-}" ;;
    pin)           shift; do_pin "${1:-}" ;;
    wake-on-focus) shift; do_wake_on_focus "${1:-}" ;;
    sleep-idle)    shift; do_gc; do_sleep_idle "${1:-}" ;;
    list)          do_gc; do_list ;;
    resume-orphan) shift; do_resume_orphan "${1:-}" ;;
    gc)            do_gc ;;
    *)             sed -n '/^# Usage:/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d' ;;
esac
