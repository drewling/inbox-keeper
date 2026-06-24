// Style.swift — the brand palette + reusable pieces. Dark "Raycast" theme: the
// panel base is masked dark vibrancy; on top of it, control-layer elements (cards,
// segmented control, action bar, composer) get a glassy treatment — a translucent
// frosted fill plus a bright top sheen — so the whole panel reads as layered glass
// without the harsh full-panel rim of NSGlassEffectView.

import SwiftUI

extension Color {
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
    /// Parse "#RRGGBB" (the per-account color the server hands us).
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}

// Dark "Raycast" theme, warmed toward the brand hue (the charcoal is tinted, not
// neutral gray). `raised` is a near-white used at LOW alpha as a lifting overlay;
// `sunken` is near-black for recessed insets; `paper` is the warm charcoal for
// opaque surfaces (composer, toast).
enum Paper {
    static let paper       = Color(0.128, 0.118, 0.108)   // warm charcoal surface
    static let raised      = Color(0.99, 0.965, 0.93)     // warm light overlay (low alpha)
    static let sunken      = Color(0.0, 0.0, 0.0)         // dark inset (low alpha)
    static let ink         = Color(0.965, 0.95, 0.925)    // primary text (warm white)
    static let ink2        = Color(0.80, 0.775, 0.73)
    static let ink3        = Color(0.625, 0.60, 0.555)
    static let ink4        = Color(0.49, 0.465, 0.43)
    static let hairline    = Color(1.0, 0.98, 0.95)       // dividers / sheen (low alpha)
    static let accent      = Color(0.90, 0.53, 0.39)      // terracotta
    static let accentHi    = Color(0.94, 0.61, 0.47)      // lit top of the CTA gradient
    static let accentPress = Color(0.80, 0.45, 0.33)
    static let accentSoft  = Color(0.93, 0.65, 0.52)      // accent text on dark (toast undo)
    static let clear       = Color(0.47, 0.79, 0.59)      // reward green
    static let danger      = Color(0.92, 0.47, 0.44)
}

// Glassy control-layer surface: a translucent frosted fill plus a top-bright hairline
// that reads as a glass sheen. The single building block for "more liquid glass" on
// cards, the segmented track, the action bar, and the composer.
extension View {
    func glassSurface(_ radius: CGFloat, fill: Double = 0.06, sheen: Double = 0.18) -> some View {
        self
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Paper.raised.opacity(fill)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(
                    LinearGradient(colors: [Paper.hairline.opacity(sheen), Paper.hairline.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
    }
}

// Compact relative time: "now", "5m", "3h", "2d", "1w", "2mo".
func relTime(_ epoch: Int) -> String {
    guard epoch > 0 else { return "" }
    let s = max(0, Int(Date().timeIntervalSince1970) - epoch)
    if s < 90 { return "now" }
    let m = s / 60; if m < 60 { return "\(m)m" }
    let h = m / 60; if h < 24 { return "\(h)h" }
    let d = h / 24; if d < 7 { return "\(d)d" }
    let w = d / 7; if w < 5 { return "\(w)w" }
    return "\(d / 30)mo"
}

// The single tinted call-to-action: a glossy terracotta pill (vertical gradient +
// a bright top highlight) so it reads as liquid, the one accented control.
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(
                        colors: configuration.isPressed ? [Paper.accentPress, Paper.accentPress]
                                                         : [Paper.accentHi, Paper.accent],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.0)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                    .shadow(color: Paper.accent.opacity(configuration.isPressed ? 0 : 0.35), radius: 8, y: 2)
            )
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

// Quiet secondary action: a glassy frosted chip.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Paper.ink2)
            .padding(.horizontal, 13).frame(height: 30)
            .glassSurface(8, fill: configuration.isPressed ? 0.14 : 0.07)
            .contentShape(Rectangle())
    }
}

// Small initials chip (account color), used in rows + cards + the top strip.
struct InitialsChip: View {
    let text: String
    let color: Color
    var size: CGFloat = 26
    var body: some View {
        Text(text)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color))
    }
}
