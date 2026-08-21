#!/bin/bash

# Startup reconciliation -- fixes pinned apps landing on the WRONG space, or landing
# FLOATING, after login or a yabai restart.
#
# 1. WRONG SPACE. At login, macOS restores app windows around the same time yabai
# starts. Windows created before yabai registered its signals get no window_created/
# application_launched event, and yabairc's one-shot `rule --apply` can run BEFORE
# those windows exist -- or before `sudo yabai --load-sa` finishes (window->space
# moves need the scripting addition). Result: pinned apps (WezTerm, Todoist, Granola,
# Spark Mail, Notion Calendar, Messages, ChatGPT, Claude, the coding-agent apps; Arc
# via Hammerspoon) sit on the wrong space until a manual `yabai --restart-service`.
#
# 2. FLOATING. yabai classifies every window it finds at startup BEFORE the config
# runs (main.c: window_manager_begin() precedes exec_config_file()), so no rule can
# influence that pass. A window it momentarily cannot move is flagged FLOAT for good
# (window_manager.c: `if (... || !window_can_move(window) || ...) window_set_flag(
# window, WINDOW_FLOAT)`) -- i.e. any window whose AX position/size attributes are
# not settable at the instant yabai looks, which a window still settling after a
# restore can be. Nothing clears the flag afterwards: `rule --apply` re-pins the SPACE but
# leaves the window floating, so it sits unmanaged on that space indefinitely.
# Observed 2026-08-21: Claude floating on `ai` after a yabai restart, while ChatGPT
# on the same space tiled normally. `manage=on` on the space= rules does NOT fix
# this -- see the comment on unfloat_pins() for why it makes things worse.
#
# This POLLS UNTIL STABLE: re-load the scripting addition once, then repeatedly
# re-apply the space= rules, re-pin Arc, and un-float any misclassified pinned window
# until every RUNNING pinned app is home AND tiled (or a hard time cap). Polling
# self-truncates on a fast login (exits in a couple of seconds) and self-extends for
# slow-launching apps (Electron: ChatGPT, Notion Calendar, Messages) -- more robust
# than a fixed ramp, which could miss an app that finishes restoring after the last
# pass. The float pass needs the retry too: an un-float attempted while the window
# still cannot be moved is silently dropped by yabai (window_manager.c:2187-2193).
#
# Run BACKGROUNDED from yabairc (`"$YABAI_STARTUP_RECONCILE" &`) so it NEVER blocks
# yabai startup. Single-flighted (mkdir lock, like yabai_heal.sh) so repeated
# restarts don't stack overlapping polls. Every action is idempotent.

set -u

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export USER="${USER:-$(id -un)}"
HS="/opt/homebrew/bin/hs"

CAP_SECONDS="${YABAI_RECONCILE_CAP:-90}"   # hard stop so a never-launching app can't poll forever

# shellcheck source=/dev/null  # required sibling: the agent app list (YABAI_AGENT_*)
. "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/yabai_common.sh"
LOCK="${TMPDIR:-/tmp}/yabai_startup_reconcile.lock"

# Single-flight (mirrors yabai_heal.sh): one reconcile at a time. A concurrent
# (re)start drops -- the in-flight poll already re-applies against current state.
# Recover a lock orphaned by a crash, older than the cap + margin so a live poll is
# never reaped.
if ! mkdir "$LOCK" 2>/dev/null; then
  now=$(date +%s)
  mtime=$(stat -f %m "$LOCK" 2>/dev/null || printf '%s' "$now")
  if [ "$((now - mtime))" -ge "$((CAP_SECONDS + 30))" ]; then
    rmdir "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Pinned app -> home space label, as JSON. Mirrors the `space=` rules in yabairc and
# the pinned-home guards in yabai_toggle_float.sh / yabai_send_window.sh; the agent
# apps come from yabai_common.sh so that half can never drift. The single copy in
# this file -- both pins_settled() and unfloat_pins() read it.
pin_home_map() {
  jq -n --arg agents "$YABAI_AGENT_APPS" --arg agentlabel "$YABAI_AGENT_LABEL" '
    ($agents | split("|") | map({ (.): $agentlabel }) | add) as $agent_home
    | { "wezterm-gui":"terminal", "WezTerm":"terminal", "Todoist":"todo",
        "Granola":"schedule", "Spark Mail":"mail", "Notion Calendar":"calendar",
        "Messages":"messages", "ChatGPT":"ai", "Claude":"ai" } + $agent_home' 2>/dev/null
}

# Are all RUNNING pinned apps on their home space AND tiled? Arc is handled by arcSync
# and is excluded here; windows on an UNLABELED space (e.g. native-fullscreen) are
# ignored -- yabai never tiles those, so a floating one is correct, not a defect.
# Returns 0 (settled) when no pinned-app window sits on a wrong labeled space or
# floats on a labeled one.
pins_settled() {
  local win spaces home off
  win=$(yabai -m query --windows 2>/dev/null) || return 1
  spaces=$(yabai -m query --spaces 2>/dev/null) || return 1
  home=$(pin_home_map) && [ -n "$home" ] || return 1
  off=$(jq -n --argjson w "$win" --argjson s "$spaces" --argjson home "$home" '
    ($s | map({ (.index|tostring): (.label // "") }) | add) as $lbl
    | [ $w[]
        | select($home[.app] != null)
        | { want: $home[.app], have: ($lbl[(.space|tostring)] // ""), float: ."is-floating" }
        | select(.have != "")
        | select(.have != .want or .float) ]
    | length' 2>/dev/null) || return 1
  [ "${off:-1}" = "0" ]
}

# Re-manage pinned windows that yabai misclassified as floating (see failure mode 2
# in the header). `--toggle float` is the only lever, and it comes with a trap:
#
#   yabai re-tiles an un-floated window onto the ACTIVE space, not onto the window's
#   own space -- window_manager_make_window_floating() ends in
#   `space_manager_tile_window_on_space(sm, window, space_manager_active_space())`.
#
# So un-floating a window that lives on a BACKGROUND space silently registers it in
# the active space's view: two windows on different spaces sharing one stack, and the
# window that legitimately owned that view gets pushed out. Verified live 2026-08-21
# (Claude on `ai` un-floated while `terminal` was active -> WezTerm and Claude came
# back as stack-index 1 and 2 of the same view, ChatGPT ejected to 0).
#
# The repair is to bounce the window through another space afterwards:
# window_manager_send_window_to_space() untiles it from whatever view currently holds
# it and re-tiles it on the DESTINATION space, so a round trip lands it in its own
# tree. It is a no-op in the case where the un-float already landed correctly (the
# window's space happened to be active), so it runs unconditionally -- no branch to
# get wrong. The scratch space is picked to be neither home nor the space the user is
# looking at, so the bounce never flashes a window onto their screen.
#
# This is also why `manage=on` on the yabairc space= rules is the wrong fix: it does
# suppress the misclassification for windows created while yabai is already running
# (window_manager.c:1498 skips the FLOAT classification for WINDOW_RULE_MANAGED), but
# it cannot help at startup (rules do not exist yet during window discovery), and it
# makes `rule --apply` -- which yabairc fires at startup and on every
# application_launched -- take the un-float path above from whatever space happens to
# be active. That trades a floating window for a corrupted cross-space stack.
unfloat_pins() {
  local win spaces home active floaters id sp scratch
  win=$(yabai -m query --windows 2>/dev/null) || return 0
  spaces=$(yabai -m query --spaces 2>/dev/null) || return 0
  home=$(pin_home_map) && [ -n "$home" ] || return 0

  floaters=$(jq -r -n --argjson w "$win" --argjson s "$spaces" --argjson home "$home" '
    ($s | map({ (.index|tostring): (.label // "") }) | add) as $lbl
    | $w[]
    | select($home[.app] != null)
    | select(."is-floating")
    | select(($lbl[(.space|tostring)] // "") != "")
    | "\(.id) \(.space)"' 2>/dev/null) || return 0
  [ -n "$floaters" ] || return 0

  active=$(printf '%s' "$spaces" | jq -r '.[] | select(."has-focus") | .index' 2>/dev/null)

  printf '%s\n' "$floaters" | while read -r id sp; do
    [ -n "$id" ] && [ -n "$sp" ] || continue

    yabai -m window "$id" --toggle float >/dev/null 2>&1 || continue
    # An un-float attempted too early is dropped silently, and bouncing a window that
    # is still floating would only shuffle it between spaces -- so confirm it took.
    [ "$(yabai -m query --windows --window "$id" 2>/dev/null \
         | jq -r '."is-floating"' 2>/dev/null)" = "false" ] || continue

    # Never home (a same-space move is a no-op: send_window_to_space returns early
    # when src == dst) and never the space the user is looking at. `agent` is tried
    # first because it is the designated background space -- nothing of the user's
    # lives there, so a sub-second visit is the least likely to ever be seen.
    scratch=$(printf '%s' "$spaces" | jq -r \
      --arg h "$sp" --arg a "${active:-}" --arg pref "$YABAI_AGENT_LABEL" '
      [ .[] | select((.label // "") != "") ]
      | (map(select(.label == $pref)) + .)
      | map(.index | tostring)
      | map(select(. != $h and . != $a))
      | first // empty' 2>/dev/null)
    [ -n "$scratch" ] || continue

    yabai -m window "$id" --space "$scratch" >/dev/null 2>&1 || continue
    yabai -m window "$id" --space "$sp"      >/dev/null 2>&1 || true
  done

  # The float set just changed, and an un-float emits no window_created/destroyed --
  # the same gap yabai_toggle_float.sh covers after hyper+t. Without this the borders
  # daemon keeps the stale whitelist yabairc's startup `sync` gave it and draws a
  # floating-window border around a window that is now tiled. Only reached when there
  # was at least one floating pinned window, and sync is a no-op if borders is absent.
  "$HOME/code/various_scripts/yabai_float_borders.sh" sync >/dev/null 2>&1 || true
}

# Ensure the scripting addition is loaded (window->space moves need it). `-n` so a
# stale NOPASSWD hash fast-fails instead of ever waiting on a prompt in this
# TTY-less context.
sudo -n yabai --load-sa >/dev/null 2>&1 || true

# Re-assert pins until everything restored has landed home and tiled, or we hit the
# cap. unfloat_pins runs AFTER `rule --apply` each pass so a window is already on its
# home space before it is un-floated -- the space= move re-tiles on the destination
# by itself, leaving only genuine misclassifications for unfloat_pins to repair.
deadline=$(( $(date +%s) + CAP_SECONDS ))
while :; do
  yabai -m rule --apply >/dev/null 2>&1 || true
  "$HS" -c "arcSync()" >/dev/null 2>&1 || true
  unfloat_pins
  pins_settled && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 2
done
