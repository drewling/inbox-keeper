// make_icon.swift — draws the zero app icon natively (no external image
// generation) and emits a full .iconset. build.sh runs `iconutil` on the output.
//
// The mark: a glossy Google-blue squircle holding a single bold cream checkmark
// ("inbox at zero — done, nothing lost"). Mirrors the user's reference icon.
// Deterministic + on-brand + in-repo.
//
//   swift make_icon.swift <output-iconset-dir>

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Brand palette: a Google-blue squircle holding a white check.
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let tileTop    = srgb(0.259, 0.522, 0.957)   // Google blue, lit (#4285F4)
let tileBottom = srgb(0.090, 0.380, 0.760)   // Google blue, shaded
let cream      = srgb(0.99, 0.99, 1.0)       // crisp white check

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
                  blur: S * 0.035, color: srgb(0.04, 0.10, 0.22, 0.32).cgColor)
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

    // Glyph: a single bold checkmark, centered, optically lifted a touch above
    // dead-center so it reads as balanced. (y-up coordinates.)
    let w = tile.width
    let cx = tile.midX, cy = tile.midY + w * 0.012
    let stroke = w * 0.115   // bold; stays legible down to 16px

    let check = NSBezierPath()
    check.move(to: NSPoint(x: cx - 0.225 * w, y: cy - 0.02 * w))
    check.line(to: NSPoint(x: cx - 0.055 * w, y: cy - 0.195 * w))
    check.line(to: NSPoint(x: cx + 0.255 * w, y: cy + 0.20 * w))
    check.lineWidth = stroke
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    // Faint inner shadow on the glyph for a debossed, glassy feel.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.006),
                  blur: w * 0.012, color: srgb(0.04, 0.10, 0.22, 0.28).cgColor)
    cream.setStroke(); check.stroke()
    ctx.restoreGState()

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
