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
#   stash.sh restore-state        re-apply parked state after a resurrect restore
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

lock_acquire() {
    local i=0 owner age
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        # Break a lock whose owner died, or one that outlived any sane critical
        # section — otherwise a killed park wedges the feature until reboot.
        owner=$(cat "$LOCKDIR/pid" 2>/dev/null)
        age=$(( $(date +%s) - $(stat -f %m "$LOCKDIR" 2>/dev/null || date +%s) ))
        if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || [ "$age" -ge "$LOCK_STALE" ]; then
            log "breaking stale lock (owner ${owner:-?}, age ${age}s)"
            rm -rf "$LOCKDIR" 2>/dev/null
            continue
        fi
        i=$((i + 1)); [ "$i" -gt 100 ] && { log "could not take the lock"; return 1; }
        sleep 0.1
    done
    printf '%s' "$$" > "$LOCKDIR/pid" 2>/dev/null
    return 0
}
lock_release() { rm -rf "$LOCKDIR" 2>/dev/null; }

hold_exists() { tmux has-session -t "=$HOLD" 2>/dev/null; }
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

save_state() {
    local sf tmp rows
    sf=$(state_file)

    # Every window that matters, not just the parked ones. A window can leave
    # the holding session still carrying @stash_session — resume_agent declines
    # when the pane is busy and tells you to try again — and the old version
    # only mirrored windows inside HOLD, so that row was dropped at exactly the
    # moment the window option became the sole surviving pointer.
    rows=$(tmux list-windows -a -F \
        "#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{@stash_pane_idx}${SEP}#{@stash_origin}${SEP}#{@stash_label}${SEP}#{@stash_session}${SEP}#{@stash_cwd}" \
        2>/dev/null) || return 0    # tmux unreachable: keep whatever is on disk
    rows=$(printf '%s\n' "$rows" | awk -F"$SEP" -v hold="$HOLD" '$1==hold || $7!=""')

    if [ -z "$rows" ]; then
        rm -f "$sf" 2>/dev/null
        return 0
    fi
    mkdir -p "$(dirname "$sf")" 2>/dev/null
    # Write-then-rename. `> "$sf"` truncates before the command runs, so a
    # single failed list-windows used to leave an EMPTY sidecar and silently
    # drop every suspended conversation's off-server copy at once.
    tmp="${sf}.$$"
    printf '%s\n' "$rows" > "$tmp" 2>/dev/null && mv -f "$tmp" "$sf" 2>/dev/null
    rm -f "$tmp" 2>/dev/null
}

# Re-attach the options to the windows resurrect just rebuilt.
#
# Keyed on session + index + NAME, all three. Index alone was not enough and
# the name was captured but never compared: nothing rewrites the sidecar when a
# parked window merely closes, `renumber-windows on` reindexes the survivors,
# and the next restore then stamped the dead window's sessionId and cwd onto
# its neighbour — unparking it resumed the WRONG conversation in the wrong
# directory, and the neighbour's own id was gone. Reproduced during review.
# A mismatch now skips the row: applying nothing is always recoverable.
do_restore_state() {
    local sf; sf=$(state_file)
    [ -f "$sf" ] || return 0
    local sess idx name pidx origin label sid cwd win got
    while IFS="$SEP" read -r sess idx name pidx origin label sid cwd; do
        [ -n "$sess" ] && [ -n "$idx" ] || continue
        tmux has-session -t "=$sess" 2>/dev/null || continue
        win=$(tmux list-windows -t "=$sess" -F '#{window_index} #{window_id}' 2>/dev/null \
              | awk -v i="$idx" '$1==i{print $2}')
        [ -n "$win" ] || continue
        got=$(tmux display-message -p -t "$win" '#{window_name}' 2>/dev/null)
        if [ "$got" != "$name" ]; then
            log "skipped $sess:$idx — expected window \"$name\", found \"$got\" (layout moved)"
            continue
        fi
        [ -n "$origin" ] && tmux set-option -w -t "$win" @stash_origin   "$origin" 2>/dev/null
        [ -n "$label" ]  && tmux set-option -w -t "$win" @stash_label    "$label"  2>/dev/null
        [ -n "$sid" ]    && tmux set-option -w -t "$win" @stash_session  "$sid"    2>/dev/null
        [ -n "$cwd" ]    && tmux set-option -w -t "$win" @stash_cwd      "$cwd"    2>/dev/null
        [ -n "$pidx" ]   && tmux set-option -w -t "$win" @stash_pane_idx "$pidx"   2>/dev/null
        log "restored $sess:$idx ($name)${sid:+ — suspended session ${sid%%-*}}"
    done < "$sf"
    tmux set-option -g @stash_count "$(count)" 2>/dev/null
}

# --- agent suspend / resume ---------------------------------------------------

# Live claude sessions, one per line, $SEP-delimited:
#   pid · sessionId · status · window · pane · cwd
# The session file's own "tmux" field is "session:@win.%pane", so the window id
# is authoritative — and it does not change when a window moves between
# sessions, which is exactly what parking does.
live_sessions() {
    python3 - "$SESS_DIR" <<'PY' 2>/dev/null
import json, os, sys, glob
# The whole record build sits inside the try. Previously only json.load did, so
# a malformed "tmux" field or a non-numeric statusUpdatedAt raised, killed the
# interpreter, and silently dropped every file glob had not reached yet —
# indistinguishable from "no agents are running", which makes suspend a no-op.
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        s = json.load(open(f))
        t = s.get("tmux") or ""
        win = pane = ""
        if ":" in t and "." in t:
            win, pane = t.split(":", 1)[1].split(".", 1)
        print(chr(31).join(str(x) for x in (
            s.get("pid", ""), s.get("sessionId", ""), s.get("status", ""),
            win, pane, s.get("cwd", ""))))
    except Exception:
        continue
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
    local status="$1" sid="$2" pid="$3" mt
    [ "$status" = "busy" ] && return 0
    # claude holds a `caffeinate -i -t 300` child while it works. Its 300s timer
    # means it lingers ~5min past a turn, which made it a bad signal for an
    # idle-timer — but here it is exactly right: parking is explicit, and the
    # only cost of a stale caffeinate is leaving an agent running, the safe
    # direction. It is also the ONLY guard that catches a long silent tool call
    # (a build, a test suite, a subagent), which writes no transcript for
    # minutes and has no `status` field on a session that never reported one.
    if [ -n "$pid" ] && ps -eo ppid=,command= 2>/dev/null \
         | awk -v r="$pid" '$1==r && /caffeinate/{f=1} END{exit !f}'; then
        return 0
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
has_live_workflow() {
    local sid="$1" cwd="$2" proj base d wfid mt now
    [ -n "$sid" ] && [ -n "$cwd" ] || return 1
    proj="${cwd//\//-}"; proj="${proj//./-}"      # claude munges / and . to -
    base="$HOME/.claude/projects/$proj/$sid"
    [ -d "$base/subagents/workflows" ] || return 1
    now=$(date +%s)
    for d in "$base"/subagents/workflows/wf_*/; do
        [ -d "$d" ] || continue
        wfid="${d%/}"; wfid="${wfid##*/}"
        [ -f "$base/workflows/$wfid.json" ] && continue    # completed
        mt=$(stat -f %m "$d"/agent-*.jsonl "$d/journal.jsonl" 2>/dev/null | sort -rn | head -1)
        [ -n "$mt" ] && [ $((now - mt)) -lt 3600 ] && return 0
    done
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
    python3 - "$CUA_ACTIVITY" "$pid" "$CUA_LIVE" <<'PY' 2>/dev/null
import json, sys, time
try:
    sessions = json.load(open(sys.argv[1])).get("sessions", {}) or {}
except Exception:
    raise SystemExit(1)
pid, live, now = int(sys.argv[2]), float(sys.argv[3]), time.time()
for d in sessions.values():
    if (isinstance(d, dict) and d.get("agent_pid")
            and int(d["agent_pid"]) == pid
            and now - float(d.get("ts") or 0) < live):
        raise SystemExit(0)
raise SystemExit(1)
PY
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
    case "$(ps -p "$a_pid" -o comm= 2>/dev/null)" in
        *claude*|*node*) : ;;
        *) log "pid $a_pid is not claude (pid reuse?) — left alone"; return 0 ;;
    esac

    # Never overwrite a sessionId already recorded here: that value can be the
    # only pointer to a DIFFERENT conversation (a resume that was refused
    # leaves one behind), and replacing it loses that one silently.
    local existing; existing=$(tmux show -wqv -t "$win" @stash_session 2>/dev/null)
    if [ -n "$existing" ] && [ "$existing" != "$a_sid" ]; then
        log "window already holds session ${existing%%-*} — not suspending over it"; return 0
    fi

    is_working "$a_status" "$a_sid" "$a_pid" && { log "agent is mid-turn — left running"; return 0; }
    has_unsent_input "$a_pane"      && { log "unsent input in the composer — left running"; return 0; }
    # A backgrounded workflow outlives its turn and computer-use spans turns;
    # both would die with the process. Checked TWO ways each — the watcher's
    # flag, which is instant but goes stale if the daemon dies, and the
    # underlying files, which are authoritative but cost a little more. Either
    # saying "busy" is enough to leave the agent alone.
    if [ -n "$(tmux show -wqv -t "$win" @agent_workflow 2>/dev/null)" ] || has_live_workflow "$a_sid" "$a_cwd"; then
        log "background workflow still in flight — left running"; return 0
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
    local win="$1" sid cwd pane pane_pid
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
    local cmd
    printf -v cmd 'cd %q && claude --resume %q' "$cwd" "$sid"
    tmux send-keys -t "$pane" C-u
    tmux send-keys -t "$pane" "$cmd" Enter

    # Only drop the record once the session is actually back: it is the sole
    # remaining pointer to that conversation, and a resume can take a while on a
    # large transcript.
    local waited=0
    while [ "$waited" -lt "$RESUME_WAIT" ]; do
        sleep 2; waited=$((waited + 2))
        # Process substitution, not a pipe: `grep -q` exits at the first match,
        # and with pipefail a SIGPIPE'd python makes the pipeline nonzero even
        # though the session WAS found — reporting failure for a live resume.
        if grep -q "${SEP}${sid}${SEP}" < <(live_sessions); then
            tmux set-option -uw -t "$win" @stash_session 2>/dev/null
            tmux set-option -uw -t "$win" @stash_cwd 2>/dev/null
            tmux set-option -uw -t "$win" @stash_pane_idx 2>/dev/null
            save_state
            return 0
        fi
    done
    msg "agent did not come back after ${RESUME_WAIT}s — its session id is still on the tab"
    return 1
}

do_stash() {
    local win="${1:-$(tmux display-message -p '#{window_id}')}"
    local sess; sess=$(tmux display-message -p -t "$win" '#{session_name}')

    # Everything from here to the move reads tmux state and then acts on it, so
    # it runs under the lock. Released before the suspend, which is slow and
    # touches only this one window.
    lock_acquire || { msg "busy — try again"; return 1; }

    # Never strand a client: taking a session's last window destroys it, and
    # detach-on-destroy is on here, so that would drop the attached client to
    # the shell. Counted INSIDE the lock — two concurrent parks both saw "2
    # windows" and both moved, and the second one emptied the session.
    if [ "$(tmux list-windows -t "=$sess" -F '#{window_id}' 2>/dev/null | wc -l | tr -d ' ')" -le 1 ]; then
        lock_release
        msg "that's the only tab in this session — not parking it"
        return 1
    fi
    case "$sess" in "$HOLD") lock_release; msg "already parked"; return 0 ;; esac

    # Origin travels with the window (see header). The label is captured too:
    # @agent_summary is maintained by the tab watcher and gets cleared once the
    # agent it describes is gone, so without this the picker would list a
    # suspended session as plain "zsh".
    tmux set-option -w -t "$win" @stash_origin "$sess"
    local label; label=$(tmux show -wqv -t "$win" @agent_summary 2>/dev/null)
    [ -n "$label" ] && tmux set-option -w -t "$win" @stash_label "$label"

    # A session cannot be created empty, so it is born with a placeholder that
    # is killed once the real window is inside; the session then dies by itself
    # when the last window leaves, so nothing idles in the background.
    #
    # `-P -F` is load-bearing: it reports the id of the window this call
    # actually created. Taking "the first window in the stash session" instead
    # meant that if new-session FAILED because the session already existed —
    # which two concurrent `prefix+H` presses reliably produce, since the bind
    # is run-shell -b and both see hold_exists as false — `boot` resolved to
    # somebody else's ALREADY-PARKED window, and the kill below destroyed it,
    # panes, scrollback, suspended agent and all. Reproduced during review.
    local boot=""
    if ! hold_exists; then
        boot=$(tmux new-session -d -s "$HOLD" -n _bootstrap -P -F '#{window_id}' 2>/dev/null) || boot=""
    fi

    if ! tmux move-window -s "$win" -t "$HOLD": 2>/dev/null; then
        # If this call created the holding session and then failed to put
        # anything in it, take the placeholder back out rather than leaving a
        # session whose only window is a stray shell that `count` reports as
        # parked and the next prefix+h would hand you.
        [ -n "$boot" ] && tmux kill-window -t "$boot" 2>/dev/null
        lock_release
        msg "could not park it"
        return 1
    fi
    # Only ever kill a window this invocation created, and never the one just parked.
    [ -n "$boot" ] && [ "$boot" != "$win" ] && tmux kill-window -t "$boot" 2>/dev/null
    publish
    lock_release

    # After the move, so the tab disappears immediately and the (slower)
    # graceful shutdown happens out of sight.
    suspend_agent "$win"

    # AGAIN, and this one is not redundant: the publish above ran before the
    # agent was suspended, so the sidecar it wrote has an empty @stash_session.
    # Leaving it at that meant a tmux restart came back with a suspended window
    # and no pointer to its conversation — the single worst outcome this whole
    # mechanism exists to prevent. Re-mirror once the suspend has had its say.
    save_state
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
            # Deliberately outside the lock: the popup waits on a human.
            tmux display-popup -E -w 60% -h 60% "$SELF pick"
            return 0
        fi
    fi

    lock_acquire || { msg "busy — try again"; return 1; }
    # Re-resolve under the lock. Picking "the only parked window" before taking
    # it meant two unstashes could select the same window, and the second
    # move-window then acted on one that had already gone home.
    if [ -z "$win" ]; then
        win=$(tmux list-windows -t "=$HOLD" -F '#{window_id}' 2>/dev/null | head -1)
    fi
    if [ -z "$win" ] || ! tmux list-windows -t "=$HOLD" -F '#{window_id}' 2>/dev/null | grep -qx "$win"; then
        lock_release
        msg "nothing is parked"
        return 0
    fi

    # Home if it still exists, otherwise wherever we are now — a parked window
    # must never become unreachable because its origin session was closed.
    local origin; origin=$(tmux show -wqv -t "$win" @stash_origin 2>/dev/null)
    if [ -z "$origin" ] || ! tmux has-session -t "=$origin" 2>/dev/null; then
        origin=$(tmux display-message -p '#{session_name}')
    fi

    if ! tmux move-window -s "$win" -t "$origin": 2>/dev/null; then
        lock_release; msg "could not bring it back"; return 1
    fi
    tmux set-option -uw -t "$win" @stash_origin 2>/dev/null
    tmux set-option -uw -t "$win" @stash_label 2>/dev/null
    tmux select-window -t "$win" 2>/dev/null
    publish
    lock_release

    # Outside the lock: the resume polls for up to RESUME_WAIT and concerns
    # only this window.
    resume_agent "$win"
}

# Runs inside the popup, where there is a real terminal for fzf.
do_pick() {
    local win
    win=$(tmux list-windows -t "=$HOLD" \
            -F '#{window_id}	#{?#{@stash_label},#{@stash_label},#{?#{@agent_summary},#{@agent_summary},#{window_name}}}	#{pane_current_path}' \
          | fzf --with-nth=2.. --delimiter='\t' --reverse --prompt='bring back > ' \
          | cut -f1)
    # Hand off rather than doing the work here. do_unstash's resume polls for up
    # to RESUME_WAIT, and display-popup -E keeps the popup on screen — holding
    # the keyboard and covering the window it just restored — until its command
    # exits. Backgrounding lets the popup close the moment you pick.
    [ -n "$win" ] && tmux run-shell -b "'$SELF' unstash '$win'"
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
    restore-state) do_restore_state ;;
    list)    do_list ;;
    *)       sed -n '/^#   stash.sh/,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//;$d' ;;
esac
