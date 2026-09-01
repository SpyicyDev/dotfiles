#!/bin/sh
# Sleep the displays now; the machine's immediate screen-lock policy locks
# the session with them. Bound to hyper-s in skhd (2026-08-31, Mack's ask).
#
# This must ALWAYS work — including while an agent holds a display-awake
# assertion (the cua v2 spec's caffeinate -d during active GUI runs): forced
# sleep overrides idle-sleep assertions. The v2 assertion PASSED that canary
# on 2026-09-01 and is enabled.
#
# The delay is load-bearing: skhd fires on key-DOWN, and without it the
# chord's key RELEASES land after the display sleeps — macOS counts them as
# HID user activity (AppleHIDTransportHIDDevice ActivityTickle in pmset -g
# log), wakes the display within ~1s, and the Apple Watch then auto-unlocks
# the lit lock screen. Measured 2026-09-01. 0.7s lets the fingers come off
# first.
sleep 0.7
exec pmset displaysleepnow
