#!/usr/bin/env bash
# stash — park a tmux window out of the tab bar without stopping it.
#
# tmux has no hide/minimize (still an open request, tmux/tmux#3047), but it does
# not need one: a window's session membership is just a pointer. `move-window`
# to a detached holding session takes the tab off the bar while the window, its
# panes, its processes and its scrollback carry on untouched — verified by round
# trip, including that custom window options survive the move. That last part is
# why there is no state file here: where a window came from is recorded ON the
# window, so it cannot go stale, cannot be orphaned by a tmux restart, and is
# garbage-collected by the window closing.
#
# SUSPENDING AGENTS. Parking a tab is an explicit "not now", which makes it a
# good moment to stop paying for a Claude session that is sitting there: an idle
# one holds 640 MB - 1.4 GB and ~0.5-0.9% of a core (measured 2026-08-22). So a
# parked window holding exactly one agent is SIGTERMed — which exits cleanly and
# reaps its MCP children — and `claude --resume` puts it back, full context
# intact, when the tab is unparked. Never SIGSTOP: it frees no memory at all and
# leaves the TUI permanently unable to read input.
#
# Everything needed to resume is stored ON the window, like @stash_origin, so
# there is still no state file to go stale or be orphaned.
#
#   stash.sh stash   [<window>]   park it (default: current)
#   stash.sh unstash [<window>]   bring one back; picker if several are parked
#   stash.sh count                how many are parked (for the status line)
#   stash.sh list                 what is parked, and where each came from
set -uo pipefail

HOLD=stash          # the detached holding session

# Absolute, because this script re-enters itself inside a popup and
# `display-popup` does NOT expand #{...} formats in its command the way
# run-shell does — a `#{HOME}/...` path reaches the popup's shell literally,
# fails to exec, and the popup vanishes instantly with no error anywhere.
SELF="$HOME/.config/tmux/scripts/stash.sh"

SESS_DIR="$HOME/.claude/sessions"
TERM_WAIT=12          # seconds to allow for a graceful exit
RESUME_WAIT=90        # a big transcript takes a while to replay before it registers
ACTIVE_SECS=15        # a transcript written this recently means a turn is in flight

# Records are delimited with the unit separator, NOT a tab: bash treats tab as
# IFS whitespace and collapses runs of it, so a session that has not reported a
# `status` yet loses that empty field and every later field shifts left.
SEP=$'\x1f'

hold_exists() { tmux has-session -t "=$HOLD" 2>/dev/null; }
count()       { hold_exists && tmux list-windows -t "=$HOLD" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ' || echo 0; }
msg()         { tmux display-message "stash: $*" 2>/dev/null; }

# Notes about what suspension decided go to a file, not over the tab bar. They
# explain a non-event ("parked, but left the agent running because…") which is
# worth being able to look up and not worth interrupting for.
LOGFILE="$HOME/Library/Logs/tmux-stash.log"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOGFILE" 2>/dev/null; }

# The status line reads @stash_count, which is written here on every change
# rather than polled with a #() shell call. A #() in the status format re-forks
# on every redraw forever; this forks only when you actually park or restore
# something, which on an idle machine is never.
publish() { tmux set-option -g @stash_count "$(count)" 2>/dev/null; }

# --- agent suspend / resume ---------------------------------------------------

# Live claude sessions, one per line, $SEP-delimited:
#   pid · sessionId · status · statusEpoch · window · pane · cwd
# The session file's own "tmux" field is "session:@win.%pane", so the window id
# is authoritative — and it does not change when a window moves between
# sessions, which is exactly what parking does.
live_sessions() {
    python3 - "$SESS_DIR" <<'PY' 2>/dev/null
import json, os, sys, glob
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
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

transcript_mtime() {
    local f
    f=$(find "$HOME/.claude/projects" -name "$1.jsonl" -maxdepth 2 2>/dev/null | head -1)
    [ -n "$f" ] && stat -f %m "$f" 2>/dev/null || echo 0
}

# Is a turn in flight? `status` is authoritative while fresh; the transcript is
# appended per message, so a very recent write means something is happening now
# whatever the field says. Stale-BUSY only over-refuses (safe); stale-IDLE is
# the dangerous direction, which the mtime check covers.
is_working() {
    local status="$1" sid="$2" mt
    [ "$status" = "busy" ] && return 0
    mt=$(transcript_mtime "$sid")
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    [ "$mt" -gt 0 ] && [ $(( $(date +%s) - mt )) -lt "$ACTIVE_SECS" ]
}

# Text typed but not submitted lives only in the TUI's buffer and dies with the
# process. The composer is the band between the LAST TWO horizontal rules — not
# the text after the last one, which is the model/context status line and is
# never empty.
has_unsent_input() {
    tmux capture-pane -p -t "$1" 2>/dev/null | awk '
        { line[NR] = $0; if ($0 ~ /^─────/) { prev = last; last = NR } }
        END {
            if (!prev) exit 1
            for (i = prev + 1; i < last; i++) {
                s = line[i]
                gsub(/^[[:space:]]*❯[[:space:]]*/, "", s)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
                if (s != "") exit 0
            }
            exit 1
        }'
}

# Best-effort: parking always succeeds, suspending is the bonus. Anything
# uncertain leaves the agent running inside the parked window, which costs
# memory but can never lose work.
suspend_agent() {
    local win="$1" n=0 pid sid status supd w pane cwd
    local a_pid="" a_sid="" a_pane="" a_cwd="" a_status=""
    while IFS="$SEP" read -r pid sid status supd w pane cwd; do
        [ "$w" = "$win" ] || continue
        n=$((n + 1)); a_pid=$pid; a_sid=$sid; a_pane=$pane; a_cwd=$cwd; a_status=$status
    done < <(live_sessions)

    [ "$n" -eq 0 ] && return 0                      # no agent — nothing to do
    # More than one agent in a window is ambiguous to put back, so leave it be
    # rather than guess which pane each resume belongs in.
    [ "$n" -gt 1 ] && { log "window holds $n agents — left running"; return 0; }

    is_working "$a_status" "$a_sid" && { log "agent is mid-turn — left running"; return 0; }
    has_unsent_input "$a_pane"      && { log "unsent input in the composer — left running"; return 0; }
    # A backgrounded workflow outlives its turn and computer-use spans turns;
    # both would die with the process. The tab watcher already tracks these.
    [ -n "$(tmux show -wqv -t "$win" @agent_workflow 2>/dev/null)" ] && { log "background workflow running — left running"; return 0; }
    [ -n "$(tmux show -wqv -t "$win" @agent_cua 2>/dev/null)" ] && { log "driving an app — left running"; return 0; }

    # Recorded BEFORE the kill: claude deletes its own session file on exit, so
    # afterwards there is nothing left that knows the sessionId.
    tmux set-option -w -t "$win" @stash_session "$a_sid"
    tmux set-option -w -t "$win" @stash_cwd "$a_cwd"

    kill -TERM "$a_pid" 2>/dev/null
    local i=0
    while [ "$i" -lt "$TERM_WAIT" ] && kill -0 "$a_pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done

    if kill -0 "$a_pid" 2>/dev/null; then
        # Never leave a claim that an agent is suspended when it is not.
        tmux set-option -uw -t "$win" @stash_session 2>/dev/null
        tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
        log "agent $a_pid did not exit — left running"
    fi
    return 0
}

resume_agent() {
    local win="$1" sid cwd pane pane_pid
    sid=$(tmux show -wqv -t "$win" @stash_session 2>/dev/null)
    [ -n "$sid" ] || return 0
    cwd=$(tmux show -wqv -t "$win" @stash_cwd 2>/dev/null)
    pane=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | head -1)
    [ -n "$pane" ] || return 1

    # Only type into a shell sitting at a prompt. The test is "the pane's shell
    # has no child", NOT a name match on #{pane_current_command}: claude sets
    # its process title to its own version string, so that field reads e.g.
    # `2.1.241` and keeps reading it briefly after the process is gone.
    pane_pid=$(tmux display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
    if [ -z "$pane_pid" ] || pgrep -P "$pane_pid" >/dev/null 2>&1; then
        msg "pane is busy — agent not resumed (prefix+h again once it's at a prompt)"
        return 1
    fi

    local cmd
    printf -v cmd 'cd %q && claude --resume %q' "${cwd:-$HOME}" "$sid"
    tmux send-keys -t "$pane" C-u
    tmux send-keys -t "$pane" "$cmd" Enter

    # Only drop the record once the session is actually back: it is the sole
    # remaining pointer to that conversation, and a resume can take a while on a
    # large transcript.
    local waited=0
    while [ "$waited" -lt "$RESUME_WAIT" ]; do
        sleep 2; waited=$((waited + 2))
        if live_sessions | grep -q "${SEP}${sid}${SEP}"; then
            tmux set-option -uw -t "$win" @stash_session 2>/dev/null
            tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
            return 0
        fi
    done
    msg "agent did not come back after ${RESUME_WAIT}s — its session id is still on the tab"
    return 1
}

do_stash() {
    local win="${1:-$(tmux display-message -p '#{window_id}')}"
    local sess; sess=$(tmux display-message -p -t "$win" '#{session_name}')

    # Never strand a client: taking a session's last window destroys it, and
    # detach-on-destroy is on here, so that would drop the attached client to
    # the shell.
    if [ "$(tmux list-windows -t "=$sess" -F '#{window_id}' | wc -l | tr -d ' ')" -le 1 ]; then
        msg "that's the only tab in this session — not parking it"
        return 1
    fi
    case "$sess" in "$HOLD") msg "already parked"; return 0 ;; esac

    # Origin travels with the window (see header). The label is captured too:
    # @agent_summary is maintained by the tab watcher and gets cleared once the
    # agent it describes is gone, so without this the picker would list a
    # suspended session as plain "zsh".
    tmux set-option -w -t "$win" @stash_origin "$sess"
    local label; label=$(tmux show -wqv -t "$win" @agent_summary 2>/dev/null)
    [ -n "$label" ] && tmux set-option -w -t "$win" @stash_label "$label"

    local boot=""
    if ! hold_exists; then
        # A session cannot be created empty, so it is born with a placeholder
        # that is killed once the real window is inside. The session then dies
        # by itself when the last window leaves — no lingering idle shell.
        tmux new-session -d -s "$HOLD" -n _bootstrap
        boot=$(tmux list-windows -t "=$HOLD" -F '#{window_id}' | head -1)
    fi

    tmux move-window -s "$win" -t "$HOLD": || { msg "could not park it"; return 1; }
    [ -n "$boot" ] && tmux kill-window -t "$boot" 2>/dev/null
    publish

    # After the move, so the tab disappears immediately and the (slower)
    # graceful shutdown happens out of sight.
    suspend_agent "$win"
}

do_unstash() {
    local win="${1:-}"
    hold_exists || { msg "nothing is parked"; return 0; }

    if [ -z "$win" ]; then
        if [ "$(count)" -gt 1 ]; then
            # fzf needs a terminal, so the choosing happens inside a popup that
            # re-enters this script as `pick`. Deciding here rather than in an
            # if-shell in tmux.conf keeps the branch in one place and avoids a
            # second layer of shell quoting inside a tmux command string.
            tmux display-popup -E -w 60% -h 60% "$SELF pick"
            return 0
        fi
        win=$(tmux list-windows -t "=$HOLD" -F '#{window_id}' | head -1)
    fi

    # Home if it still exists, otherwise wherever we are now — a parked window
    # must never become unreachable because its origin session was closed.
    local origin; origin=$(tmux show -wqv -t "$win" @stash_origin 2>/dev/null)
    if [ -z "$origin" ] || ! tmux has-session -t "=$origin" 2>/dev/null; then
        origin=$(tmux display-message -p '#{session_name}')
    fi

    tmux move-window -s "$win" -t "$origin": || { msg "could not bring it back"; return 1; }
    tmux set-option -uw -t "$win" @stash_origin 2>/dev/null
    tmux set-option -uw -t "$win" @stash_label 2>/dev/null
    tmux select-window -t "$win" 2>/dev/null
    publish
    resume_agent "$win"
}

# Runs inside the popup, where there is a real terminal for fzf.
do_pick() {
    local win
    win=$(tmux list-windows -t "=$HOLD" \
            -F '#{window_id}	#{?#{@stash_label},#{@stash_label},#{?#{@agent_summary},#{@agent_summary},#{window_name}}}	#{pane_current_path}' \
          | fzf --with-nth=2.. --delimiter='\t' --reverse --prompt='bring back > ' \
          | cut -f1)
    [ -n "$win" ] && do_unstash "$win"
}

do_list() {
    hold_exists || { echo "nothing parked"; return 0; }
    tmux list-windows -t "=$HOLD" \
        -F '  #{window_id}  from=#{?#{@stash_origin},#{@stash_origin},?}  #{?#{@stash_session},[suspended] ,}#{?#{@stash_label},#{@stash_label},#{?#{@agent_summary},#{@agent_summary},#{window_name}}}'
}

case "${1:-}" in
    stash)   shift; do_stash "${1:-}" ;;
    unstash) shift; do_unstash "${1:-}" ;;
    count)   count ;;
    publish) publish ;;
    pick)    do_pick ;;
    list)    do_list ;;
    *)       sed -n '/^#   stash.sh/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d' ;;
esac
