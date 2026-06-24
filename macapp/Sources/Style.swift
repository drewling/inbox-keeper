// Style.swift — the brand palette + reusable pieces. Dark "Raycast" theme: the
// panel base is masked dark vibrancy; on top of it, control-layer elements (cards,
// segmented control, action bar, composer) get a glassy treatment — a translucent
// frosted fill plus a bright top sheen — so the whole panel reads as layered glass
// without the harsh full-panel rim of NSGlassEffectView.

import SwiftUI
import AppKit

extension Color {
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
    /// Parse "#RRGGBB" (the per-account / per-category color the server hands us).
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
    /// "#RRGGBB" for round-tripping a ColorPicker selection back to the server.
    func hexString() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Dark "Raycast" theme. The base is a deep, near-neutral graphite (only a whisper
// of warmth so it relates to the terracotta mark without going muddy-brown), so the
// glass reads clean and the one accent really pops. `raised` is a near-white used at
// LOW alpha as a lifting overlay; `sunken` is black for recessed insets; `paper` is
// the opaque graphite for the composer + toast; the sheen white is faintly COOL, the
// way real glass catches light.
enum Paper {
    static let paper       = Color(0.10, 0.098, 0.094)    // deep graphite surface
    static let raised      = Color(0.97, 0.965, 0.96)     // light overlay (low alpha)
    static let sunken      = Color(0.0, 0.0, 0.0)         // dark inset (low alpha)
    static let ink         = Color(0.97, 0.965, 0.96)     // primary text
    static let ink2        = Color(0.85, 0.845, 0.835)    // secondary — kept bright for glass
    static let ink3        = Color(0.71, 0.705, 0.695)
    static let ink4        = Color(0.56, 0.555, 0.545)
    static let hairline    = Color(0.97, 0.98, 1.0)       // dividers / glass sheen — faintly cool
    static let accent      = Color(0.102, 0.451, 0.910)   // Google blue (#1A73E8)
    static let accentHi    = Color(0.259, 0.522, 0.957)   // lit top of the CTA gradient (#4285F4)
    static let accentPress = Color(0.082, 0.341, 0.690)   // pressed
    static let accentSoft  = Color(0.541, 0.706, 0.973)   // blue text on dark (#8AB4F8, toast undo)
    static let clear       = Color(0.45, 0.81, 0.62)      // reward green (Google green family)
    static let danger      = Color(0.94, 0.40, 0.40)      // error red, kept distinct from the blue accent
}

// Control-layer surface, rendered with the native macOS 26 Liquid Glass material
// (.glassEffect) so cards, the composer, and buttons get the system's real glass
// refraction + adaptive edge — not a hand-painted imitation. `interactive` turns on
// the system's press/hover response (for buttons); `tint` optionally tints the glass.
extension View {
    func glassSurface(_ radius: CGFloat, interactive: Bool = false, tint: Color? = nil) -> some View {
        // A subtle dark tint by default: keeps the glass reading as glass while
        // guaranteeing a dark-enough backing so text stays legible even when
        // something bright sits behind the panel.
        var glass: Glass = .regular.tint(tint ?? Color(0, 0, 0).opacity(0.26))
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: .rect(cornerRadius: radius))
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

// Quiet secondary action: an interactive Liquid Glass chip (the system handles the
// press/hover response).
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Paper.ink2)
            .padding(.horizontal, 13).frame(height: 30)
            .glassSurface(8, interactive: true)
            .contentShape(Rectangle())
    }
}

// The one account mark, used in rows, cards, and the top strip: a circular avatar
// showing the real Gmail profile photo when we have one, falling back to a coloured
// initials circle while it loads or if the account has no photo.
struct Avatar: View {
    let text: String
    let color: Color
    var photoURL: String? = nil
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            initials                                   // always behind, so it shows while loading
            if let s = photoURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill().transition(.opacity)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
    private var initials: some View {
        Text(text)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
    }
}

// A small coloured tag marking which category the keeper sorted an open loop into.
struct CategoryTag: View {
    let category: Category
    var body: some View {
        HStack(spacing: 3) {
            Text(category.emoji).font(.system(size: 8.5))
            Text(category.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Color(hex: category.color))
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Capsule().fill(Color(hex: category.color).opacity(0.16)))
        .overlay(Capsule().strokeBorder(Color(hex: category.color).opacity(0.30), lineWidth: 0.5))
        .fixedSize()
    }
}
