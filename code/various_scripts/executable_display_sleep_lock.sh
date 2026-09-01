#!/bin/sh
# Sleep the displays now; the machine's immediate screen-lock policy locks
# the session with them. Bound to hyper+fn-s in skhd (2026-08-31, Mack's ask).
#
# This must ALWAYS work — including while an agent holds a display-awake
# assertion (the cua v2 spec's caffeinate -d during active GUI runs): forced
# sleep overrides idle-sleep assertions. The v2 assertion PASSED that canary
# on 2026-09-01 and is enabled.
#
# The wait is load-bearing: skhd fires on key-DOWN, and sleeping the display
# before the chord's key RELEASES land re-wakes it within ~1s (macOS counts
# them as HID activity — AppleHIDTransportHIDDevice ActivityTickle in
# `pmset -g log`) and the Apple Watch then auto-unlocks the lit lock screen.
# Measured 2026-09-01. A flat 0.7s pad felt laggy, so instead: sleep as soon
# as HID input has been quiet for 0.15s (typically ~0.3s after the press),
# capped at 1.2s if keys are held.
exec /usr/bin/python3 - <<'PY'
import ctypes
import ctypes.util
import subprocess
import time

cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
cg.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
cg.CGEventSourceSecondsSinceLastEventType.argtypes = [
    ctypes.c_int, ctypes.c_uint32]

HID_STATE, ANY_EVENT = 1, 0xFFFFFFFF
deadline = time.time() + 1.2
while time.time() < deadline:
    if cg.CGEventSourceSecondsSinceLastEventType(HID_STATE, ANY_EVENT) >= 0.15:
        break
    time.sleep(0.03)
subprocess.run(["pmset", "displaysleepnow"])
PY
