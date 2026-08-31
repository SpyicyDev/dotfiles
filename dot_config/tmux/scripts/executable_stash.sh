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
#   stash.sh stash-many <w>...    park a group in one transaction
#   stash.sh unstash-many <w>...  bring a group back in one transaction
#   stash.sh sel-start here|left|right  start a range at the current tab
#   stash.sh sel-move  left|right grow or shrink it
#   stash.sh sel-cancel           drop the selection
#   stash.sh sel-commit           park everything selected
#   stash.sh count                how many are parked (for the status line)
#   stash.sh list                 what is parked, and where each came from
#   stash.sh restore-state        re-apply parked state after a resurrect restore
set -uo pipefail

HOLD=stash          # the detached holding session

# Absolute, because this script re-enters itself inside a popup and
# `display-popup` does NOT expand #{...} formats in its command the way
# run-shell does — a `#{HOME}/...` path reaches the popup's shell literally,
# fails to exec, and the popup vanishes instantly with no error anywhere.
#
# Overridable so a copy of this script can be exercised against a scratch tmux
# server without the re-entrant calls silently landing back in the installed
# one — which would test the old code and report that the new code passed.
SELF="${STASH_SELF:-$HOME/.config/tmux/scripts/stash.sh}"

SESS_DIR="$HOME/.claude/sessions"
TERM_WAIT=12          # seconds to allow for a graceful exit
RESUME_WAIT=360       # 0.25s ticks => 90s; a big transcript takes a while to replay
ACTIVE_SECS=15        # a transcript written this recently means a turn is in flight

# Records are delimited with the unit separator, NOT a tab: bash treats tab as
# IFS whitespace and collapses runs of it, so a session that has not reported a
# `status` yet loses that empty field and every later field shifts left.
SEP=$'\x1f'

# Serialise the part that reads tmux state and then acts on it. Both binds are
# run-shell, so two presses genuinely run at once, and every check-then-move in
# here was racy: two parks of a two-window session both saw "2 windows", both
# moved, and the second emptied the session — which with detach-on-destroy on
# drops the attached client to a shell.
#
# mkdir is the atomic primitive (there is no flock(1) on macOS). The lock is
# held only across the state-changing section — never across the up-to-12s
# suspend or the up-to-90s resume, which would make one park block the next.
LOCKDIR="${TMPDIR:-/tmp}/tmux-stash.${UID:-$(id -u)}.lock"
LOCK_STALE=30

# The sidecar has its OWN mutex, separate from the one above, because save_state
# is reached from paths that deliberately run unlocked and concurrently (see the
# header on save_state) AND from inside this lock's critical section via
# publish() — one mutex for both would deadlock. There is no lock-ordering cycle
# to worry about: save_state never takes the main lock, so the order is always
# main -> sidecar and never the reverse.
SAVE_LOCKDIR="${TMPDIR:-/tmp}/tmux-stash-save.${UID:-$(id -u)}.lock"

lock_acquire() {
    local dir="${1:-$LOCKDIR}"
    local i=0 owner age
    while :; do
        if mkdir "$dir" 2>/dev/null; then
            # Stamping ownership is part of ACQUIRING, not a formality after it.
            # If the directory is gone by now — a concurrent holder's `rm -rf`
            # racing our mkdir, seen under 10-way contention — we do not hold
            # the lock, and returning anyway would be worse than failing: with
            # no pid file, lock_release refuses to free it and the lock sticks
            # until the stale sweep. Go round again instead.
            # Braces around the redirection: a failing `>` is reported by the
            # SHELL, not by printf, so `printf ... 2>/dev/null` does not silence
            # it and the retry printed a scary path error on every race.
            { printf '%s' "$$" > "$dir/pid"; } 2>/dev/null && return 0
        fi
        i=$((i + 1)); [ "$i" -gt 100 ] && { log "could not take the lock (${dir##*/})"; return 1; }
        owner=$(cat "$dir/pid" 2>/dev/null)
        age=$(( $(date +%s) - $(stat -f %m "$dir" 2>/dev/null || date +%s) ))
        if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || [ "$age" -ge "$LOCK_STALE" ]; then
            # Breaking must itself be atomic. `rm -rf` then `mkdir` is not a
            # compare-and-swap: two processes can both judge the lock stale,
            # both remove it, and both then create it — and the second `rm`
            # deletes the FIRST one's live lock, so both proceed into the
            # critical section holding "the lock". rename(2) has exactly one
            # winner, so only the process that succeeds in moving the stale
            # directory aside is allowed to clear it.
            if mv "$dir" "${dir}.stale.$$" 2>/dev/null; then
                log "broke stale lock (${dir##*/}, owner ${owner:-?}, age ${age}s)"
                rm -rf "${dir}.stale.$$" 2>/dev/null
            fi
        fi
        sleep 0.1
    done
}

# Only ever release a lock we still own. Without the ownership test, a process
# whose lock was broken out from under it would delete whoever holds it now.
lock_release() {
    local dir="${1:-$LOCKDIR}"
    [ "$(cat "$dir/pid" 2>/dev/null)" = "$$" ] || return 0
    rm -rf "$dir" 2>/dev/null
}

hold_exists() { tmux has-session -t "=$HOLD" 2>/dev/null; }

# Close the gap a park leaves behind. `renumber-windows on` only fires when a
# window is CLOSED — moving one to another session is not a close, so parking
# tab 2 of 1,2,3 left 1,3 with a hole in it. `move-window -r` renumbers a
# session sequentially.
#
# Ordering matters: this MUST run before save_state, because the sidecar is
# keyed by window index and renumbering changes it. Callers renumber, then
# publish.
renumber() {
    local sess
    for sess in "$@"; do
        [ -n "$sess" ] || continue
        tmux has-session -t "=$sess" 2>/dev/null || continue
        tmux move-window -r -t "=$sess" 2>/dev/null
    done
}
# The `&&`/`||` form printed TWO lines when tmux failed: wc still printed 0 and
# pipefail then propagated tmux's failure, firing the `|| echo 0` as well. A
# two-line @stash_count broke both the statusline test and `[ "$(count)" -gt 1 ]`.
count() {
    local n
    hold_exists || { printf '0'; return 0; }
    n=$(tmux list-windows -t "=$HOLD" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ')
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}
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
publish() { tmux set-option -g @stash_count "$(count)" 2>/dev/null; save_state; }

# --- surviving a tmux restart -------------------------------------------------
#
# tmux-resurrect already saves the holding session verbatim — its panes and
# windows appear in the save file as `stash` like any other session — so parked
# windows come back parked with no help from us. What it does NOT save is
# WINDOW OPTIONS, and that is where everything this script knows lives:
# @stash_origin (where to put a window back), @stash_label (its name once the
# agent that supplied it is gone) and above all @stash_session, which after a
# suspend is the ONLY remaining pointer to that conversation — claude deletes
# its own ~/.claude/sessions/<pid>.json on the way out.
#
# So the options are mirrored to a sidecar and re-applied by a post-restore
# hook. Written on every state change rather than from resurrect's save hook:
# this set only changes when this script runs, so a save hook would add a
# second writer, an ordering dependency on a hook chain two other things
# already share, and nothing else.
# Follows @resurrect-dir rather than hardcoding a path: the mirror belongs
# beside the save it corresponds to, and a second tmux server on another socket
# (which is how this gets tested) points that option somewhere else precisely so
# it cannot touch the real one.
resurrect_dir() {
    local d; d=$(tmux show -gqv @resurrect-dir 2>/dev/null)
    printf '%s' "${d:-$HOME/.tmux/resurrect}"
}
STATE_FILE=""   # resolved per-call; the server this talks to decides it
state_file() { [ -n "$STATE_FILE" ] || STATE_FILE="$(resurrect_dir)/stash-state.tsv"; printf '%s' "$STATE_FILE"; }

# Does the window at <session>:<index> still look like the one a row describes?
# ONE definition, used by both the save-time merge and the restore-time match,
# so the two can never drift apart. Every recorded attribute must agree —
# index alone is not identity (renumber-windows reshuffles it), and neither
# name nor cwd alone discriminates (every claude window is named for the
# version string; most sessions sit in $HOME).
# Echoes the window id on a match; returns 1 otherwise.
window_for_row() {
    local sess="$1" idx="$2" name="$3" cwd="$4" pidx="${5:-}" win pcwd
    tmux has-session -t "=$sess" 2>/dev/null || return 1
    win=$(tmux list-windows -t "=$sess" -F '#{window_index} #{window_id}' 2>/dev/null \
          | awk -v i="$idx" '$1==i{print $2}')
    [ -n "$win" ] || return 1
    if [ -n "$cwd" ]; then
        # Compare against the AGENT'S pane, not the window's active one.
        # `display-message -t <window-id>` resolves to whichever pane is active,
        # so a multi-pane window whose active pane was an editor elsewhere in
        # the tree failed its own cwd check and got orphaned on every single
        # restart — even though @stash_pane_idx, recorded precisely because the
        # agent may not be pane 0, was sitting right there unused.
        pcwd=""
        if [ -n "$pidx" ]; then
            pcwd=$(tmux list-panes -t "$win" -F '#{pane_index} #{pane_current_path}' 2>/dev/null \
                   | awk -v i="$pidx" '$1==i{ $1=""; sub(/^ /,""); print }')
        fi
        if [ -n "$pcwd" ]; then
            [ "$pcwd" = "$cwd" ] || return 1
        else
            # No recorded pane (or it is gone): accept if ANY pane sits there.
            tmux list-panes -t "$win" -F '#{pane_current_path}' 2>/dev/null | grep -qxF "$cwd" || return 1
        fi
    fi
    if [ -n "$name" ]; then
        [ "$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null)" = "$name" ] || return 1
    fi
    printf '%s' "$win"
}

# SERIALISED, and the tmux snapshot is taken INSIDE the lock.
#
# This is a read-merge-write cycle — snapshot tmux, read the old file, decide
# which old rows to keep, rename a new file over the top — i.e. a textbook
# lost update, and it is reached from several genuinely concurrent unlocked
# callers: the `window-unlinked` hook fires one backgrounded `publish` per
# window MOVED (so a range park fires N+1 of them), and do_unstash_many fires
# one `resume` per window restored, each mirroring whenever its agent registers,
# up to 90s later.
#
# The specific loss, which a reviewer demonstrated and this comment previously
# denied: suspend_agent deliberately records the sessionId and mirrors it BEFORE
# killing the agent, so for that instant the id is on disk, in a window option,
# AND still listed by live_sessions. A concurrent writer whose tmux snapshot
# predates the option therefore reaches "still a live agent? then it needs no
# record" below, drops the row, and renames its copy over the top — moments
# before the kill makes that row the only pointer to the conversation. Nothing
# re-mirrors until the next park or unpark, which may be days.
#
# Taking the lock FIRST and snapshotting after makes each cycle atomic, so a
# writer either sees the option or predates the whole thing; either way the id
# survives. Failing to get the lock is safe to skip: whoever holds it is about
# to write, and their snapshot is newer than ours.
save_state() {
    local sf tmp rows live
    sf=$(state_file)

    lock_acquire "$SAVE_LOCKDIR" || { log "sidecar busy — skipped this mirror"; return 0; }

    # Every window that matters, not just the parked ones. A window can leave
    # the holding session still carrying @stash_session — resume_agent declines
    # when the pane is busy and tells you to try again — and the old version
    # only mirrored windows inside HOLD, so that row was dropped at exactly the
    # moment the window option became the sole surviving pointer.
    rows=$(tmux list-windows -a -F \
        "#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{@stash_pane_idx}${SEP}#{@stash_origin}${SEP}#{@stash_label}${SEP}#{@stash_session}${SEP}#{@stash_cwd}" \
        2>/dev/null) || { lock_release "$SAVE_LOCKDIR"; return 0; }   # tmux unreachable: keep what is on disk
    rows=$(printf '%s\n' "$rows" | awk -F"$SEP" -v hold="$HOLD" '$1==hold || $7!=""')

    # MERGE, never a blind rebuild.
    #
    # This used to regenerate the file purely from live state, so any sid the
    # current server does not know about was simply not written back — and an
    # empty result deleted the file outright. That erased every suspended
    # conversation on the first park after a restart, because window options do
    # not survive a restart and the post-restore hook had not repopulated them
    # yet. Worse, on this machine the hook usually never runs at all: continuum
    # skips auto-restore whenever a second tmux server exists, and there are
    # always agent sockets around. So "restore did not run" is the normal case
    # and the first prefix+H was destroying the file permanently.
    #
    # A sid in the old file that live state cannot account for is therefore
    # kept, not dropped: in the sidecar if its window still plausibly exists
    # and is simply awaiting restore, otherwise in the orphans file where
    # `stash.sh list` prints the command to resume it by hand.
    local of; of=$(orphan_file)
    if [ -f "$sf" ]; then
        local o_sess o_idx o_name o_pidx o_origin o_label o_sid o_cwd
        local fresh_sids; fresh_sids=$(printf '%s\n' "$rows" | awk -F"$SEP" '$7!=""{print $7}')
        # ONCE, not per row: live_sessions reads every session file, and this
        # ran inside the loop — O(rows) interpreter startups while holding a
        # lock, which after a restart (many rows, no options yet) is the slowest
        # thing in the file and was itself widening the race above.
        live=$(live_sessions)
        while IFS="$SEP" read -r o_sess o_idx o_name o_pidx o_origin o_label o_sid o_cwd; do
            [ -n "$o_sid" ] || continue
            printf '%s\n' "$fresh_sids" | grep -qx "$o_sid" && continue   # already represented
            # Still a live agent? Then it is not suspended and needs no record.
            printf '%s\n' "$live" | grep -q "${SEP}${o_sid}${SEP}" && continue
            # Identity, not "some window has that index": after a close,
            # renumber-windows slides a DIFFERENT window into the vacated slot,
            # and carrying the row forward there is exactly how a suspended
            # session's id ends up stamped on someone else.
            if window_for_row "$o_sess" "$o_idx" "$o_name" "$o_cwd" "$o_pidx" >/dev/null; then
                rows="${rows}"$'\n'"${o_sess}${SEP}${o_idx}${SEP}${o_name}${SEP}${o_pidx}${SEP}${o_origin}${SEP}${o_label}${SEP}${o_sid}${SEP}${o_cwd}"
                log "carried forward suspended session ${o_sid%%-*} ($o_sess:$o_idx) — window exists but has no options yet"
            else
                mkdir -p "$(dirname "$of")" 2>/dev/null
                # Append only if this sid is not already parked here. The file is
                # a hand-recovery list, and re-appending the same session on
                # every save turned one lost conversation into eight identical
                # rows — noise that makes `stash.sh list` look like a disaster.
                if ! grep -q "${SEP}${o_sid}${SEP}" "$of" 2>/dev/null; then
                    printf '%s\n' "${o_sess}${SEP}${o_idx}${SEP}${o_name}${SEP}${o_pidx}${SEP}${o_origin}${SEP}${o_label}${SEP}${o_sid}${SEP}${o_cwd}" >> "$of" 2>/dev/null
                    log "suspended session ${o_sid%%-*} has no window any more — moved to $(basename "$of")"
                fi
            fi
        done < "$sf"
    fi

    if [ -z "$rows" ]; then
        rm -f "$sf" 2>/dev/null
        lock_release "$SAVE_LOCKDIR"
        return 0
    fi
    mkdir -p "$(dirname "$sf")" 2>/dev/null
    # Write-then-rename. `> "$sf"` truncates before the command runs, so a
    # single failed list-windows used to leave an EMPTY sidecar and silently
    # drop every suspended conversation's off-server copy at once.
    tmp="${sf}.$$"
    printf '%s\n' "$rows" > "$tmp" 2>/dev/null && mv -f "$tmp" "$sf" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
    lock_release "$SAVE_LOCKDIR"
}

# Rows that could not be safely matched are parked HERE rather than dropped.
# A row carrying a sessionId is the only surviving pointer to a conversation,
# and the previous version's "a mismatch just skips the row" was not the safe
# choice it claimed: the next save_state rebuilds the sidecar from live tmux
# state, so a skipped row was silently erased on the following park.
ORPHAN_FILE=""
orphan_file() { [ -n "$ORPHAN_FILE" ] || ORPHAN_FILE="$(resurrect_dir)/stash-orphans.tsv"; printf '%s' "$ORPHAN_FILE"; }

# Re-attach the options to the windows resurrect just rebuilt.
#
# The window NAME is useless as a discriminator here, which the previous
# version's comment got wrong. automatic-rename is on with format
# #{pane_current_command}, and claude reports its own VERSION STRING as that —
# so every claude window on the machine is called the same thing (verified:
# both tabs read `2.1.241`). Keying on session+index+name therefore degraded to
# session+index for exactly the windows that matter, which is what the fix was
# supposed to stop.
#
# The recorded cwd is the real discriminator: resurrect restores a pane's
# working directory, and a suspended window's shell keeps the agent's. Identity
# has to survive ALL of: the index exists, the cwd matches, and the window is
# not already holding some other session id. Anything less unique is treated as
# unidentifiable and preserved rather than guessed at.
do_restore_state() {
    local sf of; sf=$(state_file); of=$(orphan_file)
    [ -f "$sf" ] || return 0
    local sess idx name pidx origin label sid cwd win wcwd existing kept=""
    while IFS="$SEP" read -r sess idx name pidx origin label sid cwd; do
        [ -n "$sess" ] && [ -n "$idx" ] || continue

        local ok=1
        win=$(window_for_row "$sess" "$idx" "$name" "$cwd" "$pidx") || ok=0
        [ -n "$win" ] || ok=0
        if [ "$ok" = 1 ]; then
            existing=$(tmux show -wqv -t "$win" @stash_session 2>/dev/null)
            [ -z "$existing" ] || [ "$existing" = "$sid" ] || ok=0
        fi

        if [ "$ok" != 1 ]; then
            if [ -n "$sid" ]; then
                # Keep the pointer somewhere durable, and say so loudly.
                kept="${kept}${sess}${SEP}${idx}${SEP}${name}${SEP}${pidx}${SEP}${origin}${SEP}${label}${SEP}${sid}${SEP}${cwd}"$'\n'
                log "could not place suspended session ${sid%%-*} ($sess:$idx) — kept in $(basename "$of"); \`stash.sh list\` shows how to resume it"
            else
                log "skipped $sess:$idx — no matching window"
            fi
            continue
        fi

        [ -n "$origin" ] && tmux set-option -w -t "$win" @stash_origin   "$origin" 2>/dev/null
        [ -n "$label" ]  && tmux set-option -w -t "$win" @stash_label    "$label"  2>/dev/null
        [ -n "$sid" ]    && tmux set-option -w -t "$win" @stash_session  "$sid"    2>/dev/null
        [ -n "$cwd" ]    && tmux set-option -w -t "$win" @stash_cwd      "$cwd"    2>/dev/null
        [ -n "$pidx" ]   && tmux set-option -w -t "$win" @stash_pane_idx "$pidx"   2>/dev/null
        log "restored $sess:$idx${sid:+ — suspended session ${sid%%-*}}"
    done < "$sf"

    if [ -n "$kept" ]; then
        mkdir -p "$(dirname "$of")" 2>/dev/null
        printf '%s' "$kept" >> "$of" 2>/dev/null
    fi
    tmux set-option -g @stash_count "$(count)" 2>/dev/null
}

# --- agent suspend / resume ---------------------------------------------------

# Live claude sessions, one per line, $SEP-delimited:
#   pid · sessionId · status · window · pane · cwd
# The session file's own "tmux" field is "session:@win.%pane", so the window id
# is authoritative — and it does not change when a window moves between
# sessions, which is exactly what parking does.
live_sessions() {
    # Bash builtins, NOT python. This is on the path between prefix+H and the
    # tab disappearing, and python3 startup alone is ~130ms on this machine
    # (measured; the parse itself is nothing). It is also forked by every
    # save_state and by the resume poll every 250ms for up to 90s. The regex
    # version reads the same records in ~1ms with byte-identical output.
    #
    # The session file is one flat JSON object per file, so a first-match
    # regex per field is exact. A missing field is empty, as before, and a
    # malformed file yields an empty record rather than aborting the loop —
    # the bug the python version once had was dropping every LATER file on
    # one bad one. Known limit: a cwd containing an escaped quote would be
    # truncated at it (none exist; JSON-escaping only matters for that).
    local f raw pid sid status t win pane cwd
    for f in "$SESS_DIR"/*.json; do
        [ -f "$f" ] || continue
        raw=$(<"$f") || continue
        pid=""; sid=""; status=""; t=""; cwd=""; win=""; pane=""
        [[ $raw =~ \"pid\":([0-9]+) ]] && pid="${BASH_REMATCH[1]}"
        [[ $raw =~ \"sessionId\":\"([^\"]*)\" ]] && sid="${BASH_REMATCH[1]}"
        [[ $raw =~ \"status\":\"([^\"]*)\" ]] && status="${BASH_REMATCH[1]}"
        [[ $raw =~ \"tmux\":\"([^\"]*)\" ]] && t="${BASH_REMATCH[1]}"
        [[ $raw =~ \"cwd\":\"([^\"]*)\" ]] && cwd="${BASH_REMATCH[1]}"
        # "main:@8.%8" -> win=@8 pane=%8; anything without both separators is
        # an unplaced session and reads as empty, exactly as the python did.
        if [[ $t == *:*.* ]]; then win="${t#*:}"; pane="${win#*.}"; win="${win%%.*}"; fi
        printf '%s\n' "${pid}${SEP}${sid}${SEP}${status}${SEP}${win}${SEP}${pane}${SEP}${cwd}"
    done
}

# Is <pid> a descendant of any pane in <window>? This is the server-local,
# definitive answer to "does this session record belong to THIS window".
#
# ~/.claude/sessions/*.json is machine-global but records only a bare window id,
# and every tmux server numbers windows from @0 — so on this machine, where
# tmux-pty-mcp keeps 7-15 extra sockets alive, a record from another server
# routinely collides with a local window id. The visible symptom today is
# silent: the collision inflates the match count, suspend_agent says "window
# holds 2 agents - left running", and parking simply stops suspending anything
# with no hint that another socket is the reason.
# It also subsumes the stale-record and pid-reuse cases that `kill -0` plus
# `ps -o comm=` would wave through.
# The registered agent living in a window: "pid SEP sid SEP cwd", or nothing.
# Prints only when exactly ONE agent is there — two is ambiguous, and every
# caller treats ambiguity as "leave it alone".
window_agent() {
    local win="$1" pid sid status w pane cwd n=0 out=""
    while IFS="$SEP" read -r pid sid status w pane cwd; do
        [ "$w" = "$win" ] || continue
        pid_in_window "$pid" "$win" || continue
        n=$((n + 1)); out="${pid}${SEP}${sid}${SEP}${cwd}"
    done < <(live_sessions)
    [ "$n" -eq 1 ] && printf '%s' "$out"
    return 0
}
agent_pid_in_window() { local r; r=$(window_agent "$1"); printf '%s' "${r%%"$SEP"*}"; }

pid_in_window() {
    local pid="$1" win="$2" root p guard
    [ -n "$pid" ] && [ -n "$win" ] || return 1
    for root in $(tmux list-panes -t "$win" -F '#{pane_pid}' 2>/dev/null); do
        p="$pid"; guard=0
        while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$guard" -lt 30 ]; do
            [ "$p" = "$root" ] && return 0
            p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
            guard=$((guard + 1))
        done
    done
    return 1
}

# The pid currently registered for a sessionId, or empty. Identity, not mere
# existence — see the poll in resume_agent.
sid_pid() {
    local sid="$1" pid rest
    [ -n "$sid" ] || return 0
    while IFS="$SEP" read -r pid rest; do
        case "$rest" in "$sid$SEP"*) printf '%s' "$pid"; return 0 ;; esac
    done < <(live_sessions)
    return 0
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
    local status="$1" sid="$2" pid="$3" win="${4:-}" mt tab
    [ "$status" = "busy" ] && return 0
    # claude holds a `caffeinate -i -t 300` child while it works. Its 300s timer
    # means it lingers ~5min past a turn, which made it a bad signal for an
    # idle-timer — but here it is exactly right: parking is explicit, and the
    # only cost of a stale caffeinate is leaving an agent running, the safe
    # direction. It is also the ONLY guard that catches a long silent tool call
    # (a build, a test suite, a subagent), which writes no transcript for
    # minutes and has no `status` field on a session that never reported one.
    if [ -n "$pid" ] && ps -eo ppid=,command= 2>/dev/null \
         | awk -v r="$pid" '$1==r && $2 ~ /(^|\/)caffeinate$/{f=1} END{exit !f}'; then
        return 0
    fi
    # The TAB'S OWN STATE settles it when it has an opinion, and the transcript
    # mtime below is only the fallback for when it does not.
    #
    # The mtime check is a proxy for "a turn is in flight", and it is a bad one
    # at the exact moment parking happens: a transcript write 2s before the
    # press reads identical whether the turn is starting or has just finished.
    # Measured — resuming a session and hiding it 19s later left it hidden AND
    # still running, because startup wrote the transcript 2s before the press
    # while `status` said idle and no caffeinate child existed. Hidden-but-alive
    # is the one outcome parking exists to prevent.
    #
    # Trusting the tab here is safe in a way that trusting it for the KILL
    # decision alone would not be, because it is not consulted alone: `busy`
    # above and the caffeinate child are both still checked first, and
    # caffeinate is the strong one — claude holds it for the whole turn and it
    # lingers ~300s after, so a genuinely in-flight turn is caught there even if
    # the watcher has died and frozen this option at a stale `idle`.
    if [ -n "$win" ]; then
        tab=$(tmux show -wqv -t "$win" @agent_state 2>/dev/null)
        case "$tab" in
            running)                    return 0 ;;   # definitely working
            idle|done|needs-*|failed)   return 1 ;;   # definitely not; skip the proxy
        esac
    fi

    mt=$(transcript_mtime "$sid")
    case "$mt" in ''|*[!0-9]*) mt=0 ;; esac
    [ "$mt" -gt 0 ] && [ $(( $(date +%s) - mt )) -lt "$ACTIVE_SECS" ]
}

# Is a background Workflow still in flight for this session?
#
# Derived from the runtime's own files rather than from @agent_workflow. That
# option is maintained by agent-tab-watcher.sh, so reading it alone means the
# guard FAILS OPEN if the watcher has died — and its own header documents that
# it can disappear silently after days of uptime. A backgrounded workflow
# outlives the turn that started it and would be killed with the process, so
# this is not a guard that may quietly stop working.
#
# The rule (same one the watcher uses): the runtime creates
# subagents/workflows/wf_<id>/ while a workflow runs and only writes
# workflows/<id>.json when it finishes, so live == dir without completion file.
# The 1h mtime backstop is the watcher's too — transcripts go quiet during long
# stalls, and the worst measured gap on this machine was 394s.
# Every runtime directory that can belong to this session — NOT just the one
# named after its sid.
#
# The sid in ~/.claude/sessions/<pid>.json is the id the process was RESUMED
# with, and after a compaction that is no longer where anything is written:
# the continued conversation gets a fresh id, and the live transcript, its
# subagents/ and its workflows/ all move under that one, while the session
# file keeps reporting the old id. Measured 2026-08-25: a process reporting
# 88d5cc09 had two reviewer subagents running under 42a666ca/subagents/, and
# every guard that looked under 88d5cc09/ found nothing and let the park
# SIGTERM it with both reviewers mid-run. `claude --resume <old id>` still
# works (it follows the chain), so the recorded sid is fine for RESUMING —
# it is only wrong for LOOKING.
#
# The chain is not stored anywhere structured, but it has one precise anchor:
# the continued transcript's compaction record — a user entry flagged
# `"isCompactSummary":true` whose text names the old transcript by PATH
# (`…/<old sid>.jsonl`). Match on that, on that line only. A bare search for
# the id was tried first and was wrong: transcripts mention other sessions'
# ids in plain text all the time (a peer's transcript named this one dozens
# of times), and measured, the bare match claimed four false descendants
# where the anchor found exactly the real one. A false descendant is not
# harmless: its running subagents would refuse a park of an unrelated tab.
#
# CHEAP, because this runs BEFORE the move and the user is waiting on it. The
# first version grepped every transcript in the project dir in full — 76 files,
# 198MB on this machine, ~1.5s — and was called twice per park, so prefix+H
# took ~3s to hide a tab. Three cuts, each safe:
#  - Only the HEAD of each file. The cross-file link is the continued
#    transcript's FIRST user record (measured: line 9 of 2078); the compaction
#    records found deeper in files all name the file itself (in-place
#    compactions), which is not a link to anything. 512KB covers any summary.
#  - Only files touched in the last day. Both callers only care about activity
#    within the hour, and a descendant with live work under it was itself
#    written when that work was dispatched.
#  - Once per (sid, cwd) per run. Both callers ask for the same chain.
# Measured after: 383ms for the head scan over ALL files, and the mtime filter
# takes that to ~11 files.
SESSION_DIRS_KEY=""; SESSION_DIRS_VAL=""
session_dirs() {
    local sid="$1" cwd="$2" proj f id out
    [ -n "$sid" ] && [ -n "$cwd" ] || return 0
    if [ "$SESSION_DIRS_KEY" = "${sid}${SEP}${cwd}" ]; then printf '%s' "$SESSION_DIRS_VAL"; return 0; fi
    # Munge the cwd ALONE, then join: applying the `.`→`-` rule to the joined
    # path turned `.claude` into `-claude` and every lookup silently missed.
    proj="${cwd//\//-}"; proj="${proj//./-}"      # claude munges / and . to -
    proj="$HOME/.claude/projects/$proj"
    [ -d "$proj" ] || return 0
    out="$proj/$sid"$'\n'
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        id="${f##*/}"; id="${id%.jsonl}"
        [ "$id" = "$sid" ] && continue
        head -c 524288 "$f" 2>/dev/null | grep -F '"isCompactSummary":true' | grep -qF -- "/$sid.jsonl" \
            && out="${out}${proj}/${id}"$'\n'
    done < <(find "$proj" -maxdepth 1 -name '*.jsonl' -mmin -1440 2>/dev/null)
    SESSION_DIRS_KEY="${sid}${SEP}${cwd}"; SESSION_DIRS_VAL="$out"
    printf '%s' "$out"
}

has_live_workflow() {
    local sid="$1" cwd="$2" base d wfid mt now
    [ -n "$sid" ] && [ -n "$cwd" ] || return 1
    now=$(date +%s)
    while read -r base; do
        [ -d "$base/subagents/workflows" ] || continue
        for d in "$base"/subagents/workflows/wf_*/; do
            [ -d "$d" ] || continue
            wfid="${d%/}"; wfid="${wfid##*/}"
            [ -f "$base/workflows/$wfid.json" ] && continue    # completed
            mt=$(stat -f %m "$d"/agent-*.jsonl "$d/journal.jsonl" 2>/dev/null | sort -rn | head -1)
            [ -n "$mt" ] && [ $((now - mt)) -lt 3600 ] && return 0
        done
    done < <(session_dirs "$sid" "$cwd")
    return 1
}

# Is a background SUBAGENT (the Agent tool, not a Workflow) still running?
#
# These are in-process: no child pid, no caffeinate of their own, and the
# parent's turn has usually ENDED — it dispatched them and replied "I'll report
# back" — so status reads idle, the composer is empty, and every other guard
# here says "safe". They die with the process, and a review that took twenty
# minutes is gone. This is the guard that was missing on 2026-08-25.
#
# There is no completion record to key on (the .meta.json beside each
# transcript is written at SPAWN — agentType, description, model — and never
# updated), only the transcript itself. Rule: a transcript touched in the last
# SUBAGENT_QUIET seconds is in flight regardless of what it says; one touched
# within the hour is in flight unless its last entry is a pure-text assistant
# record — the shape of a delivered report.
#
# The shape test is reliable because content blocks are written ONE RECORD
# EACH, text first (measured over a 9-reviewer workflow: zero records mixing
# text and tool_use), so mid-turn a text record is followed by its tool_use
# record within 2.13s worst-case. 30s of quiet after a pure-text ending is
# therefore finished with ~15x margin. This was 300s as a blanket — which
# locked every tab out of hiding for five minutes after any subagent finished,
# and a 9-reviewer workflow ends staggered, so the lockout kept renewing;
# reported as "it won't let me hide it" on a tab whose work was all done.
# The genuinely-dangerous shape — a subagent silent for minutes INSIDE a tool
# call — still reads live at any age, because its last record is the tool_use.
SUBAGENT_QUIET=30
has_live_subagent() {
    local sid="$1" cwd="$2" base f mt now age last
    [ -n "$sid" ] && [ -n "$cwd" ] || return 1
    now=$(date +%s)
    while read -r base; do
        [ -d "$base/subagents" ] || continue
        for f in "$base"/subagents/agent-*.jsonl; do
            [ -f "$f" ] || continue
            mt=$(stat -f %m "$f" 2>/dev/null); [ -n "$mt" ] || continue
            age=$((now - mt))
            [ "$age" -lt 3600 ] || continue
            [ "$age" -ge "$SUBAGENT_QUIET" ] || return 0
            last=$(tail -c 65536 "$f" 2>/dev/null | tail -n 1)
            case "$last" in
                *'"role":"assistant","content":[{"type":"text"'*) continue ;;
            esac
            return 0
        done
    done < <(session_dirs "$sid" "$cwd")
    return 1
}

# Is this agent driving an app through cua-driver right now? Same reasoning as
# above: read the shim's own activity file rather than trusting @agent_cua,
# which the watcher may not be alive to set.
CUA_ACTIVITY="$HOME/Library/Application Support/CuaNotch/activity.json"
CUA_LIVE=60
has_live_cua() {
    local pid="$1"
    [ -n "$pid" ] && [ -f "$CUA_ACTIVITY" ] || return 1
    # Exit codes are three-valued: 0 driving, 1 not driving, 2 UNREADABLE.
    # The shim rewrites this file on every driver call, so a torn or malformed
    # read is likeliest exactly while the agent IS driving — and here the cost
    # of guessing "not driving" is SIGTERM on an agent mid-run, not a missing
    # glyph as it is in the watcher this was ported from.
    python3 - "$CUA_ACTIVITY" "$pid" "$CUA_LIVE" <<'PY' 2>/dev/null
import json, sys, time
try:
    sessions = json.load(open(sys.argv[1])).get("sessions", {}) or {}
except Exception:
    raise SystemExit(2)
try:
    pid, live, now = int(sys.argv[2]), float(sys.argv[3]), time.time()
    for d in sessions.values():
        if (isinstance(d, dict) and d.get("agent_pid")
                and int(d["agent_pid"]) == pid
                and now - float(d.get("ts") or 0) < live):
            raise SystemExit(0)
except SystemExit:
    raise
except Exception:
    raise SystemExit(2)
raise SystemExit(1)
PY
    local rc=$?
    if [ "$rc" = 2 ]; then
        log "cua activity file unreadable - assuming the agent is driving"
        return 0
    fi
    return "$rc"
}

# Text typed but not submitted lives only in the TUI's buffer and dies with the
# process. The composer is the band between the LAST TWO horizontal rules — not
# the text after the last one, which is the model/context status line and is
# never empty.
has_unsent_input() {
    # An empty target is NOT a no-op in tmux: `-t ''` resolves to the CURRENT
    # pane, so this would have inspected whatever the user was looking at
    # instead of the agent being parked. A session file whose "tmux" field
    # lacks the pane part produces exactly that.
    [ -n "${1:-}" ] || return 0
    local cap
    cap=$(tmux capture-pane -p -t "$1" 2>/dev/null) || return 0
    [ -n "$cap" ] || return 0
    # Fewer than two rules means the composer is not fully on screen (a tall
    # draft pushes the opening rule off, and dialogs replace the band entirely).
    # That is UNKNOWN, and unknown must mean "leave it running" — the previous
    # `exit 1` read it as "no draft" and killed the agent, so the longer the
    # unsent message the likelier it was destroyed.
    printf '%s\n' "$cap" | awk '
        { line[NR] = $0; if ($0 ~ /^─────/) { prev = last; last = NR } }
        END {
            if (!prev) exit 0        # composer not fully visible -> assume a draft
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
    while IFS="$SEP" read -r pid sid status w pane cwd; do
        [ "$w" = "$win" ] || continue
        # Window id alone is per-server and collides across sockets; require the
        # process to actually live in this window.
        pid_in_window "$pid" "$win" || { log "ignoring session record pid $pid — window id $w matches but the process is not in this window (another tmux server?)"; continue; }
        n=$((n + 1)); a_pid=$pid; a_sid=$sid; a_pane=$pane; a_cwd=$cwd; a_status=$status
    done < <(live_sessions)

    [ "$n" -eq 0 ] && return 0                      # no agent — nothing to do
    # More than one agent in a window is ambiguous to put back, so leave it be
    # rather than guess which pane each resume belongs in.
    [ "$n" -gt 1 ] && { log "window holds $n agents — left running"; return 0; }

    # The pid comes from a file claude wrote; a crash or SIGKILL leaves that
    # file behind, and pids get reused. Confirm it is alive AND still claude
    # before signalling it — otherwise SIGTERM goes to an unrelated process.
    if ! kill -0 "$a_pid" 2>/dev/null; then
        log "session record for pid $a_pid is stale (process gone) — nothing to suspend"; return 0
    fi
    # `*node*` was accepted too, which with a stale session file plus pid reuse
    # meant SIGTERM to an unrelated node process — a dev server, an MCP host.
    # claude reports comm=claude; the bare version-string form is allowed
    # because that is how it presents itself elsewhere in this system.
    case "$(ps -p "$a_pid" -o comm= 2>/dev/null)" in
        *claude*) : ;;
        [0-9]*.[0-9]*.[0-9]*) : ;;
        *) log "pid $a_pid is not claude (pid reuse?) — left alone"; return 0 ;;
    esac

    # Never overwrite a sessionId already recorded here: that value can be the
    # only pointer to a DIFFERENT conversation (a resume that was refused
    # leaves one behind), and replacing it loses that one silently.
    local existing; existing=$(tmux show -wqv -t "$win" @stash_session 2>/dev/null)
    if [ -n "$existing" ] && [ "$existing" != "$a_sid" ]; then
        log "window already holds session ${existing%%-*} — not suspending over it"; return 0
    fi

    is_working "$a_status" "$a_sid" "$a_pid" "$win" && { log "agent is mid-turn — left running"; return 0; }
    has_unsent_input "$a_pane"      && { log "unsent input in the composer — left running"; return 0; }
    # A backgrounded workflow outlives its turn and computer-use spans turns;
    # both would die with the process. Checked TWO ways each — the watcher's
    # flag, which is instant but goes stale if the daemon dies, and the
    # underlying files, which are authoritative but cost a little more. Either
    # saying "busy" is enough to leave the agent alone.
    if [ -n "$(tmux show -wqv -t "$win" @agent_workflow 2>/dev/null)" ] || has_live_workflow "$a_sid" "$a_cwd"; then
        log "background workflow still in flight — left running"; return 0
    fi
    if has_live_subagent "$a_sid" "$a_cwd"; then
        log "background subagent still running — left running"; return 0
    fi
    if [ -n "$(tmux show -wqv -t "$win" @agent_cua 2>/dev/null)" ] || has_live_cua "$a_pid"; then
        log "driving an app through cua — left running"; return 0
    fi

    # Recorded BEFORE the kill: claude deletes its own session file on exit, so
    # afterwards there is nothing left that knows the sessionId.
    tmux set-option -w -t "$win" @stash_session "$a_sid"
    tmux set-option -w -t "$win" @stash_cwd "$a_cwd"
    # Which PANE the agent was in. Without this, resume typed into whichever
    # pane happened to be first, which in a multi-pane window can be an editor
    # or REPL — C-u plus a command line straight into an unsaved buffer.
    tmux set-option -w -t "$win" @stash_pane_idx \
        "$(tmux display-message -p -t "$a_pane" '#{pane_index}' 2>/dev/null)"

    # Mirror immediately, BEFORE the kill wait: a server death during the wait
    # would otherwise lose the id that was just written to a volatile option.
    save_state

    # LAST-MOMENT RE-CHECK. do_stash releases the lock before calling this, so
    # between the guards above and here the user can have pressed prefix+h and
    # brought the window home — measured 0.3-0.6s from park to this point, and
    # the guard chain's `find` over ~/.claude/projects dominates it. Killing
    # then would SIGTERM an agent in a window that is focused and back on the
    # tab bar. Re-read the two facts that can have changed rather than
    # re-taking the lock: is it still parked, and is the composer still empty
    # (the earlier check is ~1s stale by now, and anything typed in that second
    # dies with the process).
    if [ "$(tmux display-message -p -t "$win" '#{session_name}' 2>/dev/null)" != "$HOLD" ]; then
        tmux set-option -uw -t "$win" @stash_session 2>/dev/null
        tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
        tmux set-option -uw -t "$win" @stash_pane_idx 2>/dev/null
        save_state
        log "window left the holding session before the kill — not suspending"
        return 0
    fi
    if has_unsent_input "$a_pane"; then
        tmux set-option -uw -t "$win" @stash_session 2>/dev/null
        tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
        tmux set-option -uw -t "$win" @stash_pane_idx 2>/dev/null
        save_state
        log "text appeared in the composer after the first check — left running"
        return 0
    fi
    # And is it STILL not working? The first is_working ran before
    # has_unsent_input, the workflow and subagent walks, the cua fork, three
    # set-options and a save_state — and in a range, before up to TERM_WAIT
    # seconds per window ahead of this one, so ~36s stale on the fourth tab. A
    # turn that started in that gap (a peer's message_agent paste, a queued
    # message dequeuing, a subagent-completion wake) was never re-examined.
    # `status` is the guard that actually holds through a live turn (measured
    # 240/240 samples; caffeinate is a CHAIN of processes with sub-second holes
    # between them), so re-read it fresh rather than trusting the copy.
    local now_status; now_status=$(live_sessions | awk -F"$SEP" -v p="$a_pid" '$1==p{print $3; exit}')
    if is_working "${now_status:-$a_status}" "$a_sid" "$a_pid" "$win"; then
        tmux set-option -uw -t "$win" @stash_session 2>/dev/null
        tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
        tmux set-option -uw -t "$win" @stash_pane_idx 2>/dev/null
        save_state
        log "a turn started after the first check — left running"
        return 0
    fi

    kill -TERM "$a_pid" 2>/dev/null
    local i=0
    while [ "$i" -lt "$TERM_WAIT" ] && kill -0 "$a_pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done

    if kill -0 "$a_pid" 2>/dev/null; then
        # KEEP the record. The earlier version unset it here, reasoning that a
        # process still alive at the timeout had ignored the signal — but
        # SIGTERM has been delivered and cannot be recalled, and an agent with
        # several MCP children to reap can legitimately need longer than
        # TERM_WAIT. Unsetting meant: agent exits at T+15, deletes its own
        # session file, and the sole pointer to that conversation has already
        # been thrown away by the code whose comment claimed to be protecting
        # it. A window wrongly marked suspended is harmless and self-correcting
        # (resume_agent notices the pane is busy and says so); a killed agent
        # with no session id is not recoverable at all.
        log "agent $a_pid still exiting after ${TERM_WAIT}s — keeping its session id"
    fi
    return 0
}

resume_agent() {
    # pane/pane_pid are INITIALISED, not merely declared: `local pane` leaves it
    # unset, and under `set -u` the `[ -n "$pane" ]` fallback below then aborts
    # the whole resume — which is the path taken whenever @stash_pane_idx is
    # absent, i.e. every window restored from a sidecar written before it
    # existed, and every pending resume.
    local win="$1" sid cwd pane="" pane_pid=""
    sid=$(tmux show -wqv -t "$win" @stash_session 2>/dev/null)
    [ -n "$sid" ] || return 0
    cwd=$(tmux show -wqv -t "$win" @stash_cwd 2>/dev/null)
    local pidx; pidx=$(tmux show -wqv -t "$win" @stash_pane_idx 2>/dev/null)
    if [ -n "$pidx" ]; then
        pane=$(tmux list-panes -t "$win" -F '#{pane_index} #{pane_id}' 2>/dev/null \
               | awk -v i="$pidx" '$1==i{print $2}')
    fi
    [ -n "$pane" ] || pane=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | head -1)
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

    # No `${cwd:-$HOME}` fallback: `claude --resume <id>` only finds a session
    # under the project dir it was recorded in, so guessing $HOME produces a
    # confusing "no such session" instead of an honest refusal.
    if [ -z "$cwd" ]; then
        msg "no working directory recorded — resume by hand: claude --resume $sid"
        return 1
    fi
    # Whoever owns this sid right now — normally nobody, but if we are racing a
    # still-exiting claude it is the CORPSE's pid. A SIGTERMed claude keeps its
    # ~/.claude/sessions/<pid>.json for seconds while it reaps MCP children, so
    # "the sid appears in live_sessions" was satisfied by the dying process and
    # the poll below declared success, cleared @stash_session, and mirrored the
    # erasure — then claude exited and deleted its own file, taking the last
    # copy of the pointer with it. A resumed agent is a NEW process, so require
    # the pid to differ.
    local before_pid; before_pid=$(sid_pid "$sid")

    local cmd
    printf -v cmd 'cd %q && claude --resume %q' "$cwd" "$sid"
    tmux send-keys -t "$pane" C-u
    tmux send-keys -t "$pane" "$cmd" Enter

    # Only drop the record once the session is actually back: it is the sole
    # remaining pointer to that conversation, and a resume can take a while on a
    # large transcript.
    # Check BEFORE sleeping, in short steps: the old form paid a flat 2s even
    # when the agent was already back.
    local waited=0
    while :; do
        # Process substitution, not a pipe: `grep -q` exits at the first match,
        # and with pipefail a SIGPIPE'd python makes the pipeline nonzero even
        # though the session WAS found — reporting failure for a live resume.
        # By WINDOW, not by sid. A resumed process does not reliably register
        # under the id it was resumed with: after a compaction it reports the
        # continued conversation's new id, so `sid_pid "$sid"` never matched, the
        # poll ran out its 90s, and the record stayed on the tab — where the next
        # park read "window already holds a session" and silently refused to
        # suspend it, forever. Any agent that appears in this window and is not
        # the one we killed IS the comeback, whatever id it reports.
        local now_pid; now_pid=$(agent_pid_in_window "$win")
        if [ -n "$now_pid" ] && [ "$now_pid" != "$before_pid" ]; then
            # Do not erase a record that is no longer ours: the window may have
            # been re-parked and re-suspended while we polled (we run unlocked,
            # in the background), in which case @stash_session now belongs to
            # that newer suspend.
            if [ "$(tmux show -wqv -t "$win" @stash_session 2>/dev/null)" != "$sid" ]; then
                log "resume of ${sid%%-*} finished but the window moved on — leaving its record alone"
                return 0
            fi
            tmux set-option -uw -t "$win" @stash_session 2>/dev/null
            tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
            tmux set-option -uw -t "$win" @stash_pane_idx 2>/dev/null
            save_state
            return 0
        fi
        [ "$waited" -ge "$RESUME_WAIT" ] && break
        sleep 0.25; waited=$((waited + 1))
    done
    msg "agent did not come back — its session id is still on the tab (stash.sh list)"
    return 1
}

# A session cannot be created empty, so it is born with a placeholder that is
# killed once the real windows are inside; the session then dies by itself when
# the last window leaves, so nothing idles in the background.
#
# `-P -F` is load-bearing: it reports the id of the window this call actually
# created. Taking "the first window in the stash session" instead meant that if
# new-session FAILED because the session already existed — which two concurrent
# `prefix+H` presses reliably produce, since the bind is run-shell -b and both
# see hold_exists as false — `boot` resolved to somebody else's ALREADY-PARKED
# window, and the kill below destroyed it, panes, scrollback, suspended agent
# and all. Reproduced during review.
#
# Reports the placeholder in BOOT_WIN (empty if it created nothing) so the
# caller can take it back out again if nothing ends up parked.
BOOT_WIN=""
ensure_hold() {
    BOOT_WIN=""
    hold_exists && return 0
    BOOT_WIN=$(tmux new-session -d -s "$HOLD" -n _bootstrap -P -F '#{window_id}' 2>/dev/null) || BOOT_WIN=""
    return 0
}

# Move one window into the holding session. Assumes the lock is held and the
# holding session already exists.
park_one() {
    local win="$1" sess="$2" label
    # Invariant, enforced here rather than trusted from callers: nothing inside
    # the holding session is ever flagged as selected. @stash_sel is a window
    # option, so it survives the move and would repaint the tab mauve when it
    # comes back — with no selection in progress to explain why.
    tmux set-option -uw -t "$win" @stash_sel 2>/dev/null
    # Origin travels with the window (see header). The label is captured too:
    # @agent_summary is maintained by the tab watcher and gets cleared once the
    # agent it describes is gone, so without this the picker would list a
    # suspended session as plain "zsh".
    tmux set-option -w -t "$win" @stash_origin "$sess"
    label=$(tmux show -wqv -t "$win" @agent_summary 2>/dev/null)
    [ -n "$label" ] && tmux set-option -w -t "$win" @stash_label "$label"

    tmux move-window -s "$win" -t "$HOLD": 2>/dev/null && return 0

    # A window still sitting on the tab bar must not be left claiming it was
    # parked: @stash_origin is what `list` and the restore hook read, and a
    # stale one describes a park that never happened.
    tmux set-option -uw -t "$win" @stash_origin 2>/dev/null
    tmux set-option -uw -t "$win" @stash_label 2>/dev/null
    return 1
}

# Is this window's agent working right now, per the TAB'S OWN STATE?
#
# Reads the options the tab watcher maintains — the same ones the tab bar
# renders — rather than re-deriving from session files. That is a deliberate
# exception to the rule has_live_workflow follows (never trust a watcher option,
# it fails open if the watcher dies), and the difference is which way the
# failure points: this gates a REFUSAL, not a kill. A dead watcher frozen at
# `running` merely declines to hide the tab, which costs nothing; frozen at
# `idle` the tab parks and suspend_agent's own guards — status, the caffeinate
# child, the transcript — still stand between it and a SIGTERM. Nothing here can
# end a turn.
#
# `running` is the state; @agent_workflow and @agent_cua are the two "in flight
# but the chip cannot say so" cases from the same family. needs-input, failed
# and done are NOT running — those are precisely the tabs worth tidying away.
# Sets AGENT_RUNNING_WHY so refusals can be logged with a reason — a silent
# "still working" on a tab that looks done is undebuggable from the outside.
AGENT_RUNNING_WHY=""
agent_running() {
    local win="$1" rec pid sid cwd tab flagged=0
    AGENT_RUNNING_WHY=""
    tab=$(tmux show -wqv -t "$win" @agent_state 2>/dev/null)
    case "$tab" in
        ""|idle|done|needs-*|failed) : ;;
        # `running`, and anything this script has never heard of. A state the
        # watcher grows later must read as "working" here — is_working treats
        # the unknown as unknown and falls back to its proxies, but a refusal
        # has nothing to fall back to, so it errs the harmless way.
        *) flagged=1 ;;
    esac
    [ -n "$(tmux show -wqv -t "$win" @agent_workflow 2>/dev/null)" ] && flagged=1
    [ -n "$(tmux show -wqv -t "$win" @agent_cua 2>/dev/null)" ] && flagged=1
    # The one escape hatch a tab-derived refusal needs: the watcher can die
    # (its own header says so) with `running` frozen on a window whose agent
    # has long since exited — and that window would then be unparkable forever,
    # with a message that is a lie. A flag only counts if an agent is actually
    # registered in the window; a bare shell under a stale flag parks normally.
    if [ "$flagged" = "1" ]; then
        if [ -n "$(window_agent "$win")" ]; then
            AGENT_RUNNING_WHY="tab state [${tab:-flag}] with a live agent registered"
            return 0
        fi
        return 1
    fi
    # No file-derived checks here any more — the tab settles it. They were
    # added when the tab was BLIND to background work (the watcher derived a
    # session's runtime dir from the pre-compaction id, so two in-flight
    # reviewers showed no gear and a park SIGTERMed them), and they cost real
    # things: pre-move latency the user sits through, and a lockout window
    # after a subagent finishes that the watcher's own finished-rule does not
    # have (it clears the gear when the parent is TOLD the result — the
    # authoritative signal; watcher commit c554ffa also follows the
    # compaction chain now). With the blindness fixed, duplicating the lookup
    # here buys nothing on the good days and five minutes of "won't hide" on
    # the staggered end of a review fleet.
    #
    # The failure this accepts: watcher dead or one tick behind at the moment
    # of the press → the tab parks with work in flight. That lands on
    # suspend_agent, which keeps EVERY deep guard (status, caffeinate, the
    # lineage-aware workflow/subagent walks, the last-moment re-check) — so
    # the outcome is hidden-but-left-running with a logged reason, never a
    # killed turn, and prefix+h brings it straight back.
    return 1
}

# Park one or more windows as a single transaction: one lock, one renumber, one
# publish. Looping the single-window path instead would take and drop the lock
# per window, renumber per window, and let another park interleave halfway
# through a group the user selected as one unit.
do_stash_many() {
    local w s sess="" wins=() total busy=0 seen="" note=""

    # Everything from here to the moves reads tmux state and then acts on it, so
    # it runs under the lock. Released before the suspends, which are slow and
    # touch only windows that are already parked.
    lock_acquire || { msg "busy — try again"; return 0; }   # 0: see the note on the refusal below

    # Resolve membership UNDER the lock. These ids come from a keypress that may
    # be seconds old by now, so in between a window can have been closed, parked
    # by another press, or moved to another session.
    for w in "$@"; do
        [ -n "$w" ] || continue
        s=$(tmux display-message -p -t "$w" '#{session_name}' 2>/dev/null) || continue
        [ -n "$s" ] || continue
        case "$s" in "$HOLD") continue ;; esac                # already parked
        [ -n "$sess" ] || sess="$s"
        [ "$s" = "$sess" ] || continue                        # a range is one session by construction
        # De-dupe against everything SEEN, not just what was accepted: a busy
        # window is never appended to wins, so testing wins let `@5 @5` count
        # one working agent twice and report "all 2 of those agents".
        case " $seen " in *" $w "*) continue ;; esac
        seen="$seen $w"
        # Refuse to hide a working agent at all, rather than hiding it and then
        # declining to suspend it. That combination is the worst of both: the
        # tab is gone from the bar AND still holding its ~1GB and its share of a
        # core, with nothing on screen to say so. Parking is an explicit "not
        # now", and "not now" is not a thing to say to a turn in flight.
        if agent_running "$w"; then
            log "refused to hide $w — $AGENT_RUNNING_WHY"
            busy=$((busy + 1)); continue
        fi
        wins+=("$w")
    done

    if [ "${#wins[@]}" -eq 0 ]; then
        lock_release
        if [ "$busy" -eq 1 ]; then
            msg "that agent is still working — not hiding it"
        elif [ "$busy" -gt 1 ]; then
            msg "all $busy of those agents are still working — not hiding them"
        else
            msg "already parked"
        fi
        return 0
    fi

    # Never strand a client: taking a session's last window destroys it, and
    # detach-on-destroy is on here, so that would drop the attached client to
    # the shell. Counted INSIDE the lock — two concurrent parks both saw "2
    # windows" and both moved, and the second one emptied the session.
    total=$(tmux list-windows -t "=$sess" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ')
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    if [ "$total" -le "${#wins[@]}" ]; then
        lock_release
        if [ "${#wins[@]}" -eq 1 ]; then
            msg "that's the only tab in this session — not parking it"
        else
            # Refused rather than quietly parking all but one: a partial result
            # nobody asked for is worse than a clear no.
            msg "that's every tab in this session — leave one out and try again"
        fi
        # 0, NOT 1. `run-shell` displays the exit status of a failed command IN
        # THE PANE — which puts it into view-mode, so every subsequent keystroke
        # goes to copy-mode's key table instead of whatever is running there
        # until the user presses q. `-b` does not exempt it. A refusal the user
        # has already been told about via msg() is not a script failure, and
        # hijacking the focused pane to report it is far worse than the refusal.
        return 0
    fi

    ensure_hold
    local parked=() failed=0 left
    for w in "${wins[@]}"; do
        # Re-check per move, not just once up front. The count above cannot be
        # fooled by duplicates or foreign ids, but nothing stops a window
        # CLOSING on its own between the count and the last move — a shell
        # exiting is not a stash.sh actor and the lock cannot hold it back. With
        # a range that is "N of N+1", so one exit is enough to leave the session
        # empty, and destroying it drops the attached client to a shell.
        left=$(tmux list-windows -t "=$sess" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ')
        case "$left" in ''|*[!0-9]*) left=0 ;; esac
        if [ "$left" -le 1 ]; then
            # Noted, not shown yet: display-message has no queue, each call
            # overwrites the last, so every partial result is composed into ONE
            # message at the end or only the final fragment is ever seen.
            note="stopped — the rest is all that's left in this session"
            break
        fi
        if park_one "$w" "$sess"; then parked+=("$w"); else failed=$((failed + 1)); fi
    done

    if [ "${#parked[@]}" -eq 0 ]; then
        # If this call created the holding session and then failed to put
        # anything in it, take the placeholder back out rather than leaving a
        # session whose only window is a stray shell that `count` reports as
        # parked and the next prefix+h would hand you.
        [ -n "$BOOT_WIN" ] && tmux kill-window -t "$BOOT_WIN" 2>/dev/null
        lock_release
        # Say WHY nothing was parked. "could not park it" on a batch where two
        # tabs were deliberately left working and the third refused to move is
        # both incomplete and, in the stopped case, simply wrong.
        if [ -n "$note" ]; then
            msg "nothing hidden: $note"
        elif [ "$busy" -gt 0 ]; then
            msg "could not park it — and left $busy still working"
        else
            msg "could not park it"
        fi
        return 0
    fi
    # Only ever kill a window this invocation created, and never one just parked.
    if [ -n "$BOOT_WIN" ]; then
        case " ${parked[*]} " in
            *" $BOOT_WIN "*) : ;;
            *) tmux kill-window -t "$BOOT_WIN" 2>/dev/null ;;
        esac
    fi
    renumber "$sess" "$HOLD"
    publish
    lock_release
    # Never a silent partial: if part of a range stayed behind, say which and
    # why, or the tab bar just looks like the gesture misfired. ONE message —
    # see the note on `note` above.
    if [ "$busy" -gt 0 ] || [ "$failed" -gt 0 ] || [ -n "$note" ]; then
        local report="hid ${#parked[@]}"
        [ "$busy" -gt 0 ]   && report="$report — left $busy still working"
        [ "$failed" -gt 0 ] && report="$report — could not park $failed"
        [ -n "$note" ]      && report="$report — $note"
        msg "$report"
    fi

    # After the moves, so the tabs disappear immediately and the (slower)
    # graceful shutdowns happen out of sight. Serial on purpose: each suspend
    # mirrors the sidecar, and concurrent writers would race a write-then-rename
    # — the loser's session id simply would not be on disk.
    for w in "${parked[@]}"; do suspend_agent "$w"; done

    # AGAIN, and this one is not redundant: the publish above ran before the
    # agents were suspended, so the sidecar it wrote has an empty @stash_session.
    # Leaving it at that meant a tmux restart came back with a suspended window
    # and no pointer to its conversation — the single worst outcome this whole
    # mechanism exists to prevent. Re-mirror once the suspends have had their say.
    save_state
}

# The single-window entry point. Resolves its target through sel_win for the
# reason spelled out there — a bare `display-message -p` answers by
# most-recently-active rules, so `stash.sh stash` typed at a shell (where no
# window id is passed) could park a window in a different session than the one
# you are looking at, or no-op with a misleading "already parked".
#
# It also clears any range selection first. tmux hands the prefix key back to
# the prefix table WITHOUT consulting the `stash` table's bindings, so pressing
# prefix mid-selection is the one exit that cannot run sel-cancel — and the
# muscle-memory follow-up is prefix+H. Clearing here means that sequence parks
# the current window and tidies the tint, instead of parking one window that
# then travels into the holding session still flagged and comes back mauve.
do_stash() {
    do_sel_cancel
    do_stash_many "$(sel_win "${1:-}")"
}

# --- selecting a range of tabs ------------------------------------------------
#
# prefix+S-Left / prefix+S-Right start a selection at the current tab and extend
# it one tab; the client is then left in the `stash` key table where bare
# S-Left/S-Right keep extending and H parks the lot.
#
# Modelled the way every list widget models shift-arrow: an ANCHOR that stays
# put and a CURSOR that moves, with everything between them selected. That is
# what makes shrinking fall out for free — walking the cursor back toward the
# anchor and out the other side reverses the direction with no special case.
# The range is contiguous because a contiguous range is the only kind the tab
# bar can show unambiguously.
#
# Anchor and cursor are window IDs, never indexes: parking renumbers the session
# (see renumber()), so an index captured beforehand names a different window
# afterwards.
#
# The bindings that move the cursor are FOREGROUND run-shell. Backgrounded, two
# quick taps both read the same cursor and both wrote cursor+1, so the selection
# stopped growing while the keys kept registering. tmux runs foreground items
# through the client's command queue in order, which serialises them for free —
# and the freeze that makes a foreground run-shell dangerous elsewhere needs a
# job that BLOCKS (the 90s resume poll); these are a handful of tmux calls.

# The window the key was pressed in, and the session holding it.
#
# A bare `tmux display-message -p '#{session_name}'` does NOT mean "the session
# the client is looking at". With no -t, tmux resolves the target by its own
# most-recently-active rules, and the holding session is the newest thing on the
# server the moment anything is parked — so with a client sitting in `main` and
# three tabs parked, it answered `stash`, every selection landed on the HOLD
# guard, and the keys silently did nothing (measured in the lab).
#
# So the bindings pass '#{window_id}', which tmux expands against the client's
# current window, exactly as the prefix+H binding already did. TMUX_PANE (set by
# run-shell) is the fallback; a bare display-message is the last resort and is
# only ever right when there is a single session.
sel_win() {
    local w="${1:-}"
    [ -n "$w" ] && { printf '%s' "$w"; return 0; }
    if [ -n "${TMUX_PANE:-}" ]; then
        tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null
    else
        tmux display-message -p '#{window_id}' 2>/dev/null
    fi
}
sel_sess_of() { [ -n "${1:-}" ] && tmux display-message -p -t "$1" '#{session_name}' 2>/dev/null; }

# Clear the flag wherever it is, not merely where we believe it is. A selection
# that leaked would tint tabs with no way to reach the mode that clears them.
sel_clear() {
    local w
    for w in $(tmux list-windows -a -F '#{?#{@stash_sel},#{window_id},}' 2>/dev/null); do
        tmux set-option -uw -t "$w" @stash_sel 2>/dev/null
    done
}

# The ids the tab bar is currently showing as selected, in tab order.
sel_ids() {
    tmux list-windows -t "=$1" -F '#{?#{@stash_sel},#{window_id},}' 2>/dev/null | grep -v '^$'
}

# The window one step left/right of $2 in session $1 — or $2 itself at either
# end, so holding the key down parks the selection against the edge instead of
# silently wrapping around to the far side of the tab bar.
sel_neighbour() {
    tmux list-windows -t "=$1" -F '#{window_id}' 2>/dev/null |
        awk -v w="$2" -v d="$3" '
            { id[NR] = $0; if ($0 == w) i = NR }
            END {
                if (!i) { print w; exit }
                j = (d == "left" ? i - 1 : i + 1)
                if (j < 1 || j > NR) j = i
                print id[j]
            }'
}

# Every window between anchor and cursor inclusive, in tab order, whichever way
# round the two are. Empty (and nonzero) if either has since gone.
sel_range() {
    tmux list-windows -t "=$1" -F '#{window_id}' 2>/dev/null |
        awk -v a="$2" -v c="$3" '
            { id[NR] = $0; if ($0 == a) ai = NR; if ($0 == c) ci = NR }
            END {
                if (!ai || !ci) exit 1
                lo = (ai < ci ? ai : ci); hi = (ai < ci ? ci : ai)
                for (k = lo; k <= hi; k++) print id[k]
            }'
}

# Flag exactly $2.. and clear the flag everywhere else in session $1. Only
# windows whose flag actually changes are touched, so holding an arrow down does
# not fork a set-option per tab per keypress.
sel_apply() {
    local sess="$1"; shift
    local want=" $* " wid flag
    while IFS="$SEP" read -r wid flag; do
        [ -n "$wid" ] || continue
        case "$want" in
            # Space-delimited on BOTH sides. A bare substring test matches @1
            # inside @12 and would drag an unselected tab into the range — the
            # same trap that made every window id ending in 1 a false positive
            # in pending_windows().
            *" $wid "*) [ -n "$flag" ] || tmux set-option -w -t "$wid" @stash_sel 1 2>/dev/null ;;
            *)          [ -z "$flag" ] || tmux set-option -uw -t "$wid" @stash_sel 2>/dev/null ;;
        esac
    done < <(tmux list-windows -t "=$sess" -F "#{window_id}${SEP}#{@stash_sel}" 2>/dev/null)
    # status-interval is 5s, so without this the tab bar keeps showing the
    # previous selection until the next tick and the arrow key feels dead.
    tmux refresh-client -S 2>/dev/null
}

do_sel_start() {
    local dir="${1:-right}" cur sess nxt
    cur=$(sel_win "${2:-}"); [ -n "$cur" ] || return 0
    sess=$(sel_sess_of "$cur"); [ -n "$sess" ] || return 0
    # Selecting inside the holding session would offer to park what is already
    # parked, and the tab bar it tints is not on screen to begin with.
    case "$sess" in "$HOLD") return 0 ;; esac
    sel_clear
    # `here` selects only the current tab — vim's `v` — and h/l grow it from
    # there. left/right start already extended by one (the shift-arrow shape).
    if [ "$dir" = "here" ]; then nxt="$cur"; else nxt=$(sel_neighbour "$sess" "$cur" "$dir"); fi
    # Global, not session-scoped: set-option's -t is a PANE target, so naming a
    # session with it ("=main") fails to resolve outright. A stale anchor left by
    # another session is harmless — sel_range looks the anchor up among THIS
    # session's windows, does not find it, and the selection simply restarts.
    tmux set-option -g @stash_anchor "$cur" 2>/dev/null
    tmux set-option -g @stash_cursor "$nxt" 2>/dev/null
    sel_apply "$sess" $(sel_range "$sess" "$cur" "$nxt")
}

do_sel_move() {
    local dir="${1:-right}" cur sess anchor cursor nxt
    cur=$(sel_win "${2:-}"); [ -n "$cur" ] || return 0
    sess=$(sel_sess_of "$cur"); [ -n "$sess" ] || return 0
    case "$sess" in "$HOLD") return 0 ;; esac
    anchor=$(tmux show -gqv @stash_anchor 2>/dev/null)
    cursor=$(tmux show -gqv @stash_cursor 2>/dev/null)
    # No live selection, or one whose windows have since gone: start a fresh one
    # rather than doing nothing, so a key in the table is never a dead end.
    if [ -z "$anchor" ] || [ -z "$cursor" ] || [ -z "$(sel_range "$sess" "$anchor" "$cursor")" ]; then
        do_sel_start "$dir" "$cur"
        return
    fi
    nxt=$(sel_neighbour "$sess" "$cursor" "$dir")
    tmux set-option -g @stash_cursor "$nxt" 2>/dev/null
    sel_apply "$sess" $(sel_range "$sess" "$anchor" "$nxt")
}

do_sel_cancel() {
    sel_clear
    tmux set-option -gu @stash_anchor 2>/dev/null
    tmux set-option -gu @stash_cursor 2>/dev/null
    tmux refresh-client -S 2>/dev/null
}

do_sel_commit() {
    local cur sess ids
    cur=$(sel_win "${1:-}"); [ -n "$cur" ] || return 0
    sess=$(sel_sess_of "$cur"); [ -n "$sess" ] || return 0
    case "$sess" in "$HOLD") return 0 ;; esac
    # Read the selection before clearing it, and clear it before parking: the
    # flag is a window option, so it rides along into the holding session and
    # would come back tinted on the next unstash.
    ids=$(sel_ids "$sess")
    do_sel_cancel
    [ -n "$ids" ] || return 0
    do_stash_many $ids
}

# Windows that are NOT parked but still carry a suspended session — a resume
# that was declined because the pane was busy. Before this existed the advice
# "prefix+h again once it's at a prompt" was impossible to follow: do_unstash
# only ever looked inside the holding session, and the window had already gone
# home, so the agent was dead with no key that could reach it.
#
# Fields are $SEP-delimited. They were concatenated with no separator at first,
# and "the last character is the flag" is wrong the moment a window id ends in
# 1: `agents@71` with NO suspended session parsed as flag=1 and yielded the
# truncated id `@7`. Every window whose id ended in 1 was a false positive.
pending_windows() {
    local sess wid flag
    while IFS="$SEP" read -r sess wid flag; do
        [ "$flag" = "1" ] || continue
        [ "$sess" = "$HOLD" ] && continue
        [ -n "$wid" ] && printf '%s\n' "$wid"
    done < <(tmux list-windows -a -F "#{session_name}${SEP}#{window_id}${SEP}#{?#{@stash_session},1,}" 2>/dev/null)
}

do_unstash() {
    local win="${1:-}"
    if ! hold_exists; then
        # Nothing parked, but a pending resume may still be waiting.
        local p; p=$(pending_windows | head -1)
        if [ -n "$p" ]; then
            # Backgrounded: see the note on the other hand-off below.
            tmux run-shell -b "'$SELF' resume '$p'"
            return 0
        fi
        msg "nothing is parked"
        return 0
    fi

    if [ -z "$win" ]; then
        if [ "$(count)" -gt 1 ]; then
            # fzf needs a terminal, so the choosing happens inside a popup that
            # re-enters this script as `pick`. Deciding here rather than in an
            # if-shell in tmux.conf keeps the branch in one place and avoids a
            # second layer of shell quoting inside a tmux command string.
            # Deliberately outside the lock: the popup waits on a human.
            tmux display-popup -E -w 60% -h 60% "'$SELF' pick"
            return 0
        fi
    fi

    do_unstash_many "$win"
}

# Bring one or more parked windows back, in a single transaction for the same
# reasons do_stash_many is one.
do_unstash_many() {
    local w win origin origins=() ordered=() wanted=" $* "

    hold_exists || { msg "nothing is parked"; return 0; }

    lock_acquire || { msg "busy — try again"; return 0; }   # 0: see the note on the refusal below

    # Re-resolve under the lock. Picking "the only parked window" before taking
    # it meant two unstashes could select the same window, and the second
    # move-window then acted on one that had already gone home.
    #
    # Walking the holding session rather than the argument list does three jobs
    # at once: it drops ids that are no longer parked, de-dupes, and puts the
    # group back in the order it sits in — so tabs parked together come home in
    # the same relative order rather than the order fzf happened to report them.
    while read -r w; do
        [ -n "$w" ] || continue
        case "$wanted" in
            "  ") ordered+=("$w"); break ;;      # no ids given: the first parked one
            *" $w "*) ordered+=("$w") ;;
        esac
    done < <(tmux list-windows -t "=$HOLD" -F '#{window_id}' 2>/dev/null)

    if [ "${#ordered[@]}" -eq 0 ]; then
        lock_release
        msg "nothing is parked"
        return 0
    fi

    local restored=() failed=0
    for win in "${ordered[@]}"; do
        # Home if it still exists, otherwise wherever we are now — a parked
        # window must never become unreachable because its origin session was
        # closed. Resolved per window: a batch can span origins.
        origin=$(tmux show -wqv -t "$win" @stash_origin 2>/dev/null)
        if [ -z "$origin" ] || ! tmux has-session -t "=$origin" 2>/dev/null; then
            origin=$(tmux display-message -p '#{session_name}' 2>/dev/null)
        fi
        # ...but that fallback resolves by tmux's most-recently-active rules,
        # not "the session the client is looking at", and the holding session is
        # the newest thing on the server whenever anything is parked — so it can
        # answer `stash`, and moving a parked window to `stash` succeeds while
        # leaving it exactly where it was: parked, with its origin now cleared,
        # and no way left to tell it had ever been anywhere else.
        #
        # Prefer a session someone is actually ATTACHED to. `list-sessions` is
        # sorted by name, so taking its head is "alphabetically first", which on
        # this machine is `agents` — the window would land somewhere the user is
        # not looking, and the select-window below would then quietly change
        # THAT session's current window instead. -F to match literally: a
        # session name is user-chosen and may contain regex metacharacters.
        case "${origin:-}" in
            "$HOLD"|"")
                origin=$(tmux list-sessions -F '#{?session_attached,#{session_name},}' 2>/dev/null |
                         grep -vxF "$HOLD" | grep -v '^$' | head -1)
                [ -n "$origin" ] || origin=$(tmux list-sessions -F '#{session_name}' 2>/dev/null |
                                             grep -vxF "$HOLD" | head -1)
                ;;
        esac
        if [ -z "$origin" ]; then
            failed=$((failed + 1))
            log "no session left to bring $win back to"
            continue
        fi
        if ! tmux move-window -s "$win" -t "$origin": 2>/dev/null; then
            failed=$((failed + 1))
            continue
        fi
        tmux set-option -uw -t "$win" @stash_origin 2>/dev/null
        tmux set-option -uw -t "$win" @stash_label 2>/dev/null
        # An ARRAY, not a space-joined string. Session names are user-chosen and
        # may contain spaces (or glob metacharacters), and the string form both
        # word-split `my project` into two bogus targets — silently skipping the
        # renumber, so the origin kept its index hole forever — and exposed the
        # name to pathname expansion.
        local seen=0 o
        for o in ${origins[@]+"${origins[@]}"}; do
            [ "$o" = "$origin" ] && { seen=1; break; }
        done
        [ "$seen" = "1" ] || origins+=("$origin")
        restored+=("$win")
    done

    if [ "${#restored[@]}" -eq 0 ]; then
        lock_release; msg "could not bring it back"; return 0
    fi
    # Land on the first of the group, so a multi-tab restore leaves you at the
    # left end of what just came back rather than on whichever one moved last.
    tmux select-window -t "${restored[0]}" 2>/dev/null
    renumber "$HOLD" ${origins[@]+"${origins[@]}"}
    publish
    lock_release
    [ "$failed" -gt 0 ] && msg "brought back ${#restored[@]}, could not bring back $failed"

    # Handed to a BACKGROUNDED run-shell, never called inline. prefix+h is a
    # foreground run-shell (it has to be — the picker needs a client to raise a
    # popup on), and tmux dispatches key events through the same client command
    # queue that a blocking run-shell item occupies. So polling inline froze the
    # client's keyboard for the whole resume: measured 96.9s on a session that
    # never registered, with everything dead — typing, prefix chords, even
    # prefix+d — and keys typed during a 90s block discarded outright rather
    # than replayed.
    #
    # One per window, and deliberately concurrent: each polls for up to 90s for
    # its OWN agent to register, so running them in series would make the last
    # tab of a group wait out every tab before it. They touch different windows
    # and the sidecar write they each trigger is a rename, so the worst case is
    # a redundant mirror, not a lost id.
    for win in "${restored[@]}"; do
        tmux run-shell -b "'$SELF' resume '$win'"
    done
}

# Runs inside the popup, where there is a real terminal for fzf.
#
# --multi so a group parked together can come back together. Shift-Up/Shift-Down
# are bound alongside fzf's own Tab/Shift-Tab because shift+arrow is the gesture
# this pairs with on the tab-bar side, and having the two halves of the feature
# answer to the same key is most of what makes it memorable.
do_pick() {
    local wins
    wins=$(tmux list-windows -t "=$HOLD" \
            -F '#{window_id}	#{?#{@stash_label},#{@stash_label},#{?#{@agent_summary},#{@agent_summary},#{window_name}}}	#{pane_current_path}' \
          | fzf --with-nth=2.. --delimiter='\t' --reverse --prompt='bring back > ' \
                --multi \
                --bind 'shift-down:toggle+down,shift-up:toggle+up,ctrl-a:select-all,ctrl-d:deselect-all' \
                --header '⇧↑/⇧↓ or Tab to pick several · ⌃a all · ⏎ bring back' \
          | cut -f1 | tr '\n' ' ')
    # Hand off rather than doing the work here. the resume polls for up to
    # RESUME_WAIT, and display-popup -E keeps the popup on screen — holding the
    # keyboard and covering the windows it just restored — until its command
    # exits. Backgrounding lets the popup close the moment you pick.
    #
    # Unquoted on purpose: this is a list of ids for the command line to split.
    # They are tmux window ids (@ plus digits), so there is nothing in them for
    # a shell to interpret.
    [ -n "${wins// /}" ] && tmux run-shell -b "'$SELF' unstash-many $wins"
}

do_list() {
    if hold_exists; then
        tmux list-windows -t "=$HOLD" \
            -F '  #{window_id}  from=#{?#{@stash_origin},#{@stash_origin},?}  #{?#{@stash_session},[suspended] ,}#{?#{@stash_label},#{@stash_label},#{?#{@agent_summary},#{@agent_summary},#{window_name}}}'
    else
        echo "  nothing parked"
    fi

    # Windows that came home but whose agent has not been resumed yet — the
    # "pane was busy" case. prefix+h reaches these, but they are invisible
    # otherwise, so say so.
    local p sid lbl
    for p in $(pending_windows); do
        sid=$(tmux show -wqv -t "$p" @stash_session 2>/dev/null)
        lbl=$(tmux show -wqv -t "$p" @stash_label 2>/dev/null)
        printf '  %s  [resume pending] %s  (prefix+h, or: claude --resume %s)\n' \
            "$p" "${lbl:-$p}" "$sid"
    done

    # Suspended sessions whose window could not be identified after a restart.
    # These are the ones with no tmux state left at all, so print the command
    # that gets them back — this listing is the only place the id still exists.
    local of; of=$(orphan_file)
    if [ -s "$of" ]; then
        echo
        echo "  Suspended sessions that lost their window (resume by hand):"
        while IFS="$SEP" read -r sess idx name pidx origin label sid cwd; do
            [ -n "$sid" ] || continue
            printf '    %-28s cd %s && claude --resume %s\n' "${label:-$name}" "${cwd:-?}" "$sid"
        done < "$of"
        echo "  (delete $of once you have dealt with them)"
    fi
}

case "${1:-}" in
    stash)   shift; do_stash "${1:-}" ;;
    unstash) shift; do_unstash "${1:-}" ;;
    stash-many)   shift; do_stash_many "$@" ;;
    unstash-many) shift; do_unstash_many "$@" ;;
    sel-start)  shift; do_sel_start "${1:-right}" "${2:-}" ;;
    sel-move)   shift; do_sel_move "${1:-right}" "${2:-}" ;;
    sel-cancel) do_sel_cancel ;;
    sel-commit) shift; do_sel_commit "${1:-}" ;;
    count)   count ;;
    publish) publish ;;
    pick)    do_pick ;;
    resume)  shift; resume_agent "${1:-}" ;;
    restore-state) do_restore_state ;;
    list)    do_list ;;
    *)       sed -n '/^#   stash.sh/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d' ;;
esac
