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
PANEL_SRC="$CACHE_DIR/swiftbar-claude-panel.swift"
PANEL_BIN="$CACHE_DIR/swiftbar-claude-panel"
HISTORY_FILE="$CACHE_DIR/usage-history.jsonl"

# Width of the drawn dropdown card, in points. SwiftBar's menu adds ~42pt of
# its own inset around it.
PANEL_WIDTH=340

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
    green)      printf '%s' "$GREEN" ;;
    yellow)     printf '%s' "$YELLOW" ;;
    red)        printf '%s' "$RED" ;;
    brightblack) printf '%s' "$GRAY" ;;
    \#*)        printf '%s' "$1" ;;
    *)          printf '%s' "$GRAY" ;;
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
  # CODEXBAR_USAGE_PROVIDER is not optional here. The script resolves the
  # provider from the tmux option first but falls back to *codex*, and both
  # providers share one usage.json — so with no tmux server running, "Refresh
  # now" used to overwrite the cache with Codex numbers, which this plugin and
  # the tmux status line then both displayed as Claude.
  CODEXBAR_USAGE_PROVIDER=claude CODEXBAR_USAGE_FORCE_REFRESH=1 "$SRC" --refresh >/dev/null 2>&1 || true
  CODEXBAR_USAGE_PROVIDER=claude "$SRC" --publish >/dev/null 2>&1 || true
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

# The dropdown card. Reads a JSON model on stdin (built by build_panel_json
# below) and prints one base64 PNG; SwiftBar shows it as a single menu item.
# Every number, label and color is decided on the bash side — this is only the
# view layer.
ensure_panel_renderer() {
  command -v swiftc >/dev/null 2>&1 || return 1
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1

  local tmp
  tmp="$(mktemp "${PANEL_SRC}.tmp.XXXXXX")" || return 1
  cat >"$tmp" <<'PANEL_EOF'
import AppKit

struct Row: Decodable {
    let label: String
    let pct: Double
    let expected: Double // -1 = don't draw the pace marker
    let accent: String
    let note: String
    let noteAccent: String
    let sub: String
}

struct Spark: Decodable {
    let title: String
    let points: [[Double]] // [x 0...1, y percent]
    let accent: String
    let peak: String
}

struct Model: Decodable {
    let appearance: String
    let width: Double
    let title: String
    let updated: String
    let message: String
    let primary: [Row]
    let compact: [Row]
    let spark: Spark?
    let footer: String
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let model = try? JSONDecoder().decode(Model.self, from: input) else {
    FileHandle.standardError.write(Data("swiftbar-claude-panel: bad model\n".utf8))
    exit(2)
}

func hexColor(_ hex: String, fallback: NSColor) -> NSColor {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return fallback }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255,
                   alpha: 1)
}

// ---- Metrics (points) -------------------------------------------------------
let W = CGFloat(model.width)
let scale: CGFloat = 2
let padX: CGFloat = 15
let padTop: CGFloat = 11
let padBottom: CGFloat = 12
let headerH: CGFloat = 14
let ruleTop: CGFloat = 8
let ruleBottom: CGFloat = 11
let msgH: CGFloat = 16
let pLabelH: CGFloat = 18
let barGap: CGFloat = 5
let barH: CGFloat = 7
let subGap: CGFloat = 7
let subH: CGFloat = 13
let blockGap: CGFloat = 14
let compactH: CGFloat = 16
let compactGap: CGFloat = 6
let sectionGap: CGFloat = 12
let sectionRule: CGFloat = 11 // hairline plus breathing room above a section
let sparkTitleH: CGFloat = 12
let sparkGap: CGFloat = 6
let sparkH: CGFloat = 40
let footerTop: CGFloat = 12
let footerH: CGFloat = 13

var H = padTop + headerH + ruleTop + 1 + ruleBottom
if !model.message.isEmpty { H += msgH + 4 }
if !model.primary.isEmpty {
    H += CGFloat(model.primary.count) * (pLabelH + barGap + barH + subGap + subH)
    H += CGFloat(model.primary.count - 1) * blockGap
}
if !model.compact.isEmpty {
    H += sectionGap + 1 + sectionRule + CGFloat(model.compact.count) * compactH
    H += CGFloat(model.compact.count - 1) * compactGap
}
if let s = model.spark, s.points.count >= 2 {
    H += sectionGap + 1 + sectionRule + sparkTitleH + sparkGap + sparkH
}
if !model.footer.isEmpty { H += footerTop + footerH }
H += padBottom

// ---- Canvas -----------------------------------------------------------------
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int((W * scale).rounded()),
                                 pixelsHigh: Int((H * scale).rounded()),
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .calibratedRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
// Draw in points; the 2x bitmap is re-tagged at 1x point size on the way out,
// so it lands crisp on Retina.
let unit = NSAffineTransform()
unit.scale(by: scale)
unit.concat()

// `y` runs downward from the top of the card; flip it into AppKit's bottom-up
// coordinate space at draw time.
func flip(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
    NSRect(x: x, y: H - y - h, width: w, height: h)
}

func drawText(_ s: String,
              font: NSFont,
              color: NSColor,
              x: CGFloat,
              y: CGFloat,
              width: CGFloat,
              height: CGFloat,
              align: NSTextAlignment = .left,
              kern: CGFloat = 0) {
    guard !s.isEmpty else { return }
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineBreakMode = .byTruncatingTail
    let line = NSAttributedString(string: s, attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern,
    ])
    // Centre the glyphs vertically in their slot.
    line.draw(in: flip(x, y + (height - line.size().height) / 2, width, height))
}

func roundedBar(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// Resolve the system label colors against the menu's appearance rather than
// this process's default, so the card reads correctly on the menu's material.
let appearance = NSAppearance(named: model.appearance == "dark" ? .darkAqua : .aqua)
    ?? NSAppearance(named: .aqua)!

appearance.performAsCurrentDrawingAppearance {
    let label = NSColor.labelColor
    let secondary = NSColor.secondaryLabelColor
    let tertiary = NSColor.tertiaryLabelColor
    let track = label.withAlphaComponent(0.13)
    let hairline = label.withAlphaComponent(0.11)

    let contentW = W - padX * 2
    var y = padTop

    // ---- Header -------------------------------------------------------------
    drawText(model.title,
             font: .systemFont(ofSize: 10, weight: .semibold),
             color: secondary, x: padX, y: y, width: contentW, height: headerH,
             kern: 0.8)
    drawText(model.updated,
             font: .systemFont(ofSize: 10, weight: .regular),
             color: tertiary, x: padX, y: y, width: contentW, height: headerH,
             align: .right)
    y += headerH + ruleTop

    hairline.setFill()
    NSBezierPath(rect: flip(padX, y, contentW, 1)).fill()
    y += 1 + ruleBottom

    func sectionDivider(_ y: inout CGFloat) {
        y += sectionGap
        hairline.setFill()
        NSBezierPath(rect: flip(padX, y, contentW, 1)).fill()
        y += 1 + sectionRule
    }

    // ---- Status message (login needed, no data yet) -------------------------
    if !model.message.isEmpty {
        drawText(model.message,
                 font: .systemFont(ofSize: 12, weight: .medium),
                 color: label, x: padX, y: y, width: contentW, height: msgH)
        y += msgH + 4
    }

    // ---- Session / weekly ---------------------------------------------------
    for (index, row) in model.primary.enumerated() {
        let accent = hexColor(row.accent, fallback: label)
        let frac = max(0, min(1, row.pct / 100))

        drawText(row.label,
                 font: .systemFont(ofSize: 12.5, weight: .medium),
                 color: label, x: padX, y: y, width: contentW, height: pLabelH)
        drawText(String(format: "%.0f%%", row.pct),
                 font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
                 color: accent, x: padX, y: y, width: contentW, height: pLabelH,
                 align: .right)
        y += pLabelH + barGap

        let barRect = flip(padX, y, contentW, barH)
        track.setFill()
        roundedBar(barRect, radius: barH / 2).fill()

        if frac > 0 {
            // Never narrower than the cap diameter, or the pill loses its shape.
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY,
                                  width: max(barH, contentW * frac), height: barH)
            NSGraphicsContext.saveGraphicsState()
            roundedBar(fillRect, radius: barH / 2).addClip()
            NSGradient(starting: accent.blended(withFraction: 0.22, of: .white) ?? accent,
                       ending: accent)?.draw(in: fillRect, angle: -90)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Pace marker: where usage *would* be if it were spread evenly across
        // the window. Fill short of the tick = under pace.
        if row.expected >= 0 {
            let markX = barRect.minX + contentW * max(0, min(1, row.expected / 100))
            if markX > barRect.minX + 1.5, markX < barRect.maxX - 1.5 {
                label.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: NSRect(x: markX - 1, y: barRect.minY - 2,
                                                 width: 2, height: barH + 4),
                             xRadius: 1, yRadius: 1).fill()
            }
        }
        y += barH + subGap

        // Split the sub-line so a long badge truncates instead of colliding
        // with the reset text.
        let noteW = (contentW * 0.54).rounded()
        drawText(row.note,
                 font: .systemFont(ofSize: 10.5, weight: .medium),
                 color: hexColor(row.noteAccent, fallback: tertiary),
                 x: padX, y: y, width: noteW, height: subH)
        drawText(row.sub,
                 font: .systemFont(ofSize: 10.5, weight: .regular),
                 color: tertiary, x: padX + noteW, y: y,
                 width: contentW - noteW, height: subH,
                 align: .right)
        y += subH
        if index < model.primary.count - 1 { y += blockGap }
    }

    // ---- Scoped limits (per-model weekly caps) ------------------------------
    if !model.compact.isEmpty {
        sectionDivider(&y)
        let miniW: CGFloat = 74
        let miniH: CGFloat = 5
        for (index, row) in model.compact.enumerated() {
            let accent = hexColor(row.accent, fallback: label)
            drawText(row.label,
                     font: .systemFont(ofSize: 11.5, weight: .regular),
                     color: secondary, x: padX, y: y,
                     width: contentW - miniW - 44, height: compactH)

            let barRect = flip(padX + contentW - miniW, y + (compactH - miniH) / 2, miniW, miniH)
            track.setFill()
            roundedBar(barRect, radius: miniH / 2).fill()
            let frac = max(0, min(1, row.pct / 100))
            if frac > 0 {
                accent.setFill()
                roundedBar(NSRect(x: barRect.minX, y: barRect.minY,
                                  width: max(miniH, miniW * frac), height: miniH),
                           radius: miniH / 2).fill()
            }

            drawText(String(format: "%.0f%%", row.pct),
                     font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                     color: secondary,
                     x: padX, y: y, width: contentW - miniW - 8, height: compactH,
                     align: .right)
            y += compactH
            if index < model.compact.count - 1 { y += compactGap }
        }
    }

    // ---- Sparkline over the sampled history ---------------------------------
    if let spark = model.spark, spark.points.count >= 2 {
        sectionDivider(&y)
        let accent = hexColor(spark.accent, fallback: label)
        drawText(spark.title,
                 font: .systemFont(ofSize: 10, weight: .medium),
                 color: tertiary, x: padX, y: y, width: contentW, height: sparkTitleH)
        drawText(spark.peak,
                 font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                 color: tertiary, x: padX, y: y, width: contentW, height: sparkTitleH,
                 align: .right)
        y += sparkTitleH + sparkGap

        let chart = flip(padX, y, contentW, sparkH)
        let peakY = spark.points.map { $0.count > 1 ? $0[1] : 0 }.max() ?? 0
        let yMax = max(peakY * 1.22, 8)

        // Keep the head dot inside the frame at both ends.
        let plotInset: CGFloat = 3
        func point(_ p: [Double]) -> NSPoint {
            NSPoint(x: chart.minX + plotInset + (chart.width - plotInset * 2) * CGFloat(max(0, min(1, p[0]))),
                    y: chart.minY + chart.height * CGFloat(max(0, min(1, p[1] / yMax))))
        }

        let pts = spark.points.filter { $0.count > 1 }.map(point)
        if pts.count >= 2 {
        let line = NSBezierPath()
        line.lineWidth = 1.6
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        line.move(to: pts[0])
        for p in pts.dropFirst() { line.line(to: p) }

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: pts[pts.count - 1].x, y: chart.minY))
        area.line(to: NSPoint(x: pts[0].x, y: chart.minY))
        area.close()

        NSGraphicsContext.saveGraphicsState()
        area.addClip()
        NSGradient(starting: accent.withAlphaComponent(0.34),
                   ending: accent.withAlphaComponent(0.02))?.draw(in: chart, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        hairline.setFill()
        NSBezierPath(rect: NSRect(x: chart.minX, y: chart.minY,
                                  width: chart.width, height: 1)).fill()

        accent.setStroke()
        line.stroke()

        // Head of the trace is right now.
        if let last = pts.last {
            accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2.4, y: last.y - 2.4,
                                        width: 4.8, height: 4.8)).fill()
        }
        }
        y += sparkH
    }

    // ---- Footer -------------------------------------------------------------
    if !model.footer.isEmpty {
        y += footerTop
        drawText(model.footer,
                 font: .systemFont(ofSize: 10.5, weight: .regular),
                 color: tertiary, x: padX, y: y, width: contentW, height: footerH)
    }
}

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

rep.size = NSSize(width: W, height: H)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
// Line 1 is the point size, line 2 the image. SwiftBar 2.1.1 shrinks any
// dropdown image over 16pt unless the line carries both width= and height=,
// so the caller has to be told what the layout came out to.
print("\(Int(W.rounded())) \(Int(H.rounded()))")
print(png.base64EncodedString())
PANEL_EOF

  if cmp -s "$tmp" "$PANEL_SRC" 2>/dev/null; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$PANEL_SRC" || { rm -f "$tmp"; return 1; }
  fi

  if [[ ! -x "$PANEL_BIN" || "$PANEL_SRC" -nt "$PANEL_BIN" ]]; then
    swiftc -O -o "$PANEL_BIN" "$PANEL_SRC" >/dev/null 2>&1 || return 1
  fi
  return 0
}

# ---- Load cache ------------------------------------------------------------
state='missing'
session_text='' weekly_text='' session_color='' weekly_color=''
session_resets='' weekly_resets='' updated_at=0

# Tab is IFS *whitespace*: `IFS=$'\t' read` collapses runs of tabs and drops
# empty fields, shifting every later field left. session_resets_at is empty
# whenever no 5-hour window is open, which slid weekly_resets_at into
# session_resets and left updated_at blank (hence "No usage data yet" plus a
# refresh attempt on every tick). Split on US (\037) instead so empty fields
# survive; @tsv escapes any literal tab in a value, so the swap is lossless.
if [[ -f "$CACHE_FILE" ]] && command -v jq >/dev/null 2>&1; then
  parsed="$(jq -r '[.state//"ok", .session_text//"", .weekly_text//"", .session_color//"", .weekly_color//"", .session_resets_at//"", .weekly_resets_at//"", .updated_at//0] | @tsv' "$CACHE_FILE" 2>/dev/null | tr '\t' '\037' || true)"
  if [[ -n "$parsed" ]]; then
    IFS=$'\037' read -r state session_text weekly_text session_color weekly_color session_resets weekly_resets updated_at <<<"$parsed"
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
    # "idle" = no 5-hour window open (see codexbar-usage-status.sh). Dim the
    # whole line so it doesn't read as a live measurement.
    [[ "$l1" == 'S: idle' ]] && m1="$GRAY"
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
    ] | @tsv' "$RAW_FILE" 2>/dev/null | tr '\t' '\037' || true)"
  [[ -n "$rows" ]] || return 0

  local kind pct severity resets_iso scope_name label epoch reset_label color line
  local window_minutes pace pace_part runout runout_part runout_clock
  while IFS=$'\037' read -r kind pct severity resets_iso scope_name; do
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

    if [[ -z "$epoch" ]]; then
      # No resets_at means the window isn't open (the endpoint nulls it between
      # 5-hour sessions). Pacing, run-out and reset time are all undefined —
      # label that plainly instead of showing a green "0% · resets --".
      line="$(printf '%-8.8s %s %3d%% · no active window' "$label" "$(usage_bar "$pct")" "$pct")"
      printf '%s | %s color=%s trim=false\n' "$line" "$MONO_FONT" "$GRAY"
    else
      color="$(limit_row_color "$pct" "$severity" "$pace")"
      line="$(printf '%-8.8s %s %3d%%%s%s · resets %s' \
        "$label" "$(usage_bar "$pct")" "$pct" "$pace_part" "$runout_part" "$reset_label")"
      printf '%s | %s color=%s trim=false\n' "$line" "$MONO_FONT" "$color"
    fi
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

# ---- Drawn dropdown card: model ---------------------------------------------
# Everything below decides *what* the card says; swiftbar-claude-panel only
# draws it. Anything that can't be computed degrades to an empty string, which
# the renderer skips.

extra_usage_text() {
  [[ -f "$RAW_FILE" ]] || { printf '%s' ''; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s' ''; return 0; }

  local enabled util
  enabled="$(jq -r '.extra_usage.is_enabled // false' "$RAW_FILE" 2>/dev/null || true)"
  if [[ "$enabled" == "true" ]]; then
    util="$(jq -r '(.extra_usage.utilization // 0) | floor' "$RAW_FILE" 2>/dev/null || true)"
    [[ "$util" =~ ^[0-9]+$ ]] || util=0
    printf 'Extra usage on · %d%% of monthly credits used' "$util"
  else
    printf '%s' 'Extra usage off'
  fi
}

# Where usage *would* be, as a percent, if the window burned evenly. -1 when the
# window isn't open, so the renderer knows to skip the pace tick.
calc_expected_pct() {
  local window_minutes="$1" resets_at="$2" ref="$3"
  [[ "$window_minutes" =~ ^[0-9]+$ && "$resets_at" =~ ^[0-9]+$ ]] || { printf '%s' '-1'; return 0; }
  local duration=$(( window_minutes * 60 ))
  (( duration > 0 )) || { printf '%s' '-1'; return 0; }
  local time_until=$(( resets_at - ref ))
  (( time_until > 0 && time_until <= duration )) || { printf '%s' '-1'; return 0; }
  awk -v e="$(( duration - time_until ))" -v d="$duration" 'BEGIN { printf "%.2f", (e / d) * 100 }'
}

format_age() {
  local seconds="$1"
  (( seconds < 45 )) && { printf '%s' 'updated just now'; return 0; }
  printf 'updated %s ago' "$(format_time_until $(( now + seconds )) "$now")"
}

# "resets 6:49pm · in 3h1m", or the honest version when no window is open.
reset_sub() {
  local epoch="$1" daytime
  [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%s' 'no active window'; return 0; }
  (( epoch > now )) || { printf '%s' 'resetting now'; return 0; }
  if (( epoch - now < 86400 )); then
    daytime="$(date -r "$epoch" "+%-l:%M%p" 2>/dev/null || true)"
  else
    daytime="$(date -r "$epoch" "+%a %-l:%M%p" 2>/dev/null || true)"
  fi
  daytime="$(printf '%s' "$daytime" | sed 's/:00//;s/AM/am/;s/PM/pm/')"
  printf 'resets %s · in %s' "${daytime:---}" "$(format_time_until "$epoch" "$now")"
}

# The badge under a bar, colored by how far off the even-burn pace we are so
# that it agrees with the bar. When we're burning fast enough that the window
# won't survive, the projected run-out replaces the pace delta — it's the more
# actionable phrasing of the same fact. While pacing is fine the projection
# stays hidden: a linear extrapolation off a couple of samples doesn't deserve
# a warning colour.
row_note() {
  local pace="$1" runout="$2" epoch="$3" elapsed_pct="$4" pct="${5:-}"
  NOTE=''; NOTE_COLOR="$GRAY"

  # An exhausted window has nothing left to project. calc_runout_epoch returns
  # `now` at 100%, and format_time_until of a zero delta is the not-computable
  # sentinel, so this used to read "out in --" for the rest of the window — at
  # exactly the moment the badge matters most.
  if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= 100 )); then
    NOTE='limit reached'; NOTE_COLOR="$RED"
    return 0
  fi

  local magnitude='' over=0
  if [[ "$pace" =~ ^[+-][0-9]+$ ]]; then
    magnitude="${pace#[+-]}"
    if (( magnitude <= 2 )) || [[ "$pace" == -* ]]; then
      NOTE_COLOR="$GREEN"
    elif (( magnitude <= 15 )); then
      NOTE_COLOR="$YELLOW"; over=1
    else
      NOTE_COLOR="$RED"; over=1
    fi
  fi

  # A quarter of the window has to have gone by before a linear extrapolation
  # is worth putting on screen — 19h into a 7-day window it is noise.
  local grounded=0
  [[ "$elapsed_pct" =~ ^[0-9]+ ]] && (( ${elapsed_pct%%.*} >= 25 )) && grounded=1

  if (( over && grounded )) && [[ "$runout" =~ ^[0-9]+$ && "$epoch" =~ ^[0-9]+$ ]] && (( runout < epoch )); then
    local rounded clock
    rounded=$(( ((runout + 1800) / 3600) * 3600 ))
    if (( runout - now >= 86400 )); then
      clock="$(date -r "$rounded" "+%a %-l%p" 2>/dev/null | sed 's/AM/am/;s/PM/pm/')"
    else
      clock="$(date -r "$rounded" "+%-l%p" 2>/dev/null | sed 's/AM/am/;s/PM/pm/')"
    fi
    NOTE="out in $(format_time_until "$runout" "$now")${clock:+ · ~$clock}"
    return 0
  fi

  if [[ -n "$magnitude" ]]; then
    if (( magnitude <= 2 )); then
      NOTE='on pace'
    elif [[ "$pace" == -* ]]; then
      NOTE="${magnitude}% under pace"
    else
      NOTE="+${magnitude}% over pace"
    fi
    return 0
  fi

  # No pace to report. When the window isn't open at all, reset_sub already
  # says so on the right — don't repeat it on the left.
  return 0
}

# The trace under the card: every sample this script has recorded for the
# window that's currently open, x-normalised across the sampled span (not the
# whole window) so short histories still fill the width.
build_spark_json() {
  local accent="$1"
  [[ -f "$HISTORY_FILE" ]] || { printf '%s' 'null'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s' 'null'; return 0; }

  local key value_key reset_key title_prefix
  if [[ "$session_resets" =~ ^[0-9]+$ ]] && (( session_resets > now )); then
    key="$session_resets"; value_key='s'; reset_key='sr'; title_prefix='Session'
  elif [[ "$weekly_resets" =~ ^[0-9]+$ ]] && (( weekly_resets > now )); then
    key="$weekly_resets"; value_key='w'; reset_key='wr'; title_prefix='Weekly'
  else
    printf '%s' 'null'; return 0
  fi

  local series
  series="$(tail -n 500 "$HISTORY_FILE" 2>/dev/null | jq -s -c \
    --argjson key "$key" --arg vk "$value_key" --arg rk "$reset_key" '
      [ .[] | select((.[$rk] // 0) == $key) | {t: .t, v: (.[$vk] // 0)} ]
      | if length < 3 then null
        else
          (.[0].t) as $t0 | (.[-1].t) as $t1
          | if ($t1 - $t0) < 300 then null
            else { span: ($t1 - $t0),
                   peak: ([.[].v] | max),
                   points: [ .[] | [ ((.t - $t0) / ($t1 - $t0)), .v ] ] }
            end
        end' 2>/dev/null || true)"
  [[ -n "$series" && "$series" != 'null' ]] || { printf '%s' 'null'; return 0; }

  local span peak
  span="$(printf '%s' "$series" | jq -r '.span' 2>/dev/null || true)"
  peak="$(printf '%s' "$series" | jq -r '.peak | floor' 2>/dev/null || true)"
  [[ "$span" =~ ^[0-9]+$ && "$peak" =~ ^[0-9]+$ ]] || { printf '%s' 'null'; return 0; }

  printf '%s' "$series" | jq -c \
    --arg title "$title_prefix · last $(format_time_until $(( now + span )) "$now")" \
    --arg accent "$accent" \
    --arg peak "peak ${peak}%" \
    '{title: $title, accent: $accent, peak: $peak, points: .points}' 2>/dev/null \
    || printf '%s' 'null'
}

join_json() { local IFS=','; printf '%s' "$*"; }

PANEL_IMAGE='' PANEL_W='' PANEL_H=''
build_panel_image() {
  PANEL_IMAGE=''; PANEL_W=''; PANEL_H=''
  command -v jq >/dev/null 2>&1 || return 1
  ensure_panel_renderer || return 1

  local appearance_key='light'
  [[ "$appearance" == 'Dark' ]] && appearance_key='dark'

  local message='' footer='' updated='no data yet'
  local primary=() compact=() spark='null' spark_accent="$GRAY"
  (( updated_at > 0 )) && updated="$(format_age "$age")"

  if (( auth_required )); then
    message='Not logged in to Claude'
    footer='Log in from tmux: prefix + u'
  else
    local rows=''
    if [[ -f "$RAW_FILE" ]]; then
      rows="$(jq -r '.limits[]? | [
          .kind // "",
          ((.percent // 0) | floor),
          .severity // "normal",
          .resets_at // "",
          (.scope.model.display_name // "")
        ] | @tsv' "$RAW_FILE" 2>/dev/null | tr '\t' '\037' || true)"
    fi
    [[ -n "$rows" ]] || return 1

    local kind pct severity resets_iso scope_name label epoch window_minutes
    local pace runout expected accent sub row
    while IFS=$'\037' read -r kind pct severity resets_iso scope_name; do
      [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
      case "$kind" in
        session)       label='Session' ;;
        weekly_all)    label='Weekly' ;;
        weekly_scoped) label="${scope_name:-Scoped}" ;;
        *)             label="${scope_name:-$kind}" ;;
      esac

      epoch=''
      epoch="$(iso_to_epoch "$resets_iso" || true)"
      window_minutes="$(window_minutes_for_kind "$kind")"
      pace="$(calc_pace_delta "$pct" "$window_minutes" "${epoch:-}" "$now")"
      runout="$(calc_runout_epoch "$pct" "$window_minutes" "${epoch:-}" "$now")"
      expected="$(calc_expected_pct "$window_minutes" "${epoch:-}" "$now")"
      accent="$(limit_row_color "$pct" "$severity" "$pace")"
      [[ -n "$epoch" ]] || accent="$GRAY"
      sub="$(reset_sub "${epoch:-}")"
      row_note "$pace" "${runout:-}" "${epoch:-}" "$expected" "$pct"

      row="$(jq -n \
        --arg label "$label" \
        --argjson pct "$pct" \
        --argjson expected "$expected" \
        --arg accent "$accent" \
        --arg note "$NOTE" \
        --arg noteAccent "$NOTE_COLOR" \
        --arg sub "$sub" \
        '{label: $label, pct: $pct, expected: $expected, accent: $accent,
          note: $note, noteAccent: $noteAccent, sub: $sub}' 2>/dev/null || true)"
      [[ -n "$row" ]] || continue

      case "$kind" in
        session)
          spark_accent="$accent"
          primary+=("$row")
          ;;
        weekly_all)
          [[ "$spark_accent" == "$GRAY" ]] && spark_accent="$accent"
          primary+=("$row")
          ;;
        *)
          # Scoped caps get a compact row: no pace tick, no reset line — the
          # weekly block above already carries the timing.
          compact+=("$row")
          ;;
      esac
    done <<<"$rows"

    (( ${#primary[@]} > 0 )) || return 1
    spark="$(build_spark_json "$spark_accent")"
    footer="$(extra_usage_text)"
  fi

  local model
  model="$(jq -n \
    --arg appearance "$appearance_key" \
    --argjson width "$PANEL_WIDTH" \
    --arg title 'CLAUDE USAGE' \
    --arg updated "$updated" \
    --arg message "$message" \
    --argjson primary "[$(join_json "${primary[@]}")]" \
    --argjson compact "[$(join_json "${compact[@]}")]" \
    --argjson spark "$spark" \
    --arg footer "$footer" \
    '{appearance: $appearance, width: $width, title: $title, updated: $updated,
      message: $message, primary: $primary, compact: $compact, spark: $spark,
      footer: $footer}' 2>/dev/null || true)"
  [[ -n "$model" ]] || return 1

  local rendered
  rendered="$(printf '%s' "$model" | "$PANEL_BIN" 2>/dev/null || true)"
  [[ -n "$rendered" ]] || return 1
  read -r PANEL_W PANEL_H <<<"$(printf '%s\n' "$rendered" | sed -n '1p')"
  PANEL_IMAGE="$(printf '%s\n' "$rendered" | sed -n '2p')"
  [[ "$PANEL_W" =~ ^[0-9]+$ && "$PANEL_H" =~ ^[0-9]+$ && -n "$PANEL_IMAGE" ]]
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
# One drawn card for the whole state, with the plain text rows kept as the
# fallback for when swiftc isn't around or the renderer fails.
echo '---'
if build_panel_image; then
  printf '| image=%s width=%s height=%s\n' "$PANEL_IMAGE" "$PANEL_W" "$PANEL_H"
elif (( auth_required )); then
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
printf 'Refresh now | sfimage=arrow.clockwise bash="%s" param1=refresh-now terminal=false refresh=true\n' "$PLUGIN_PATH"
printf 'Usage settings on claude.ai | sfimage=arrow.up.right href=https://claude.ai/settings/usage\n'
