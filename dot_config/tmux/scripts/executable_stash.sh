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
#   stash.sh stash   [<window>]   park it (default: current)
#   stash.sh unstash [<window>]   bring one back; picker if several are parked
#   stash.sh count                how many are parked (for the status line)
#   stash.sh list                 what is parked, and where each came from
set -uo pipefail

HOLD=stash          # the detached holding session

hold_exists() { tmux has-session -t "=$HOLD" 2>/dev/null; }
count()       { hold_exists && tmux list-windows -t "=$HOLD" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ' || echo 0; }
msg()         { tmux display-message "stash: $*" 2>/dev/null; }

# The status line reads @stash_count, which is written here on every change
# rather than polled with a #() shell call. A #() in the status format re-forks
# on every redraw forever; this forks only when you actually park or restore
# something, which on an idle machine is never.
publish() { tmux set-option -g @stash_count "$(count)" 2>/dev/null; }

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

    # Origin travels with the window (see header).
    tmux set-option -w -t "$win" @stash_origin "$sess"

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
    msg "parked ($(count) hidden) — prefix+h to bring back"
}

do_unstash() {
    local win="${1:-}"
    hold_exists || { msg "nothing is parked"; return 0; }

    if [ -z "$win" ]; then
        local n; n=$(count)
        if [ "$n" = 1 ]; then
            win=$(tmux list-windows -t "=$HOLD" -F '#{window_id}' | head -1)
        else
            # More than one: pick. Popup + fzf, matching the picker style
            # already used for sessions (prefix+a).
            win=$(tmux list-windows -t "=$HOLD" -F '#{window_id}	#{window_name}	#{?#{@agent_summary},#{@agent_summary},#{pane_current_path}}' \
                  | fzf --with-nth=2.. --delimiter='\t' --height=100% --reverse \
                        --prompt='bring back > ' 2>/dev/null | cut -f1)
            [ -n "$win" ] || return 0
        fi
    fi

    # Home if it still exists, otherwise wherever we are now — a parked window
    # must never become unreachable because its origin session was closed.
    local origin; origin=$(tmux show -wqv -t "$win" @stash_origin 2>/dev/null)
    if [ -z "$origin" ] || ! tmux has-session -t "=$origin" 2>/dev/null; then
        origin=$(tmux display-message -p '#{session_name}')
    fi

    tmux move-window -s "$win" -t "$origin": || { msg "could not bring it back"; return 1; }
    tmux set-option -uw -t "$win" @stash_origin 2>/dev/null
    tmux select-window -t "$win" 2>/dev/null
    publish
    msg "restored"
}

do_list() {
    hold_exists || { echo "nothing parked"; return 0; }
    tmux list-windows -t "=$HOLD" \
        -F '  #{window_id}  from=#{?#{@stash_origin},#{@stash_origin},?}  #{?#{@agent_summary},#{@agent_summary},#{window_name}}'
}

case "${1:-}" in
    stash)   shift; do_stash "${1:-}" ;;
    unstash) shift; do_unstash "${1:-}" ;;
    count)   count ;;
    publish) publish ;;
    list)    do_list ;;
    *)       sed -n '/^#   stash.sh/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d' ;;
esac
