#!/bin/sh
# Sleep the displays now; the machine's immediate screen-lock policy locks
# the session with them. Bound to hyper-s in skhd (2026-08-31, Mack's ask).
#
# This must ALWAYS work — including while an agent holds a display-awake
# assertion (the cua v2 spec's caffeinate -d during active GUI runs): forced
# sleep overrides idle-sleep assertions. The v2 assertion ships only after
# its canary confirms this override on this machine.
exec pmset displaysleepnow
