// make_icon.swift — draws the inbox-keeper app icon natively (no external image
// generation) and emits a full .iconset. build.sh runs `iconutil` on the output.
//
// The mark echoes the in-app wordmark: a warm terracotta squircle holding a cream
// "checked tray" glyph — a tray (your inbox) with a checkmark resting in it
// ("only what needs you, and nothing lost"). Deterministic + on-brand + in-repo.
//
//   swift make_icon.swift <output-iconset-dir>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Brand palette (sRGB approximations of the panel's OKLCH terracotta + cream).
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let tileTop    = srgb(0.84, 0.47, 0.36)   // accent, lit
let tileBottom = srgb(0.66, 0.33, 0.25)   // accent-press, shaded
let cream      = srgb(0.985, 0.965, 0.930)

// Draw the icon into a bitmap of `px` × `px` pixels.
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let S = CGFloat(px)

    // Rounded "squircle" tile, inset to leave the standard transparent margin,
    // with a soft drop shadow so it reads as a real macOS app tile.
    let margin = S * 0.105
    let tile = NSRect(x: margin, y: margin * 1.18, width: S - 2 * margin, height: S - 2 * margin)
    let radius = tile.width * 0.2237   // Apple's continuous-corner ratio (circular approx)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                  blur: S * 0.035, color: srgb(0.20, 0.10, 0.06, 0.30).cgColor)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    cream.setFill(); tilePath.fill()   // fill once just to cast the shadow cleanly
    ctx.restoreGState()

    // Terracotta vertical gradient inside the tile.
    ctx.saveGState()
    tilePath.addClip()
    let grad = NSGradient(colors: [tileTop, tileBottom])!
    grad.draw(in: tile, angle: -90)
    // Subtle top highlight for depth.
    let hi = NSGradient(colors: [srgb(1, 1, 1, 0.14), srgb(1, 1, 1, 0)])!
    hi.draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
    ctx.restoreGState()

    // Glyph: a cream tray with a checkmark resting in it. (y-up coordinates.)
    let cx = tile.midX, cy = tile.midY, w = tile.width
    let stroke = w * 0.072

    // Tray (open top): left wall up → floor → right wall up.
    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: cx - 0.30 * w, y: cy - 0.06 * w))
    tray.line(to: NSPoint(x: cx - 0.30 * w, y: cy - 0.27 * w))
    tray.line(to: NSPoint(x: cx + 0.30 * w, y: cy - 0.27 * w))
    tray.line(to: NSPoint(x: cx + 0.30 * w, y: cy - 0.06 * w))
    tray.lineWidth = stroke
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    cream.setStroke(); tray.stroke()

    // Checkmark resting in the tray.
    let check = NSBezierPath()
    check.move(to: NSPoint(x: cx - 0.24 * w, y: cy + 0.07 * w))
    check.line(to: NSPoint(x: cx - 0.06 * w, y: cy - 0.12 * w))
    check.line(to: NSPoint(x: cx + 0.28 * w, y: cy + 0.26 * w))
    check.lineWidth = stroke * 1.05
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    cream.setStroke(); check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// Standard iconset members: 1x and 2x for each point size.
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),   (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),   (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes { writePNG(render(px), name) }
print("Wrote iconset to \(outDir)")
