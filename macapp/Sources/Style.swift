// Style.swift — the brand's warm-paper palette (ported from the panel's OKLCH
// tokens to sRGB) and a few reusable SwiftUI pieces. Light theme only; the surface
// underneath is real Liquid Glass (NSGlassEffectView), so content here is opaque
// ink on translucent warm surfaces — never glass-on-glass.

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

enum Paper {
    static let paper       = Color(0.985, 0.973, 0.953)
    static let raised      = Color(0.967, 0.952, 0.929)
    static let sunken      = Color(0.949, 0.933, 0.909)
    static let ink         = Color(0.227, 0.196, 0.165)
    static let ink2        = Color(0.435, 0.392, 0.341)
    static let ink3        = Color(0.612, 0.561, 0.498)
    static let ink4        = Color(0.722, 0.671, 0.604)
    static let hairline    = Color(0.895, 0.866, 0.827)
    static let accent      = Color(0.792, 0.420, 0.298)
    static let accentPress = Color(0.706, 0.353, 0.243)
    static let accentSoft  = Color(0.953, 0.878, 0.831)
    static let clear       = Color(0.353, 0.596, 0.451)
    static let danger      = Color(0.776, 0.298, 0.255)
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

// The single tinted call-to-action. Solid terracotta (not glass) so it reads as
// the one primary action over the glass surface, per Apple's "tint = one thing".
struct PrimaryButtonStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15).frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Paper.accentPress : Paper.accent)
            )
            .opacity(enabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}

// Quiet secondary action: hairline-bordered warm chip.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Paper.ink2)
            .padding(.horizontal, 13).frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Paper.raised.opacity(configuration.isPressed ? 0.95 : 0.6))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Paper.hairline.opacity(0.7), lineWidth: 0.5))
            )
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
