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
let font = NSFont.monospacedDigitSystemFont(ofSize: 8.5 * scale, weight: .semibold)

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
    split_pace "$(strip_legacy_prefix "$session_text")"
    l1="S: ${SPLIT_MAIN:---%}"; p1="$SPLIT_PACE"
    split_pace "$(strip_legacy_prefix "$weekly_text")"
    l2="W: ${SPLIT_MAIN:---%}"; p2="$SPLIT_PACE"
    m1="$TEXTC"; m2="$TEXTC"
    c1="$(color_to_hex "$session_color")"
    c2="$(color_to_hex "$weekly_color")"
    ;;
  *)
    l1='S: --%'; p1=''; l2='W: --%'; p2=''
    m1="$TEXTC"; m2="$TEXTC"; c1="$GRAY"; c2="$GRAY"
    ;;
esac

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
  session_until="$(format_time_until "$session_resets" "$now")"
  weekly_until="$(format_time_until "$weekly_resets" "$now")"
  weekly_day="$(format_reset_daytime "$weekly_resets" || true)"

  printf 'Session: %s — resets in %s | color=%s\n' "$(strip_legacy_prefix "$session_text")" "$session_until" "$c1"
  if [[ -n "${weekly_day:-}" ]]; then
    printf 'Weekly: %s — resets %s (in %s) | color=%s\n' "$(strip_legacy_prefix "$weekly_text")" "$weekly_day" "$weekly_until" "$c2"
  else
    printf 'Weekly: %s — resets in %s | color=%s\n' "$(strip_legacy_prefix "$weekly_text")" "$weekly_until" "$c2"
  fi

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
