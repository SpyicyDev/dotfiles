#!/usr/bin/env bash
# Agent tab watcher — presence daemon backing agent-tab-indicator.sh.
#
# Hooks give instant state transitions but can't cover two cases:
#   1. presence with no events yet (agent just launched, or hooks untrusted —
#      codex requires interactive trust approval for new hook entries), and
#   2. cleanup when the agent dies without firing SessionEnd (SIGKILL,
#      kill-pane SIGHUP, crash) — SessionEnd is best-effort for both agents
#      (codex additionally clamps its SessionEnd hook timeout to 3s).
#
# Every POLL_SECONDS this daemon matches agent processes to tmux windows by
# TTY and reconciles the per-window @agent_state option:
#   agent present + no state           → idle    (seed presence)
#   no agent     + any state OR summary → unset @agent_state/@agent_summary (GC)
# Hook-set states (running/needs-input/done) are never overridden while the
# agent lives.
#
# It also makes tabs aware of background Claude WORKFLOWS. A backgrounded
# Workflow keeps running after the main turn's Stop fires (so the tab would
# otherwise read done/idle). There's no hook for it, but the workflow runtime
# writes a live dir subagents/workflows/wf_<id>/ and only writes the terminal
# state file workflows/wf_<id>.json at completion — so a workflow is in-flight
# iff its runtime dir exists without that completion file. Per claude window we
# map pane→pid→session (~/.claude/sessions/<pid>.json) and set a per-window
# @agent_workflow flag the formats render as a distinct blinking gear.
# (Workflows are a Claude feature; a codex pid has no ~/.claude/sessions
# file, so codex windows fall through the lookup naturally.)
#
# It also flags COMPUTER USE. cua-mcp-shim stamps every driver tool call into
# ~/Library/Application Support/CuaNotch/activity.json with the owning agent's pid, which is
# the same pane→pid map the workflow lookup already builds — so a window whose
# agent has driven an app within CUA_LIVE seconds gets a per-window @agent_cua
# flag, rendered as a blue robot. This is the tab-bar twin of CuaNotch's blue
# glow segment: same source of truth, same meaning, same hue.
#
# It also drives the running-state animation: while ANY window is in state
# running OR has @agent_workflow / @agent_cua set, the global @agent_blink
# option toggles each tick and the window formats alternate the glyph between
# its color and a dimmed copy of THE SAME hue (a brightness pulse, matching
# CuaNotch's breathing glow — never a hue swap, which would make a state look
# like a different state). Nothing running → no toggling, no redraws.
#
# Process matching is by `ps -o comm` basename — NOT #{pane_current_command}:
# tmux reads the kernel p_comm, which for Claude Code is the version-named
# binary ("2.1.170"), while ps comm reflects argv[0] ("claude"). The bare
# version-string pattern is kept as a fallback in case a Claude build stops
# setting its process title. Codex's npm wrapper spawns the native binary
# vendor/<triple>/bin/codex → comm basename "codex" (plus a "node" parent we
# don't match).
#
# Singleton + lifecycle follow coffee-watcher.sh: PID-file guard, exits when
# the tmux server goes away, writes only on change then refresh-client -S.
# Spawned from tmux.conf via `run-shell -b`. set -u/-e relaxed: a daemon
# must survive transient tmux command failures mid-loop.

# 1s: doubles as the blink interval for the running-glyph animation.
POLL_SECONDS=1

command -v tmux >/dev/null 2>&1 || exit 0

# Singleton: every tmux.conf reload (`prefix r`) re-runs the spawn line, so a
# plain check-then-write leaks daemons (a transiently-exiting watcher with an
# unconditional trap can delete a live sibling's pidfile, then the next reload
# finds none and starts another). Reap any prior instance, then claim the
# pidfile, and only clean it up on exit if it's still ours.
PIDFILE="${TMPDIR:-/tmp}/agent-tab-watcher.${UID:-$(id -u)}.pid"
SELF="$HOME/.config/tmux/scripts/agent-tab-watcher.sh"

# A PID IS NOT AN IDENTITY. cleanup() only unlinks the pidfile on a normal
# EXIT, so a SIGKILLed watcher leaves a live-looking pid behind — and pid
# churn on this machine is ~1000/10s, so the space wraps in ~15 minutes. By
# the next `prefix r` that number is very likely some unrelated process, and
# `kill -0` says only "a process exists", not "it is mine". This used to
# SIGTERM whatever answered. Exactly the hazard the -fx sweep below documents
# ("killing a bystander is not [harmless]") — the pidfile path just had no
# equivalent guard. One ps, at startup only; the loop never forks for this.
is_watcher_pid() {
    local cmd
    cmd="$(ps -o command= -p "$1" 2>/dev/null)"
    [ "$cmd" = "bash $SELF" ] || [ "$cmd" = "/bin/bash $SELF" ] || [ "$cmd" = "$SELF" ]
}

prev=$(cat "$PIDFILE" 2>/dev/null || true)
if [ -n "$prev" ] && [ "$prev" != "$$" ] && kill -0 "$prev" 2>/dev/null \
   && is_watcher_pid "$prev"; then
    kill "$prev" 2>/dev/null || true
fi
# Belt to the pidfile's braces: also sweep for stragglers whose pidfile we
# can't see (a respawn under a different TMPDIR, a cleaned tmp dir). Two live
# daemons would both toggle @agent_blink each second and the glyph would sit
# on one color — the exact symptom this daemon exists to produce. One pgrep at
# startup only; the loop below never forks for this.
#
# -fx (whole command line must match EXACTLY) is load-bearing: a substring
# `pgrep -f agent-tab-watcher` also matches any shell, editor or grep whose
# argv merely mentions this path, and we kill what we match. Missing a stray
# spawned some other way is harmless (the pidfile still covers the normal
# case); killing a bystander is not. ($SELF is defined with is_watcher_pid
# above, which applies the same exactness to the pidfile path.)
if command -v pgrep >/dev/null 2>&1; then
    for stray in $(pgrep -fx "bash $SELF" 2>/dev/null; pgrep -fx "/bin/bash $SELF" 2>/dev/null; pgrep -fx "$SELF" 2>/dev/null); do
        if [ "$stray" != "$$" ] && [ "$stray" != "$PPID" ]; then
            kill "$stray" 2>/dev/null || true
        fi
    done
fi
echo $$ > "$PIDFILE"
# Remove the pidfile on exit only if it's still ours. The signal traps must
# EXIT (a bare cleanup trap on TERM/INT/HUP would run the handler and then
# RESUME the loop — the daemon would survive `kill`, which is exactly how the
# old version leaked); routing signals through `exit 0` fires the EXIT trap.
cleanup() { [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$PIDFILE"; }
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

is_agent_comm() {
    # ${1##*/}, not basename: this runs for every tty-owning process on every
    # 1s tick (~60 fork+exec per tick, ~5M/day) — measured 109ms/tick vs
    # 9.5ms for the builtin. ps `comm` is never "/" or a trailing-slash path,
    # so the expansion is exactly equivalent here (and it doesn't choke on
    # comm values like "-zsh", which basename parses as an option).
    local base="${1##*/}"
    case "$base" in
        claude|codex) return 0 ;;
    esac
    # Claude's binary is version-named (e.g. "2.1.170") in case its
    # process-title rename ever stops applying. Anchored regex, digits-only
    # segments — a case glob like [0-9]*.[0-9]*.[0-9]* would also match
    # IP-like or suffixed names ("10.0.0.1", "1.2.3-beta").
    [[ "$base" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Claude Code's own view of whether the session is mid-turn, echoed as
# "busy" | "idle" | "" (unknown/not a claude session).
#
# ~/.claude/sessions/<pid>.json carries a "status" field that Claude maintains
# itself, and it is the only GROUND TRUTH here — every other signal we have is
# an inference from hooks, and hooks only tell us about transitions they
# actually fire. Interrupting a turn with Esc fires NOTHING: no Stop, no
# StopFailure (there is no interrupt/abort event in the wired set at all), so
# @agent_state sat at `running` and the tab pulsed for a session doing nothing
# — reported from the field, reproduced with tab main:3 showing running while
# its session file read idle for 156s. Same stuck state arrives from a missed
# Stop, a hook that failed to run, or the deliberate SessionStart(compact)
# skip, so reconciling against status fixes the whole class rather than one
# cause. Builtin read, no fork; unknown values are left alone deliberately.
session_status() {
    local sf raw
    [ -n "$1" ] || return 0
    sf="$HOME/.claude/sessions/$1.json"
    [ -f "$sf" ] || return 0
    raw="$(<"$sf")"
    [[ $raw =~ \"status\":\"([^\"]+)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Codex's answer to the same question, from its rollout stream: "busy" | "idle"
# | "" (unknown). Codex has no ~/.claude/sessions equivalent and no pid→thread
# mapping we could follow, so agent-tab-indicator.sh stashes the thread's
# rollout_path in @agent_rollout (it already queries that row on every codex
# hook) and this reads the tail of it.
#
# The stream records turn boundaries explicitly: event_msg task_started opens a
# turn, task_complete closes it, and an INTERRUPT writes turn_aborted (verified
# against the on-disk corpus: 51 starts, 41 completes, 8 aborts). So the turn is
# live iff the most recent of the three is task_started — real state, not an
# inference from how recently the file was touched.
#
# Bounded tail, never the whole file: rollouts run to 27MB here (p90 791KB).
# If no marker falls in the tail the answer is "" and the caller does nothing,
# which is the same conservative failure as not looking at all.
#
# awk, NOT bash string ops. The obvious `${chunk##*"$marker"}` trick to find a
# last occurrence is O(n^2) on a 256KB string — it hung this function outright
# on the first large rollout it met. One linear pass instead; records are
# JSONL, one event per line, so the last line carrying any of the three
# markers decides. A truncated first line from the byte-oriented tail is
# harmless.
CODEX_TAIL_BYTES=262144
codex_status() {
    local rp="$1"
    [ -n "$rp" ] && [ -f "$rp" ] || return 0
    tail -c "$CODEX_TAIL_BYTES" "$rp" 2>/dev/null | awk '
        /"type":"task_started"/                        { last = "busy" }
        /"type":"task_complete"/ || /"type":"turn_aborted"/ { last = "idle" }
        END { printf "%s", last }
    '
}

# Resolve a claude PID to its session's runtime dirs. SESSION_PROJ is the
# project dir (~/.claude/projects/<proj>) and SESSION_BASES the session ids
# under it that belong to this process - PLURAL, because of compaction:
# after a compaction ~/.claude/sessions/<pid>.json can go on reporting the
# ORIGINAL id for a while, but the continued conversation gets a NEW id and
# its transcript, subagents/ and workflows/ all move under that one.
# Measured 2026-08-25: a process reporting 88d5cc09 had two running
# reviewers under 42a666ca/, this function looked in the empty dir, the gear
# never showed, and the tab read done with work in flight - which is how a
# park SIGTERMed that session mid-review. The lineage is discoverable: the
# continued transcript's compaction summary is a user record marked
# "isCompactSummary":true whose text names the old transcript's PATH, so a
# descendant is a transcript with both on ONE line (a bare mention of the
# id is not enough - other sessions quote ids in conversation all day).
# Walked transitively, and cached per pid+sid for a minute: the grep over
# every transcript in the project is the one thing here that is not free.
declare -A SB_CACHE SB_CACHE_AT
SESSION_PROJ=""
SESSION_BASES=()
resolve_session_bases() {
    local pid="$1" sf sid cwd proj raw now key dirs frontier found id f fid
    SESSION_PROJ=""
    SESSION_BASES=()
    [ -n "$pid" ] || return 1
    sf="$HOME/.claude/sessions/$pid.json"
    [ -f "$sf" ] || return 1
    # Bash builtins, not `grep -o | head -1 | cut`: this runs for EVERY claude
    # window on EVERY 1s tick, and it cannot be moved behind the cheap
    # [ -d ] gate below because that path is built from sid+cwd. The pipeline
    # form cost 8 processes and ~4.7ms per call (measured, 200 iterations)
    # against 0.045ms here — ~105x, and with 4 live windows it was ~2.8M
    # spawns/day for a function that returns "no workflow" almost always.
    # Same family as the basename fix below; bigger in absolute terms.
    raw="$(<"$sf")"
    [[ $raw =~ \"sessionId\":\"([^\"]+)\" ]] && sid="${BASH_REMATCH[1]}"
    [[ $raw =~ \"cwd\":\"([^\"]+)\" ]] && cwd="${BASH_REMATCH[1]}"
    { [ -n "$sid" ] && [ -n "$cwd" ]; } || return 1
    # Claude munges the project dir name from cwd: '/' and '.' both become '-'.
    proj="${cwd//\//-}"; proj="${proj//./-}"
    SESSION_PROJ="$HOME/.claude/projects/$proj"
    key="$pid:$sid"
    printf -v now '%(%s)T' -1
    if [ -n "${SB_CACHE[$key]:-}" ] && [ $((now - SB_CACHE_AT[$key])) -lt 60 ]; then
        read -ra SESSION_BASES <<<"${SB_CACHE[$key]}"
        return 0
    fi
    dirs="$sid"; frontier="$sid"
    while [ -n "$frontier" ]; do
        found=""
        for id in $frontier; do
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                fid="${f##*/}"; fid="${fid%.jsonl}"
                case " $dirs " in *" $fid "*) continue ;; esac
                # Both markers on one line, either order.
                grep -q -m1 -E "\"isCompactSummary\":true.*/$id\.jsonl|/$id\.jsonl.*\"isCompactSummary\":true" "$f" 2>/dev/null || continue
                dirs="$dirs $fid"; found="$found $fid"
            done <<EOF
$(grep -lF -- "/$id.jsonl" "$SESSION_PROJ"/*.jsonl 2>/dev/null)
EOF
        done
        frontier="$found"
    done
    SB_CACHE[$key]="$dirs"; SB_CACHE_AT[$key]=$now
    read -ra SESSION_BASES <<<"$dirs"
}

# WHEN IS A SUBAGENT FINISHED? Not by its own transcript's tail - two rules
# were tried there and a 101-transcript corpus refuted both (opus review of
# cua-notch v0.4.0, 2026-08-25): 2.1.245 writes stop_reason null on the
# final record, and "last record is an assistant text block" misfires on
# the text-then-tool_use gap, which scales with the tool call's payload
# (23% of measured gaps beat 5s, the worst 86s). The PARENT knows: when a
# background agent finishes, the harness appends a <task-notification>
# naming its <task-id> to the parent transcript, promptly, and that is the
# same witness agent-bg-pending uses for the session's state. So a subagent
# is finished when its parent was notified about it SINCE its transcript
# last moved (a resumed agent moves again and is running again), or when
# the user hit Esc on it (its last record is the interrupt marker - the
# parent is never notified for those), else it is running, for at most the
# one-hour age backstop a dead parent's agents are given. PINNED to
# CuaNotch's workflowInfo/tallyNotifications/subagentInterrupted - see
# check-invariants.
#
# The parent transcript is read INCREMENTALLY (bytes appended since the last
# look, one python over the delta, only when a fresh subagent file makes the
# answer matter), and the interrupt verdict is cached by mtime+size, so a
# finished file costs one tail read rather than two forks a second.
declare -A NOTIF_SIZE NOTIF_IDS INT_CACHE
notified_ids() {   # $1 parent transcript → NOTIF_IDS[$1] = " id=epoch id=epoch "
    local p="$1" size have out consumed
    size=$(stat -f %z "$p" 2>/dev/null) || return 0
    have="${NOTIF_SIZE[$p]:-0}"
    [ "$size" = "$have" ] && return 0
    if [ "$size" -lt "$have" ]; then NOTIF_IDS[$p]=" "; have=0; fi   # rotated
    out=$(tail -c +$((have + 1)) "$p" 2>/dev/null | python3 -c '
import sys, re, datetime
data = sys.stdin.buffer.read()
cut = data.rfind(b"\n") + 1            # never consume a half-written record
ids = []
for line in data[:cut].decode("utf-8", "replace").splitlines():
    if "<task-id>" not in line:
        continue
    m = re.search(r"<task-id>([^<]+)</task-id>", line)
    if not m:
        continue
    ep = 0
    t = re.search(r"\"timestamp\":\"([^\"]+)\"", line)
    if t:
        try:
            ep = int(datetime.datetime.fromisoformat(t.group(1).replace("Z", "+00:00")).timestamp())
        except Exception:
            pass
    ids.append("%s=%d" % (m.group(1), ep))
print(" ".join(ids))
print(cut)')
    consumed="${out##*$'\n'}"
    out="${out%$'\n'*}"
    [ "$consumed" -eq "$consumed" ] 2>/dev/null || return 0
    NOTIF_IDS[$p]="${NOTIF_IDS[$p]:- }${out} "
    NOTIF_SIZE[$p]=$((have + consumed))
}

# True if the claude session owning PID has a background SUBAGENT (the Agent
# tool) still out. Same gear as a workflow, on purpose: from the tab's point
# of view a turn that ended with three reviewers still running is in exactly
# the position of one with a fleet out - it looks finished and is not.
session_has_running_subagent() {
    local f mt size now age base id p tok when v last
    resolve_session_bases "$1" || return 1
    printf -v now '%(%s)T' -1
    for base in "${SESSION_BASES[@]}"; do
        [ -d "$SESSION_PROJ/$base/subagents" ] || continue
        p="$SESSION_PROJ/$base.jsonl"
        for f in "$SESSION_PROJ/$base"/subagents/agent-*.jsonl; do
            [ -f "$f" ] || continue
            mt=$(stat -f %m "$f" 2>/dev/null)
            [ -n "$mt" ] || continue
            age=$((now - mt))
            [ "$age" -lt 3600 ] || continue
            id="${f##*/agent-}"; id="${id%.jsonl}"
            # 1. Notified since it last moved → finished.
            notified_ids "$p"
            when=""
            for tok in ${NOTIF_IDS[$p]:-}; do
                case "$tok" in "$id="*) when="${tok#*=}" ;; esac
            done
            [ -n "$when" ] && [ "$when" -ge "$mt" ] && continue
            # 2. Interrupted by the user → finished. Cached by mtime+size.
            size=$(stat -f %z "$f" 2>/dev/null)
            v="${INT_CACHE[$f]:-}"
            if [ "${v%=*}" != "$mt.$size" ]; then
                last=$(tail -c 65536 "$f" 2>/dev/null | tail -n 1)
                case "$last" in
                    *'"type":"user"'*'"type":"text","text":"[Request interrupted by user'*) v="$mt.$size=1" ;;
                    *) v="$mt.$size=0" ;;
                esac
                INT_CACHE[$f]="$v"
            fi
            [ "${v#*=}" = 1 ] && continue
            # 3. Otherwise it is running.
            return 0
        done
    done
    return 1
}

# True if the claude session owning PID has a background Workflow in flight.
# Runtime dir without its completion file = running (see header). Scoped to
# the session's own project/<sid> dirs so other panes' workflows don't leak in.
session_has_running_workflow() {
    local d wfid mt now base b
    resolve_session_bases "$1" || return 1
    printf -v now '%(%s)T' -1
    for b in "${SESSION_BASES[@]}"; do
    base="$SESSION_PROJ/$b"
    [ -d "$base/subagents/workflows" ] || continue
    for d in "$base"/subagents/workflows/wf_*/; do
        [ -d "$d" ] || continue
        # ${d%/} then ##*/, not basename: these paths are cwd-munged and
        # start with a dash ("-Users-mackhaymond-..."), which basename would
        # parse as options if the path were ever relative. Same family as
        # the "-zsh" comm bug below.
        wfid="${d%/}"; wfid="${wfid##*/}"
        [ -f "$base/workflows/$wfid.json" ] && continue   # completion file → done
        # Backstop against a crashed/stale runtime dir. mtime is the only
        # liveness signal, but transcripts go quiet during long stalls (API
        # backoff, a tool with no timeout, a permission gate), so the old
        # 600s floor darkened the gear on workflows that were still running
        # (worst measured quiet gap on this machine: 394s). An hour gives
        # 9x that margin and still SELF-HEALS: a plain age test, on purpose.
        # Anchoring "live" to the session's own start instead would mean a
        # dir created this session never expires, so one crashed run would
        # pin the gear — and since done+workflow renders the tab untinted,
        # that would suppress this window's green for the rest of the
        # session. CuaNotch's runningWorkflows() must keep the same rule.
        mt=$(stat -f %m "$d"/agent-*.jsonl "$d/journal.jsonl" 2>/dev/null | sort -rn | head -1)
        [ -n "$mt" ] && [ $((now - mt)) -lt 3600 ] && return 0
    done
    done
    return 1
}

# Agent pids that have driven an app within CUA_LIVE seconds, space-delimited
# (" 123 456 "). Mirrors CuaNotch's own liveWindow so the tab and the notch
# light up and go dark together. Missing/garbage file → empty (never fatal).
ACTIVITY="$HOME/Library/Application Support/CuaNotch/activity.json"
# 60s, matching CuaNotch's liveWindow AND the shim's LOCK_TTL: a drive is in
# progress for as long as the shim holds its window lock, and an agent that
# thinks for 25s between two clicks is still driving. At 15 the tab glyph
# dropped out and came back on every model turn while the notch stayed lit —
# the two surfaces must light up and go dark together. Change both or neither.
CUA_LIVE=60
live_cua_pids() {
    [ -f "$ACTIVITY" ] || { printf ' '; return 0; }
    # Cheap gate before starting an interpreter (~22ms, every second,
    # forever): the shim rewrites this file on every driver call, so every
    # session ts is <= its mtime — an untouched file cannot hold a live
    # session, and the answer is the empty set without any python at all.
    local _now _amt
    printf -v _now '%(%s)T' -1
    _amt=$(stat -f %m "$ACTIVITY" 2>/dev/null || echo 0)
    [ $((_now - _amt)) -lt "$CUA_LIVE" ] || { printf ' '; return 0; }
    /usr/bin/python3 - "$ACTIVITY" "$CUA_LIVE" <<'PY' 2>/dev/null || printf ' '
import json, sys, time
try:
    with open(sys.argv[1]) as f:
        sessions = json.load(f).get("sessions", {}) or {}
except Exception:
    print(" "); raise SystemExit(0)
now, live = time.time(), float(sys.argv[2])
pids = {int(d["agent_pid"]) for d in sessions.values()
        if isinstance(d, dict) and d.get("agent_pid")
        and now - float(d.get("ts") or 0) < live}
# Emit a SINGLE space when the set is empty, matching the early-return paths.
# " " + "" + " " gave two, and the consumer's `*" ${pid} "*` test matches that
# with an empty pid — so an unset pid would have read as "driving an app" if
# its [ -n "$pid" ] guard were ever dropped. Don't leave a guard load-bearing
# in a caller when the producer can just not lie.
print((" " + " ".join(str(p) for p in sorted(pids)) + " ") if pids else " ")
PY
}

# A failed tmux command is NOT proof the server died — it can also be a
# transient hiccup (server mid-reload, EINTR, fd pressure). Exiting on the
# first one is how the daemon silently disappears after days of uptime, taking
# the blink, the workflow gear and the state GC with it and leaving no trace.
# Tolerate a short streak, and only quit once the server is confirmed gone.
FAIL_LIMIT=5
fail_streak=0
server_gone() { ! tmux list-sessions >/dev/null 2>&1; }

# Consecutive-idle counters for the stuck-`running` reconcile, carried across
# ticks as " @win=N @win=N " (see the hysteresis note in the loop).
idle_streak=" "

while :; do
    # window_id<space>pane_tty for every pane.
    if ! panes=$(tmux list-panes -a -F '#{window_id} #{pane_tty}' 2>/dev/null); then
        fail_streak=$((fail_streak + 1))
        { [ "$fail_streak" -ge "$FAIL_LIMIT" ] && server_gone; } && exit 0
        sleep "$POLL_SECONDS"
        continue
    fi

    # One ps for all TTYs: agent TTYs, plus tty=pid for every agent pane —
    # claude pids feed the workflow lookup (codex pids simply miss in
    # ~/.claude/sessions and fall through), and both kinds feed the
    # computer-use pid match (@agent_cua), which is agent-agnostic.
    # GUARDED like the two tmux reads around it. This was the one data source
    # in the loop that was not: a single empty/failed ps tick made has_agent=0
    # for every window, the GC below unset every @agent_* option, and the next
    # good tick reseeded them all to `idle` - which is TERMINAL for a mid-turn
    # agent, because the heartbeat only re-arms `running` from idle when
    # @agent_pending is set, and the GC had just cleared it. An empty listing
    # is never real (this very shell is in it), so it is treated as a failure.
    if ! ps_out=$(ps -ax -o tty=,pid=,comm= 2>/dev/null) || [ -z "$ps_out" ]; then
        fail_streak=$((fail_streak + 1))
        { [ "$fail_streak" -ge "$FAIL_LIMIT" ] && server_gone; } && exit 0
        sleep "$POLL_SECONDS"
        continue
    fi
    agent_ttys=" "
    tty_pid=" "
    while IFS=' ' read -r tty pid comm; do
        [ -n "$tty" ] && [ "$tty" != "??" ] || continue
        if is_agent_comm "$comm"; then
            agent_ttys="${agent_ttys}${tty} "
            case "${comm##*/}" in
                claude|codex|[0-9]*) tty_pid="${tty_pid}${tty}=${pid} " ;;
            esac
        fi
    done <<EOF
$ps_out
EOF

    # Current per-window state in one call (formats resolve window options).
    if ! states=$(tmux list-windows -a -F '#{window_id} #{@agent_state} #{window_active_clients}' 2>/dev/null); then
        fail_streak=$((fail_streak + 1))
        { [ "$fail_streak" -ge "$FAIL_LIMIT" ] && server_gone; } && exit 0
        sleep "$POLL_SECONDS"
        continue
    fi
    fail_streak=0

    # Windows containing at least one agent pane, and the claude pid per window
    # (first agent pane wins) for workflow lookup.
    present=" "
    win_pid=" "
    while IFS=' ' read -r win tty; do
        [ -n "$win" ] || continue
        short_tty="${tty#/dev/}"
        case "$agent_ttys" in
            *" ${short_tty} "*)
                present="${present}${win} "
                case "$win_pid" in
                    *" ${win}="*) : ;;   # already mapped
                    *)
                        for kv in $tty_pid; do
                            case "$kv" in "${short_tty}="*) win_pid="${win_pid}${win}=${kv#*=} "; break ;; esac
                        done
                        ;;
                esac
                ;;
        esac
    done <<EOF
$panes
EOF

    # Windows with a non-empty @agent_summary (read separately — a summary can
    # contain spaces, and it can outlive @agent_state: a detached condenser may
    # write a summary after the agent died and the watcher GC'd its state).
    with_summary=" "
    while IFS=' ' read -r win rest; do
        [ -n "$win" ] && [ -n "$rest" ] && with_summary="${with_summary}${win} "
    done <<EOF
$(tmux list-windows -a -F '#{window_id} #{@agent_summary}' 2>/dev/null)
EOF

    # Windows that currently carry @agent_workflow (to reconcile against).
    wf_now=" "
    while IFS=' ' read -r win rest; do
        [ -n "$win" ] && [ -n "$rest" ] && wf_now="${wf_now}${win} "
    done <<EOF
$(tmux list-windows -a -F '#{window_id} #{@agent_workflow}' 2>/dev/null)
EOF

    # Same, for @agent_cua, plus this tick's live driver pids (one read).
    cua_now=" "
    while IFS=' ' read -r win rest; do
        [ -n "$win" ] && [ -n "$rest" ] && cua_now="${cua_now}${win} "
    done <<EOF
$(tmux list-windows -a -F '#{window_id} #{@agent_cua}' 2>/dev/null)
EOF
    cua_pids=$(live_cua_pids)

    # win=<rollout path> for codex windows (see codex_status). Paths live under
    # ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl and contain no
    # spaces, so the flat "win=value" encoding used elsewhere holds.
    roll_map=" "
    while IFS=' ' read -r win rest; do
        [ -n "$win" ] && [ -n "$rest" ] && roll_map="${roll_map}${win}=${rest} "
    done <<EOF
$(tmux list-windows -a -F '#{window_id} #{@agent_rollout}' 2>/dev/null)
EOF

    changed=0
    any_workflow=0
    any_cua=0
    # Rebuilt each tick; a window that stops reading idle drops out, so the
    # streak only ever counts CONSECUTIVE observations.
    idle_streak_next=" "
    wez_front=""   # per tick, computed at most once, only if a tinted tab is watched
    while IFS=' ' read -r win state wac; do
        # SEEN-IT, CONTINUOUSLY. The hook discharges a yellow/green that lands
        # while the user is sitting on the tab with WezTerm focused; this is
        # the other order - the tint landed while WezTerm was behind something,
        # and the user then Cmd-Tabbed back to it without changing tabs, so no
        # select-window hook ever fires. Same test (active for a client AND
        # WezTerm frontmost), same discharge as clear-current, once a second.
        # Red is left alone: a dead turn is not answered by being looked at.
        # The frontmost lookup forks twice, so it runs only when there is a
        # tinted, watched window to ask about - almost never.
        case "$state" in
            done|needs-input)
                case "$wac" in ''|0|*[!0-9]*) : ;; *)
                    if [ -z "$wez_front" ]; then
                        wez_front=no
                        [ "$(lsappinfo info -only bundleid "$(lsappinfo front 2>/dev/null)" 2>/dev/null)" = \
                          '"CFBundleIdentifier"="com.github.wez.wezterm"' ] && wez_front=yes
                    fi
                    if [ "$wez_front" = yes ]; then
                        tmux set-option -w -t "$win" @agent_state idle 2>/dev/null && changed=1
                        [ "$state" = needs-input ] && \
                            tmux set-option -w -t "$win" @agent_pending "$(printf '%(%s)T' -1)" 2>/dev/null
                        state=idle
                    fi ;;
                esac ;;
        esac
        [ -n "$win" ] || continue
        case "$present" in
            *" ${win} "*) has_agent=1 ;;
            *) has_agent=0 ;;
        esac
        case "$with_summary" in
            *" ${win} "*) has_summary=1 ;;
            *) has_summary=0 ;;
        esac
        case "$wf_now" in
            *" ${win} "*) had_wf=1 ;;
            *) had_wf=0 ;;
        esac
        case "$cua_now" in
            *" ${win} "*) had_cua=1 ;;
            *) had_cua=0 ;;
        esac

        # Background-workflow + computer-use detection (both need a live agent
        # and share the one pane→pid lookup; workflows are claude-only).
        wf=0
        cua=0
        if [ "$has_agent" = 1 ]; then
            pid=""
            for kv in $win_pid; do
                case "$kv" in "${win}="*) pid="${kv#*=}"; break ;; esac
            done
            # A workflow or a background subagent: one gear for both.
            if [ -n "$pid" ] && { session_has_running_workflow "$pid" \
                                  || session_has_running_subagent "$pid"; }; then
                wf=1; any_workflow=1
            fi
            case "$cua_pids" in
                *" ${pid} "*) [ -n "$pid" ] && { cua=1; any_cua=1; } ;;
            esac
        fi
        if [ "$cua" = 1 ] && [ "$had_cua" = 0 ]; then
            tmux set-option -w -t "$win" @agent_cua 1 2>/dev/null && changed=1
        elif [ "$cua" = 0 ] && [ "$had_cua" = 1 ]; then
            tmux set-option -uw -t "$win" @agent_cua 2>/dev/null && changed=1
        fi
        if [ "$wf" = 1 ] && [ "$had_wf" = 0 ]; then
            tmux set-option -w -t "$win" @agent_workflow 1 2>/dev/null && changed=1
        elif [ "$wf" = 0 ] && [ "$had_wf" = 1 ]; then
            tmux set-option -uw -t "$win" @agent_workflow 2>/dev/null && changed=1
        fi

        # Un-stick a `running` tab whose session says it is idle (see
        # session_status). ONLY `running` is reconciled: the attention states
        # are "always asserted, discharged by focus" on purpose, and a session
        # sitting on an open permission gate also reads idle — clearing those
        # from here would silently drop live prompts, the one thing this
        # indicator must never do.
        #
        # HYSTERESIS, not a single reading. At turn start the hook and Claude's
        # own status write race, so one tick can legitimately see
        # state=running with a stale idle status. Acting on that would clear
        # the tab for the WHOLE turn — heartbeat re-arms running only from
        # running/needs-input, never from bare idle, so nothing would put it
        # back. Three consecutive idle ticks costs 3s of latency on a fix for
        # a tab that was previously stuck for the rest of the session, and
        # makes the race require three impossible coincidences in a row.
        agent_idle=0
        if [ "$state" = "running" ] && [ "$has_agent" = 1 ]; then
            st=""
            [ -n "$pid" ] && st=$(session_status "$pid")        # claude
            if [ -z "$st" ]; then                               # codex
                rp=""
                for kv in $roll_map; do
                    case "$kv" in "${win}="*) rp="${kv#*=}"; break ;; esac
                done
                # Only reached for a codex window ALREADY showing running, so
                # the tail read is bounded to that case; a long live turn pays
                # one read per tick until it ends, which is the price of having
                # no status file to poll.
                [ -n "$rp" ] && st=$(codex_status "$rp")
            fi
            [ "$st" = "idle" ] && agent_idle=1
        fi
        if [ "$agent_idle" = 1 ]; then
            n=0
            for kv in $idle_streak; do
                case "$kv" in "${win}="*) n="${kv#*=}"; break ;; esac
            done
            n=$((n + 1))
            if [ "$n" -ge 3 ]; then
                tmux set-option -w -t "$win" @agent_state idle 2>/dev/null && changed=1
                state=idle
            else
                idle_streak_next="${idle_streak_next}${win}=${n} "
            fi
        fi

        if [ "$has_agent" = 1 ] && [ -z "$state" ]; then
            tmux set-option -w -t "$win" @agent_state idle 2>/dev/null && changed=1
        elif [ "$has_agent" = 0 ] && { [ -n "$state" ] || [ "$has_summary" = 1 ]; }; then
            tmux set-option -uw -t "$win" @agent_state 2>/dev/null
            tmux set-option -uw -t "$win" @agent_summary 2>/dev/null
            tmux set-option -uw -t "$win" @agent_summary_cond 2>/dev/null
            tmux set-option -uw -t "$win" @agent_pending 2>/dev/null
            tmux set-option -uw -t "$win" @agent_rollout 2>/dev/null
            changed=1
        fi
    done <<EOF
$states
EOF

    idle_streak="$idle_streak_next"

    # Blink driver: toggle while anything is running or has a workflow in
    # flight; redraw covers both the toggle and any reconcile changes above.
    blink_active=0
    case "$states" in *" running"*) blink_active=1 ;; esac
    [ "$any_workflow" = 1 ] && blink_active=1
    [ "$any_cua" = 1 ] && blink_active=1
    if [ "$blink_active" = 1 ]; then
        if [ "$(tmux show-options -gqv @agent_blink 2>/dev/null)" = "1" ]; then
            tmux set-option -g @agent_blink 0 2>/dev/null
        else
            tmux set-option -g @agent_blink 1 2>/dev/null
        fi
        changed=1
    fi

    if [ "$changed" = 1 ]; then
        tmux refresh-client -S 2>/dev/null
    fi

    # HEARTBEAT. Being alive is not the same as turning: every check on this
    # daemon (the pidfile, ensure_watcher's kill -0 + ps) proves a PROCESS
    # exists, and none of them prove the LOOP is still going round. A tmux
    # call or the python in live_cua_pids wedging would leave a healthy-
    # looking watcher that has quietly stopped reconciling, and since the
    # working chip went pink↔blue a frozen blink renders as plain blue —
    # i.e. identical to idle, so the surface lies rather than merely going
    # quiet. Restamping the pidfile each tick makes the mtime a liveness
    # clock that ensure_watcher can test. Builtin redirect: no fork.
    #
    # Reading it back first also settles a race the startup guard can't: if
    # a newer instance has claimed the file, WE are the stale one and should
    # go, rather than both of us toggling @agent_blink and cancelling out.
    read -r _owner < "$PIDFILE" 2>/dev/null || _owner="$$"
    [ "$_owner" = "$$" ] || exit 0
    echo $$ > "$PIDFILE"

    sleep "$POLL_SECONDS"
done
