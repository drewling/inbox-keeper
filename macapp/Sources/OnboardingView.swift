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

            Text("zero")
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
                    if !m.preflight.claude { ToolRow(name: "Claude Code CLI", cmd: "npm i -g @anthropic-ai/claude-code") }
                }
                .padding(14)
                .glassSurface(12, tint: Paper.danger.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Paper.danger.opacity(0.22), lineWidth: 0.75))
                .frame(maxWidth: 320).padding(.top, 14)
            }

            Spacer(minLength: 18)

            if m.needsCredentials {
                // gws is installed but there's no Google OAuth client yet — let the
                // user set one up in-app instead of hand-placing client_secret.json.
                CredentialsCard()
            } else {
                // Connect the first inbox. gws is required for the OAuth flow.
                // While the sign-in job is running, show the live message from the
                // server and a Cancel button so the user is never stuck.
                Button { m.addAccount() } label: {
                    HStack(spacing: 7) {
                        if m.isBusy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "plus").font(.system(size: 12, weight: .bold)) }
                        Text(m.isBusy ? "Signing in…" : "Connect your first inbox")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: m.preflight.gws && !m.isBusy))
                .disabled(!m.preflight.gws || m.isBusy)

                // Cancel is always reachable during a sign-in — the user must be able
                // to back out of a stuck OAuth flow without force-quitting.
                if m.isBusy {
                    if let msg = m.job?.message, !msg.isEmpty {
                        Text(msg)
                            .font(.system(size: 11)).foregroundStyle(Paper.ink4)
                            .multilineTextAlignment(.center).frame(maxWidth: 300)
                            .padding(.top, 6)
                    }
                    if let urlStr = m.job?.authUrl, let url = URL(string: urlStr) {
                        Button("Open the sign-in page") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Paper.accentSoft)
                            .padding(.top, 2)
                    }
                    Button("Cancel sign-in") { m.cancelJob() }
                        .buttonStyle(GhostButtonStyle())
                        .padding(.top, 8)
                } else {
                    Text("Sign-in opens in your browser. The app never sees your password.")
                        .font(.system(size: 11)).foregroundStyle(Paper.ink4)
                        .multilineTextAlignment(.center).frame(maxWidth: 300)
                        .padding(.top, 10)
                }
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// One-time, skippable first-run step: clear the backlog so the keeper starts from a
// calm inbox. Reversible (lands in Undo). Same glass language as OnboardingView.
struct BacklogStep: View {
    @EnvironmentObject var m: KeeperModel
    @State private var beforeDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    private static let apiFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; return f
    }()
    private static let humanFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)

            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Paper.accentHi, Paper.accent], startPoint: .top, endPoint: .bottom))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "archivebox")
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(Color(0.99, 0.99, 1.0)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
                .shadow(color: Paper.accent.opacity(0.45), radius: 12, y: 4)

            Text("Start from a calm inbox")
                .font(.system(size: 19, weight: .semibold)).kerning(-0.2).padding(.top, 16)
            Text("Optionally archive everything older than a date you choose, so zero only weighs what's recent. Nothing is deleted — it's one tap to undo.")
                .font(.system(size: 13)).foregroundStyle(Paper.ink3)
                .multilineTextAlignment(.center).frame(maxWidth: 320).padding(.top, 6)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text("Archive everything before").font(.system(size: 12.5)).foregroundStyle(Paper.ink2)
                    DatePicker("", selection: $beforeDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.shield").font(.system(size: 11)).foregroundStyle(Paper.clear)
                    Text("Starred, flagged, and live sign/pay/legal mail is always kept.")
                        .font(.system(size: 11)).foregroundStyle(Paper.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .padding(16).glassSurface(13).frame(maxWidth: 340).padding(.top, 20)

            Spacer(minLength: 18)

            Button {
                m.archiveBefore(before: Self.apiFmt.string(from: beforeDate))
                m.dismissBacklog()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "archivebox").font(.system(size: 12, weight: .bold))
                    Text("Archive before \(Self.humanFmt.string(from: beforeDate))")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !m.isBusy)).disabled(m.isBusy)

            Button("Skip for now") { m.dismissBacklog() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Paper.ink3).padding(.top, 12)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Onboarding credential setup: the user creates a free Desktop OAuth client in
// Google Cloud Console and pastes the downloaded client_secret.json here, so a
// stranger can set zero up without hand-editing files. The sign-in consent still
// happens in the browser when they connect. The JSON stays on this Mac.
private struct CredentialsCard: View {
    @EnvironmentObject var m: KeeperModel
    @State private var pasted = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SET UP GOOGLE ACCESS").font(.system(size: 10, weight: .semibold)).kerning(0.5)
                .foregroundStyle(Paper.ink4)
            Text("zero signs in through your own free Google app. Create an OAuth client, then paste it below — it never leaves this Mac.")
                .font(.system(size: 12)).foregroundStyle(Paper.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://console.cloud.google.com/apis/credentials")!) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Open Google Cloud Console")
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(Paper.accentSoft)
            }.buttonStyle(.plain)
            Text("Create credentials → OAuth client ID → Desktop app → download the JSON. Enable the Gmail API for the project.")
                .font(.system(size: 10.5)).foregroundStyle(Paper.ink4)
                .fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $pasted)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 60).padding(8).glassSurface(8)
                if pasted.isEmpty {
                    Text("Paste client_secret.json here")
                        .font(.system(size: 11)).foregroundStyle(Paper.ink4)
                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
            Button { m.saveCredentials(pasted) } label: {
                Text("Save Google access").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(14).glassSurface(13).frame(maxWidth: 320).padding(.top, 14)
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
