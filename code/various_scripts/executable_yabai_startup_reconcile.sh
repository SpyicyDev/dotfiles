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
# window, WINDOW_FLOAT)`) -- i.e. any window whose AX position attribute is not
# settable at the instant yabai looks, which a window still settling after a restore
# can be. Nothing clears the flag afterwards: `rule --apply` re-pins the SPACE but
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

# Required siblings, resolved by directory rather than $HOME so a chezmoi checkout or
# a test copy runs against its own copies: yabai_common.sh (the agent app list and the
# pinned-home map) and yabai_float_borders.sh (called after an un-float).
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/yabai_common.sh"
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

# The pinned app -> home space map (JSON) comes from yabai_common.sh, which is where
# this codebase keeps lists that more than one script needs. Computed ONCE at startup,
# not per pass: it is a pure function of two constants, and the poll can run ~45 times.
PIN_HOMES=$(yabai_home_map_json)

# A window this script may un-float. yabai floats plenty of windows ON PURPOSE and
# every one of them must be left alone -- a pinned app's non-standard second window
# (settings sheet, save panel, palette), a sticky window, a scratchpad window, a
# minimized or hidden one (which also reports can-move=false, so an un-float would be
# dropped anyway), and a native-fullscreen window. This mirrors the eligibility filter
# yabai_workspace_refresh.sh's space_for_app() already applies for the same reason.
#
# The filter is shared with pins_settled() BY CONSTRUCTION: if a window is ineligible
# here it must not count as unsettled there either, or the poll spins to the cap every
# 2s on a window this function will never touch.
#
# Deliberately NOT filtered on `can-move`: a window yabai cannot move right now is the
# transient case this whole script exists for (that is what makes yabai flag FLOAT in
# the first place), and it usually becomes movable a second later. Such a window stays
# a candidate, its un-float is silently dropped, the verify catches that, and the poll
# retries it -- bounded by MAX_ATTEMPTS so it cannot hold the loop open forever.
JQ_ELIGIBLE='
  select(.subrole == "AXStandardWindow")
  | select(."root-window")
  | select(."is-minimized" == false and ."is-hidden" == false)
  | select(."is-sticky" == false and ."is-native-fullscreen" == false)
  | select((.scratchpad // "") == "")'

# ~20s of retries at the loop's 2s cadence -- long enough for a slow Electron window to
# become movable, short enough that a permanently stuck one does not cost the full cap.
MAX_ATTEMPTS=10

# Space index -> label, plus the label of the FOCUSED space. Focused, not merely
# visible: yabai re-tiles an un-floated window onto space_manager_active_space(),
# which resolves to the space of the focused window's display -- i.e. the has-focus
# space, the one place an un-float lands correctly with no repair.
JQ_SPACE_MAPS='
  ($s | map({ (.index|tostring): (.label // "") }) | add) as $lbl
  | (($s | map(select(."has-focus")) | first | .label) // "") as $focused'

# Are all RUNNING pinned apps on their home space AND not flagged FLOAT? Arc is handled
# by arcSync and is excluded; windows on an UNLABELED space (e.g. a native-fullscreen
# one) are ignored -- yabai never tiles those, so a floating one is correct.
#
# The float half is NOT re-derived here. unfloat_pins() runs first each pass and leaves
# PENDING_FLOATS = how many windows it still intends to retry; anything it decided to
# skip for good (ineligible, or floating on a bsp space it must not rebuild) is
# deliberately NOT counted. Deriving that twice is how the predicate and the repair
# drift apart, and a window the repair will never touch keeping the poll hot -- and
# `rule --apply` + arcSync firing every 2s -- for the whole cap is the expensive kind
# of drift. One decision point, in unfloat_pins; this just reads the tally.
#
# Takes the windows/spaces blobs so the poll queries yabai once per pass rather than
# once per predicate.
pins_settled() {
  local off
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  [ "${PENDING_FLOATS:-0}" = "0" ] || return 1
  off=$(jq -n --argjson w "$1" --argjson s "$2" --argjson home "$PIN_HOMES" '
    ($s | map({ (.index|tostring): (.label // "") }) | add) as $lbl
    | [ $w[]
        | select($home[.app] != null)
        # Only windows yabai would ever move. An Electron app publishes hidden helper
        # windows with an EMPTY subrole and can-move=false -- Claude Desktop ships two,
        # parked on whatever space it launched from. `rule --apply` cannot move them, so
        # counting them meant this poll could NEVER settle and burned its whole cap,
        # re-running rule --apply + arcSync every 2s, at every login. (Pre-dates the
        # un-float work; found 2026-08-21 when two such windows appeared mid-test.)
        | select(.subrole == "AXStandardWindow")
        | select(."root-window")
        | { want: $home[.app], have: ($lbl[(.space|tostring)] // "") }
        | select(.have != "" and .have != .want) ]
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
# The repair is to REBUILD THE HOME SPACE'S VIEW afterwards -- `--layout bsp` then back
# to `--layout stack` re-derives the tree from actual window->space membership, which
# both re-homes the window and drops the stale registration from the other view.
# Verified live 2026-08-21: with `terminal` active, a corrupted `todo` (Todoist sharing
# WezTerm's view at stack-index 1/2) came back correct -- Todoist alone on `todo`,
# WezTerm alone on `terminal` -- by flipping `todo` ALONE, addressed by label.
#
# The obvious alternative -- bounce the window through another space and back, so
# send_window_to_space() re-tiles it on the destination -- was implemented first and is
# WRONG here. It needs the scripting addition, which may not be loaded yet at login
# (`window --space` then fails SILENTLY and exit-0, so the failure is undetectable and
# the window is left cross-registered); yabai REFUSES to move a window into a
# native-fullscreen space, which strands WezTerm off `terminal` whenever
# yabai_terminal_follow.sh has moved that label onto a fullscreen Space; the outbound
# leg hands focus to another window when the source space is visible
# (window_manager.c:2099); and it parks the window somewhere
# yabai_workspace_refresh.sh's label-follows-app logic can see and re-label it. The
# flip touches no window and needs no scripting addition.
#
# It costs one thing: a flip re-derives a bsp tree from scratch, losing hand-tuned
# splits. So a window whose home space is bsp AND not the active space is SKIPPED
# rather than repaired -- left floating, which is the benign failure. Every space in
# this config is `stack` (yabairc sets `layout stack`), so that path is currently dead.
#
# This is also why `manage=on` on the yabairc space= rules is the wrong fix: it does
# suppress the misclassification for windows created while yabai is already running
# (window_manager.c:1498 skips the FLOAT classification for WINDOW_RULE_MANAGED), but
# it cannot help at startup (rules do not exist yet during window discovery), and it
# makes `rule --apply` -- which yabairc fires at startup and on every
# application_launched -- take the un-float path above from whatever space happens to
# be active. That trades a floating window for a corrupted cross-space stack.
unfloat_pins() {
  local floaters id label layout focused attempts changed=0 pending=0

  PENDING_FLOATS=0
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0

  # id, home LABEL (never an index -- indices renumber, and yabai_workspace_refresh.sh
  # / yabai_reorder_spaces.sh / yabai_displays.sh can all renumber them mid-poll; the
  # siblings compare by label for exactly this reason), the home space's layout, and
  # whether that space is the focused one.
  floaters=$(jq -r -n --argjson w "$1" --argjson s "$2" --argjson home "$PIN_HOMES" "
    $JQ_SPACE_MAPS
    | (\$s | map({ (.index|tostring): (.type // \"\") }) | add) as \$type
    | \$w[]
    | select(\$home[.app] != null)
    | select(.\"is-floating\")
    | $JQ_ELIGIBLE
    | { l: (\$lbl[(.space|tostring)] // \"\"), t: (\$type[(.space|tostring)] // \"\") }
      as \$sp
    | select(\$sp.l != \"\")
    | \"\(.id) \(\$sp.l) \(\$sp.t) \(if \$sp.l == \$focused then 1 else 0 end)\"
    " 2>/dev/null) || return 0
  [ -n "$floaters" ] || return 0

  while read -r id label layout focused; do
    [ -n "$id" ] && [ -n "$label" ] || continue

    # Decide repairability BEFORE touching anything: un-floating a window we then
    # cannot re-home would leave the corruption instead of the float.
    [ "$focused" = "1" ] || [ "$layout" = "stack" ] || continue

    # Give up on a window that keeps refusing, so one stubborn case cannot keep the
    # poll hot -- and the active space thrashing -- for the whole 90s cap.
    attempts="ATTEMPT_${id}"
    eval "attempts=\${$attempts:-0}"
    [ "$attempts" -ge "$MAX_ATTEMPTS" ] && continue
    eval "ATTEMPT_${id}=$((attempts + 1))"

    yabai -m window "$id" --toggle float >/dev/null 2>&1 || { pending=$((pending + 1)); continue; }
    # An un-float attempted too early is dropped SILENTLY and exit-0 (the force=false
    # path returns without a daemon_fail), so the exit status proves nothing -- and a
    # `--toggle` acts on a snapshot that may be stale by now, e.g. because the user
    # just pressed hyper+t. Confirm the post-state, and undo an accidental float.
    case "$(yabai -m query --windows --window "$id" 2>/dev/null \
            | jq -r '."is-floating"' 2>/dev/null)" in
      false) : ;;
      true)  yabai -m window "$id" --toggle float >/dev/null 2>&1 || true
             pending=$((pending + 1)); continue ;;
      *)     pending=$((pending + 1)); continue ;;
    esac
    changed=1

    # Rebuild the home view unless the un-float already landed there (home == the
    # focused space => yabai tiled it correctly and a flip would only churn the view
    # the user is looking at). Cheap and idempotent on a stack space; a bsp home space
    # never reaches here -- it was skipped above.
    [ "$focused" = "1" ] && continue
    yabai -m space "$label" --layout bsp   >/dev/null 2>&1 || continue
    yabai -m space "$label" --layout stack >/dev/null 2>&1 || true
  done <<EOF
$floaters
EOF

  # What pins_settled() reads: windows still floating that this function intends to
  # retry. Skipped-for-good cases were never counted, so they cannot hold the poll open.
  PENDING_FLOATS=$pending

  # An un-float changes the float set but emits no window_created/destroyed -- the same
  # gap yabai_toggle_float.sh covers after hyper+t. Without this the borders daemon
  # keeps the stale whitelist yabairc's startup `sync` gave it and draws a floating-
  # window border around a window that is now tiled. Gated on an actual change: the
  # sync forks a full query + a 0.15s settle, and on a stubborn window the poll would
  # otherwise fire ~45 of them, most of which lose that script's own single-flight lock.
  [ "$changed" = "1" ] || return 0
  "$SCRIPT_DIR/yabai_float_borders.sh" sync >/dev/null 2>&1 || true
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

  # One pair of queries per pass, shared by both predicates below (they used to query
  # yabai twice each -- 4 round trips a pass, ~45 passes at the cap).
  win=$(yabai -m query --windows 2>/dev/null) || win=""
  # Not a bare `yabai -m query --spaces`: that call intermittently returns "[" for
  # minutes at a time, and without the fallback both predicates below go blind and the
  # poll burns its whole cap doing nothing (seen exactly that way while testing this).
  spaces=$(yabai_spaces_json) || spaces=""

  unfloat_pins "$win" "$spaces"
  # unfloat_pins mutates what pins_settled reads, so re-read rather than reuse the
  # blobs above -- otherwise a pass that just healed everything still reports unsettled
  # and the poll always costs one extra 2s sleep.
  pins_settled "$(yabai -m query --windows 2>/dev/null)" "$spaces" && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 2
done
