// OnboardingView.swift — the first-run takeover. Shown until at least one Gmail
// account is connected. It states the one job, flags any missing prerequisite
// (python3 / gws / claude) with the exact fix, and connects the first inbox via the
// browser OAuth flow the server already exposes. The app never sees a password.

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var m: KeeperModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            // App mark: the glossy blue squircle + cream check (echoes the icon). It
            // breathes almost imperceptibly so the first screen feels alive, not static.
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Paper.accentHi, Paper.accent], startPoint: .top, endPoint: .bottom))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 27, weight: .bold)).foregroundStyle(Color(0.99, 0.99, 1.0)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
                .shadow(color: Paper.accent.opacity(0.45), radius: 12, y: 4)
                .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.035]) { v, s in v.scaleEffect(s) }
                    animation: { _ in .easeInOut(duration: 2.4) }

            Text("inbox·keeper")
                .font(.system(size: 21, weight: .semibold)).kerning(-0.2)
                .padding(.top, 16)
            Text("Keeps your inbox at only what still needs you, across every account. Nothing is ever deleted.")
                .font(.system(size: 13)).foregroundStyle(Paper.ink3)
                .multilineTextAlignment(.center).frame(maxWidth: 300).padding(.top, 6)

            // Three quiet trust points.
            VStack(alignment: .leading, spacing: 9) {
                TrustRow(symbol: "arrow.uturn.backward", text: "Reversible by design. Archiving just removes the inbox label, restorable any time.")
                TrustRow(symbol: "moon.stars", text: "Ambient. It works quietly behind your existing mail apps, once a morning.")
                TrustRow(symbol: "brain", text: "Judged by an agent reading each thread, not brittle filter rules.")
            }
            .padding(16).glassSurface(13).frame(maxWidth: 320).padding(.top, 20)

            // Missing prerequisites (only if the check ran and found gaps).
            if m.preflight.checked && !m.preflight.allGood {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FIRST, INSTALL").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                        .foregroundStyle(Paper.ink4)
                    if !m.preflight.python { ToolRow(name: "Python 3", cmd: "xcode-select --install") }
                    if !m.preflight.gws { ToolRow(name: "Google Workspace CLI", cmd: "npm i -g @googleworkspace/cli") }
                    if !m.preflight.claude { ToolRow(name: "Claude CLI", cmd: "claude.ai/download") }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Paper.danger.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Paper.danger.opacity(0.22), lineWidth: 0.75))
                .frame(maxWidth: 320).padding(.top, 14)
            }

            Spacer(minLength: 18)

            // Connect the first inbox. gws is required for the OAuth flow.
            Button { m.addAccount() } label: {
                HStack(spacing: 7) {
                    if m.isBusy { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "plus").font(.system(size: 12, weight: .bold)) }
                    Text(m.isBusy ? "Opening your browser…" : "Connect your first inbox")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: m.preflight.gws && !m.isBusy))
            .disabled(!m.preflight.gws || m.isBusy)

            Text("Sign-in opens in your browser. The app never sees your password.")
                .font(.system(size: 11)).foregroundStyle(Paper.ink4)
                .multilineTextAlignment(.center).frame(maxWidth: 300)
                .padding(.top, 10)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrustRow: View {
    let symbol: String; let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Paper.accentSoft).frame(width: 18)
            Text(text).font(.system(size: 12)).foregroundStyle(Paper.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ToolRow: View {
    let name: String; let cmd: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.system(size: 12)).foregroundStyle(Paper.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(cmd).font(.system(size: 11, design: .monospaced)).foregroundStyle(Paper.ink3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }
}
