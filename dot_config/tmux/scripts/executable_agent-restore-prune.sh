#!/usr/bin/env bash
# tmux-resurrect post-restore-all hook: drop the dead copies of agent PTYs.
#
# WHY THIS EXISTS
# tmux-pty-mcp keeps every agent's shell as a window in the `agents` session
# and identifies each one by WINDOW OPTIONS (@pty_session, @pty_owner_pid,
# ...). resurrect saves window names but not window options, so a restore
# brings every agent window back as an idle zsh that no server can ever claim
# again — the live server matches on options, finds nothing, and opens a fresh
# window beside the corpse. Observed 2026-08-29: 80 such shells restored in one
# burst, from sessions that had been dead for days.
#
# The server's sweep now ages these out after its grace period; this hook just
# spares the machine an hour of 80 idle shells by pruning them on arrival.
#
# WHAT IT DOES
# Kills windows in `agents` that (a) carry no @pty_owner_pid, (b) are not the
# dashboard, and (c) are running nothing but a shell. Anything with a command
# in it is somebody's and is left alone.

set -uo pipefail

SESSION="${PTY_MCP_SESSION:-agents}"
LOG="${HOME}/.local/state/tmux-pty-mcp/exits.log"

tmux has-session -t "=${SESSION}" 2>/dev/null || exit 0

n=0
while IFS='|' read -r wid name owner cmd; do
	[ -n "$owner" ] && continue
	[ "$name" = "_dashboard" ] && continue
	case "$cmd" in zsh | bash | fish | sh | -zsh | -bash) ;; *) continue ;; esac
	tmux kill-window -t "$wid" 2>/dev/null && n=$((n + 1))
done < <(tmux list-windows -t "=${SESSION}" -F '#{window_id}|#{window_name}|#{@pty_owner_pid}|#{pane_current_command}')

if [ "$n" -gt 0 ]; then
	mkdir -p "$(dirname "$LOG")" 2>/dev/null
	printf '[%s] agent-restore-prune: killed %d resurrect-restored agent window(s) with no owner tag\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$n" >>"$LOG" 2>/dev/null
fi
exit 0
