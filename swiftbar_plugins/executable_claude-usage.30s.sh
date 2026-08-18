#!/bin/bash

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export USER="${USER:-$(id -un)}"

# <swiftbar.title>Claude Usage</swiftbar.title>
# <swiftbar.desc>Session + weekly Claude usage from the codexbar tmux cache, stacked on two menu bar lines.</swiftbar.desc>
# <swiftbar.runInBash>true</swiftbar.runInBash>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# Same source of truth as the tmux status modules: codexbar-usage-status.sh
# owns the fetch/auth/backoff logic and the cache file; this plugin only reads
# the cache and delegates refresh/login to that script.
SRC="$HOME/.config/tmux/scripts/codexbar-usage-status.sh"
CACHE_DIR="$HOME/.cache/codexbar-tmux"
CACHE_FILE="$CACHE_DIR/usage.json"
BACKOFF_FILE="$CACHE_DIR/refresh_backoff_claude"
STALE_AFTER_SECONDS=120

RENDER_SRC="$CACHE_DIR/swiftbar-claude-render.swift"
RENDER_BIN="$CACHE_DIR/swiftbar-claude-render"

# Catppuccin mocha on the dark menu bar, latte on the light one. SwiftBar
# exports OS_APPEARANCE; fall back to defaults when run by hand.
appearance="${OS_APPEARANCE:-}"
if [[ -z "$appearance" ]]; then
  defaults read -g AppleInterfaceStyle 2>/dev/null | grep -q Dark && appearance="Dark"
fi
if [[ "$appearance" == "Dark" ]]; then
  GREEN='#a6e3a1'; YELLOW='#f9e2af'; RED='#f38ba8'; AUTH='#cba6f7'; GRAY='#a6adc8'; TEXTC='#ffffff'
else
  GREEN='#40a02b'; YELLOW='#df8e1d'; RED='#d20f39'; AUTH='#8839ef'; GRAY='#6c6f85'; TEXTC='#000000'
fi

color_to_hex() {
  case "$1" in
    green)  printf '%s' "$GREEN" ;;
    yellow) printf '%s' "$YELLOW" ;;
    red)    printf '%s' "$RED" ;;
    \#*)    printf '%s' "$1" ;;
    *)      printf '%s' "$GRAY" ;;
  esac
}

strip_legacy_prefix() {
  local v="${1:-}"
  v="${v#S:}"
  v="${v#W:}"
  [[ "$v" == "--" ]] && v="--%"
  printf '%s' "$v"
}

now_epoch() { date +%s; }

format_time_until() {
  local resets_at="$1" now="$2"
  [[ "$resets_at" =~ ^[0-9]+$ ]] || { printf '%s' '--'; return 0; }
  local delta=$(( resets_at - now ))
  (( delta > 0 )) || { printf '%s' '--'; return 0; }
  local total_minutes=$(( delta / 60 ))
  (( total_minutes > 0 )) || { printf '%s' '<1m'; return 0; }
  local days=$(( total_minutes / (60 * 24) ))
  local hours=$(( (total_minutes / 60) % 24 ))
  local minutes=$(( total_minutes % 60 ))
  if (( days >= 1 )); then
    printf '%dd%dh' "$days" "$hours"
  elif (( hours >= 1 )); then
    printf '%dh%dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

format_reset_daytime() {
  local resets_at="$1"
  [[ "$resets_at" =~ ^[0-9]+$ ]] || return 1
  date -r "$resets_at" "+%a %-l:%M%p" 2>/dev/null | sed 's/AM$/am/;s/PM$/pm/'
}

PLUGIN_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"

do_refresh_now() {
  rm -f "$BACKOFF_FILE"
  CODEXBAR_USAGE_FORCE_REFRESH=1 "$SRC" --refresh >/dev/null 2>&1 || true
  "$SRC" --publish >/dev/null 2>&1 || true
  command -v tmux >/dev/null 2>&1 && tmux refresh-client -S >/dev/null 2>&1 || true
}

case "${1:-}" in
  refresh-now) do_refresh_now; exit 0 ;;
esac

ensure_renderer() {
  command -v swiftc >/dev/null 2>&1 || command -v xcrun >/dev/null 2>&1 || return 1
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "${RENDER_SRC}.tmp.XXXXXX")" || return 1
  cat >"$tmp" <<'SWIFT_EOF'
import AppKit

// args: main1 mainHex1 suffix1 suffixHex1 main2 mainHex2 suffix2 suffixHex2
// -> base64 PNG (2x pixels, 1x point size via DPI). The suffix (pace delta)
// is appended after a space in its own color; empty suffix draws nothing.
let a = CommandLine.arguments
guard a.count >= 9 else {
    FileHandle.standardError.write(Data("usage: render main1 hex1 suffix1 hex1s main2 hex2 suffix2 hex2s\n".utf8))
    exit(2)
}

func parseColor(_ hex: String) -> NSColor {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .white }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255,
                   alpha: 1)
}

let scale: CGFloat = 2
// Fully monospaced so the two lines align column-for-column (the bash side
// pads the percent field to a fixed width).
let font = NSFont.monospacedSystemFont(ofSize: 8.5 * scale, weight: .semibold)

// suffix is the bare pace delta ("-66%"); the wrapping parens are drawn in
// the main color so only the number/sign/percent carries the pacing color.
func makeLine(_ main: String, _ mainHex: String, _ suffix: String, _ suffixHex: String) -> NSAttributedString {
    let mainAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: parseColor(mainHex)]
    let suffixAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: parseColor(suffixHex)]
    let s = NSMutableAttributedString(string: main, attributes: mainAttrs)
    if !suffix.isEmpty {
        s.append(NSAttributedString(string: " (", attributes: mainAttrs))
        s.append(NSAttributedString(string: suffix, attributes: suffixAttrs))
        s.append(NSAttributedString(string: ")", attributes: mainAttrs))
    }
    return s
}

let lines: [NSAttributedString] = [
    makeLine(a[1], a[2], a[3], a[4]),
    makeLine(a[5], a[6], a[7], a[8]),
]

let pad: CGFloat = 1 * scale
let lineH = ceil(max(lines[0].size().height, lines[1].size().height))
let pixW = Int(ceil(max(lines[0].size().width, lines[1].size().width) + pad * 2))
let pixH = Int(lineH * 2)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: max(pixW, 1),
                                 pixelsHigh: max(pixH, 1),
                                 bitsPerSample: 8,
                                 samplesPerPixel: 4,
                                 hasAlpha: true,
                                 isPlanar: false,
                                 colorSpaceName: .calibratedRGB,
                                 bytesPerRow: 0,
                                 bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
lines[0].draw(at: NSPoint(x: pad, y: CGFloat(pixH) - lineH))
lines[1].draw(at: NSPoint(x: pad, y: 0))
NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

// Halve the point size so the 2x bitmap renders crisp at Retina density.
rep.size = NSSize(width: CGFloat(pixW) / scale, height: CGFloat(pixH) / scale)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
print(png.base64EncodedString())
SWIFT_EOF

  if cmp -s "$tmp" "$RENDER_SRC" 2>/dev/null; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$RENDER_SRC" || { rm -f "$tmp"; return 1; }
  fi

  if [[ ! -x "$RENDER_BIN" || "$RENDER_SRC" -nt "$RENDER_BIN" ]]; then
    swiftc -O -o "$RENDER_BIN" "$RENDER_SRC" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# ---- Load cache ------------------------------------------------------------
state='missing'
session_text='' weekly_text='' session_color='' weekly_color=''
session_resets='' weekly_resets='' updated_at=0

if [[ -f "$CACHE_FILE" ]] && command -v jq >/dev/null 2>&1; then
  parsed="$(jq -r '[.state//"ok", .session_text//"", .weekly_text//"", .session_color//"", .weekly_color//"", .session_resets_at//"", .weekly_resets_at//"", .updated_at//0] | @tsv' "$CACHE_FILE" 2>/dev/null || true)"
  if [[ -n "$parsed" ]]; then
    IFS=$'\t' read -r state session_text weekly_text session_color weekly_color session_resets weekly_resets updated_at <<<"$parsed"
  fi
fi

now="$(now_epoch)"

# ---- Trigger a background refresh when stale (same backoff as tmux) --------
[[ "$updated_at" =~ ^[0-9]+$ ]] || updated_at=0
age=$(( now - updated_at ))
(( age < 0 )) && age=$STALE_AFTER_SECONDS
if [[ -x "$SRC" ]] && { [[ ! -f "$CACHE_FILE" ]] || (( age >= STALE_AFTER_SECONDS )); }; then
  fc=0; na=0
  if [[ -f "$BACKOFF_FILE" ]]; then
    read -r fc na <"$BACKOFF_FILE" 2>/dev/null || true
  fi
  [[ "$na" =~ ^[0-9]+$ ]] || na=0
  if (( now >= na )); then
    nohup env CODEXBAR_USAGE_PROVIDER=claude "$SRC" --refresh >/dev/null 2>&1 &
  fi
fi

# Split "27% (-65%)" into the main text and the bare pace delta ("-65%").
split_pace() {
  local v="${1:-}"
  if [[ "$v" == *" ("* ]]; then
    SPLIT_MAIN="${v%% (*}"
    SPLIT_PACE="${v#* (}"
    SPLIT_PACE="${SPLIT_PACE%)}"
  else
    SPLIT_MAIN="$v"
    SPLIT_PACE=''
  fi
}

# ---- Compose the two menu bar lines ----------------------------------------
# Main text stays white (black in light mode); only the pace suffix carries
# the pacing color.
auth_required=0
case "$state" in
  auth_required)
    auth_required=1
    l1='S: login'; p1=''; l2='W: login'; p2=''
    m1="$AUTH"; m2="$AUTH"; c1="$AUTH"; c2="$AUTH"
    ;;
  ok)
    # Right-pad the percent to 4 chars ("  6%", " 27%", "100%") so the two
    # lines' percents align under the monospaced renderer font.
    split_pace "$(strip_legacy_prefix "$session_text")"
    l1="S: $(printf '%4s' "${SPLIT_MAIN:---%}")"; p1="$SPLIT_PACE"
    split_pace "$(strip_legacy_prefix "$weekly_text")"
    l2="W: $(printf '%4s' "${SPLIT_MAIN:---%}")"; p2="$SPLIT_PACE"
    m1="$TEXTC"; m2="$TEXTC"
    c1="$(color_to_hex "$session_color")"
    c2="$(color_to_hex "$weekly_color")"
    ;;
  *)
    l1='S: --%'; p1=''; l2='W: --%'; p2=''
    m1="$TEXTC"; m2="$TEXTC"; c1="$GRAY"; c2="$GRAY"
    ;;
esac

RAW_FILE="$CACHE_DIR/usage-raw.json"
MONO_FONT='font=Menlo size=12'

iso_to_epoch() {
  local iso="${1:-}"
  [[ -n "$iso" ]] || return 1
  if [[ "$iso" =~ ^([0-9-]+T[0-9:]+)\.[0-9]+(.*)$ ]]; then
    iso="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  fi
  iso="${iso/+00:00/Z}"
  local epoch
  epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$epoch"
}

# "8:10pm (4h32m)" within 24h; "Mon 9pm (6d6h)" beyond.
format_reset_label() {
  local epoch="$1" ref="$2"
  [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%s' '--'; return 0; }
  local delta=$(( epoch - ref ))
  (( delta > 0 )) || { printf '%s' '--'; return 0; }
  local daytime
  if (( delta < 86400 )); then
    daytime="$(date -r "$epoch" "+%-l:%M%p" 2>/dev/null || true)"
  else
    daytime="$(date -r "$epoch" "+%a %-l:%M%p" 2>/dev/null || true)"
  fi
  daytime="$(printf '%s' "$daytime" | sed 's/:00//;s/AM/am/;s/PM/pm/')"
  printf '%s (%s)' "${daytime:---}" "$(format_time_until "$epoch" "$ref")"
}

usage_bar() {
  local pct="$1" filled i bar=''
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  filled=$(( (pct + 5) / 10 ))
  (( filled > 10 )) && filled=10
  for (( i = 0; i < 10; i++ )); do
    if (( i < filled )); then bar+='█'; else bar+='░'; fi
  done
  printf '%s' "$bar"
}

# Signed pacing delta in percentage points (actual used - expected used at
# this point in the window). Mirrors the tmux script's pace_delta. Empty
# output when not computable (no reset, window not started, etc.).
calc_pace_delta() {
  local used="$1" window_minutes="$2" resets_at="$3" ref="$4"
  [[ "$used" =~ ^[0-9]+$ && "$window_minutes" =~ ^[0-9]+$ ]] || return 0
  [[ "$resets_at" =~ ^[0-9]+$ && "$ref" =~ ^[0-9]+$ ]] || return 0

  local duration time_until elapsed
  duration=$(( window_minutes * 60 ))
  (( duration > 0 )) || return 0
  time_until=$(( resets_at - ref ))
  (( time_until > 0 && time_until <= duration )) || return 0
  elapsed=$(( duration - time_until ))
  (( elapsed == 0 && used > 0 )) && return 0

  awk -v a="$used" -v e="$elapsed" -v d="$duration" 'BEGIN {
    expected = (e / d) * 100
    delta = a - expected
    if (delta < 0) { sign = "-"; delta = -delta } else { sign = "+" }
    printf "%s%d", sign, int(delta + 0.5)
  }'
}

# Linear projection of when this window's limit runs out, as an epoch.
# Empty when not computable (nothing used yet, or too early in the window
# for the rate to mean anything).
calc_runout_epoch() {
  local used="$1" window_minutes="$2" resets_at="$3" ref="$4"
  [[ "$used" =~ ^[0-9]+$ && "$window_minutes" =~ ^[0-9]+$ ]] || return 0
  [[ "$resets_at" =~ ^[0-9]+$ && "$ref" =~ ^[0-9]+$ ]] || return 0
  (( used > 0 )) || return 0

  local duration time_until elapsed min_elapsed
  duration=$(( window_minutes * 60 ))
  (( duration > 0 )) || return 0
  time_until=$(( resets_at - ref ))
  (( time_until > 0 && time_until <= duration )) || return 0
  elapsed=$(( duration - time_until ))
  min_elapsed=$(( duration / 100 ))
  (( min_elapsed < 60 )) && min_elapsed=60
  (( elapsed >= min_elapsed )) || return 0

  if (( used >= 100 )); then
    printf '%s' "$ref"
    return 0
  fi

  local eta
  eta="$(awk -v u="$used" -v e="$elapsed" 'BEGIN {
    rate = u / e
    if (rate <= 0) exit
    printf "%d", int((100 - u) / rate + 0.5)
  }')"
  [[ "$eta" =~ ^[0-9]+$ ]] || return 0
  printf '%s' $(( ref + eta ))
}

limit_row_color() {
  local pct="$1" severity="$2" pace="$3"
  case "$severity" in
    warning)               printf '%s' "$YELLOW"; return 0 ;;
    exceeded|blocked|high) printf '%s' "$RED"; return 0 ;;
  esac
  # Prefer pacing color (like tmux); fall back to absolute usage.
  if [[ "$pace" =~ ^[+-][0-9]+$ ]]; then
    local delta=${pace#+}
    if (( delta <= 5 )); then
      printf '%s' "$GREEN"
    elif (( delta <= 15 )); then
      printf '%s' "$YELLOW"
    else
      printf '%s' "$RED"
    fi
    return 0
  fi
  if (( pct <= 49 )); then
    printf '%s' "$GREEN"
  elif (( pct <= 79 )); then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$RED"
  fi
}

window_minutes_for_kind() {
  case "$1" in
    session)                     printf '%s' 300 ;;
    weekly_all|weekly_scoped)    printf '%s' 10080 ;;
    *)                           printf '%s' '' ;;
  esac
}

# One aligned row per entry in the endpoint's limits[] array:
#   Fable    █░░░░░░░░░  14% (+2%) · lasts to reset · resets Mon 9pm (6d5h)
#   Session  ███░░░░░░░  34% (+9%) · out in 2h10m (~6:30pm) · resets 8:09pm (4h28m)
LIMIT_ROWS_EMITTED=0
emit_limit_rows_from_raw() {
  LIMIT_ROWS_EMITTED=0
  [[ -f "$RAW_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local rows
  rows="$(jq -r '.limits[]? | [
      .kind // "",
      ((.percent // 0) | floor),
      .severity // "normal",
      .resets_at // "",
      (.scope.model.display_name // "")
    ] | @tsv' "$RAW_FILE" 2>/dev/null || true)"
  [[ -n "$rows" ]] || return 0

  local kind pct severity resets_iso scope_name label epoch reset_label color line
  local window_minutes pace pace_part runout runout_part runout_clock
  while IFS=$'\t' read -r kind pct severity resets_iso scope_name; do
    [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
    case "$kind" in
      session)       label='Session' ;;
      weekly_all)    label='Weekly' ;;
      weekly_scoped) label="${scope_name:-Scoped}" ;;
      *)             label="${scope_name:-$kind}" ;;
    esac

    epoch=''
    reset_label='--'
    if epoch="$(iso_to_epoch "$resets_iso")"; then
      reset_label="$(format_reset_label "$epoch" "$now")"
    fi

    window_minutes="$(window_minutes_for_kind "$kind")"
    pace="$(calc_pace_delta "$pct" "$window_minutes" "${epoch:-}" "$now")"
    pace_part=''
    [[ -n "$pace" ]] && pace_part=" (${pace}%)"

    runout_part=''
    if runout="$(calc_runout_epoch "$pct" "$window_minutes" "${epoch:-}" "$now")" && [[ -n "$runout" ]]; then
      if [[ -n "$epoch" ]] && (( runout >= epoch )); then
        runout_part=' · lasts to reset'
      else
        # Round the projected clock time to the hour — a linear projection
        # doesn't deserve minute precision (matches the tmux reset view).
        local runout_hr=$(( ((runout + 1800) / 3600) * 3600 ))
        runout_clock="$(date -r "$runout_hr" "+%-l%p" 2>/dev/null | sed 's/AM/am/;s/PM/pm/')"
        if (( runout - now >= 86400 )); then
          runout_clock="$(date -r "$runout_hr" "+%a %-l%p" 2>/dev/null | sed 's/AM/am/;s/PM/pm/')"
        fi
        runout_part=" · out in $(format_time_until "$runout" "$now")${runout_clock:+ (~${runout_clock})}"
      fi
    fi

    color="$(limit_row_color "$pct" "$severity" "$pace")"
    line="$(printf '%-8.8s %s %3d%%%s%s · resets %s' \
      "$label" "$(usage_bar "$pct")" "$pct" "$pace_part" "$runout_part" "$reset_label")"
    printf '%s | %s color=%s trim=false\n' "$line" "$MONO_FONT" "$color"
    LIMIT_ROWS_EMITTED=$(( LIMIT_ROWS_EMITTED + 1 ))
  done <<<"$rows"
}

emit_extra_usage_from_raw() {
  [[ -f "$RAW_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local enabled util
  enabled="$(jq -r '.extra_usage.is_enabled // false' "$RAW_FILE" 2>/dev/null || true)"
  if [[ "$enabled" == "true" ]]; then
    util="$(jq -r '(.extra_usage.utilization // 0) | floor' "$RAW_FILE" 2>/dev/null || true)"
    [[ "$util" =~ ^[0-9]+$ ]] || util=0
    printf 'Extra usage: on · %d%% of monthly credits used | color=%s\n' "$util" "$GRAY"
  else
    printf 'Extra usage: off | color=%s\n' "$GRAY"
  fi
}

# ---- Menu bar title: stacked image, cycling-text fallback ------------------
img=''
if ensure_renderer; then
  img="$("$RENDER_BIN" "$l1" "$m1" "$p1" "$c1" "$l2" "$m2" "$p2" "$c2" 2>/dev/null || true)"
fi

if [[ -n "$img" ]]; then
  printf '| image=%s\n' "$img"
else
  printf '%s%s | color=%s\n' "$l1" "${p1:+ ($p1)}" "$m1"
  printf '%s%s | color=%s\n' "$l2" "${p2:+ ($p2)}" "$m2"
fi

# ---- Dropdown ---------------------------------------------------------------
echo '---'
if (( auth_required )); then
  printf 'Not logged in to Claude | color=%s\n' "$AUTH"
  printf 'Log in from tmux: prefix + u | color=%s\n' "$AUTH"
else
  emit_limit_rows_from_raw
  if (( LIMIT_ROWS_EMITTED == 0 )); then
    # Raw endpoint dump not available yet — fall back to the cache summary.
    session_until="$(format_time_until "$session_resets" "$now")"
    weekly_until="$(format_time_until "$weekly_resets" "$now")"
    weekly_day="$(format_reset_daytime "$weekly_resets" || true)"
    printf 'Session: %s — resets in %s | color=%s\n' "$(strip_legacy_prefix "$session_text")" "$session_until" "$c1"
    if [[ -n "${weekly_day:-}" ]]; then
      printf 'Weekly: %s — resets %s (in %s) | color=%s\n' "$(strip_legacy_prefix "$weekly_text")" "$weekly_day" "$weekly_until" "$c2"
    else
      printf 'Weekly: %s — resets in %s | color=%s\n' "$(strip_legacy_prefix "$weekly_text")" "$weekly_until" "$c2"
    fi
  fi

  echo '---'
  emit_extra_usage_from_raw
  if (( updated_at > 0 )); then
    if (( age < 60 )); then
      printf 'Updated just now | color=%s\n' "$GRAY"
    else
      printf 'Updated %s ago | color=%s\n' "$(format_time_until $(( now + age )) "$now")" "$GRAY"
    fi
  else
    printf 'No usage data yet | color=%s\n' "$GRAY"
  fi
fi
echo '---'
printf 'Refresh now | bash="%s" param1=refresh-now terminal=false refresh=true\n' "$PLUGIN_PATH"
printf 'Open claude.ai usage settings | href=https://claude.ai/settings/usage\n'
