// PanelView.swift — the entire panel UI in SwiftUI. Hosted (via NSHostingView)
// inside a real NSGlassEffectView, so this view tree draws no opaque full-bleed
// background: bright text and subtle surface overlays sit directly on the dark
// "Raycast" glass. Ports every feature of the old web panel: the four views, the
// reply composer, optimistic set-aside with undo, and the run/job status.

import SwiftUI

struct PanelView: View {
    @EnvironmentObject var m: KeeperModel
    @Namespace private var segNS

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                TopBar()
                SegmentedNav(ns: segNS)
                ContentArea()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ActionBar()
            }

            if let t = m.toastInfo {
                ToastView(info: t).padding(.bottom, 66)   // clears the action bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if m.composer != nil {
                ComposerView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: PANEL_W, height: PANEL_H)
        .background(
            // Warm depth over the vibrancy: a little darker/richer toward the bottom.
            LinearGradient(colors: [Color(0.15, 0.135, 0.12).opacity(0.32),
                                    Color(0.10, 0.09, 0.08).opacity(0.46)],
                           startPoint: .top, endPoint: .bottom)
        )
        .foregroundStyle(Paper.ink)
        .tint(Paper.accent)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.22), value: m.toastInfo)
        .animation(.snappy(duration: 0.28), value: m.composer?.id)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        HStack(spacing: 8) {
            // Wordmark: a glossy terracotta squircle with a cream check (echoes the
            // app icon) + "inbox·keeper".
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Paper.accentHi, Paper.accent], startPoint: .top, endPoint: .bottom))
                .frame(width: 16, height: 16)
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color(0.99, 0.975, 0.94)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                .shadow(color: Paper.accent.opacity(0.4), radius: 3, y: 1)
            HStack(spacing: 0) {
                Text("inbox").fontWeight(.semibold)
                Text("·").foregroundStyle(Paper.ink4)
                Text("keeper").fontWeight(.semibold)
            }
            .font(.system(size: 13.5))
            .kerning(-0.1)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                ForEach(m.state?.accounts ?? []) { a in AccountDot(account: a) }
            }
        }
        .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 11)
        .background(Paper.raised.opacity(0.05))
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
    }
}

private struct AccountDot: View {
    let account: Account
    var body: some View {
        Circle()
            .fill(Color(hex: account.color))
            .frame(width: 27, height: 27)
            .overlay(Text(account.short).font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
            .overlay {
                if !account.ok {
                    Circle().strokeBorder(Paper.danger, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if account.inboxThreads > 0 {
                    Text(account.inboxThreads > 99 ? "99+" : "\(account.inboxThreads)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(Paper.accent))
                        .overlay(Capsule().strokeBorder(Paper.paper.opacity(0.85), lineWidth: 1.2))
                        .offset(x: 6, y: -5)
                }
            }
            .help(account.email + (account.ok ? "" : " — needs attention"))
    }
}

// MARK: - Segmented nav

private struct SegmentedNav: View {
    @EnvironmentObject var m: KeeperModel
    let ns: Namespace.ID
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                let on = m.tab == tab
                Button {
                    withAnimation(.snappy(duration: 0.3)) { m.tab = tab }
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Paper.ink : Paper.ink3)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Paper.raised.opacity(0.16))
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(LinearGradient(colors: [Paper.hairline.opacity(0.28), Paper.hairline.opacity(0.05)],
                                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Paper.sunken.opacity(0.22)))
        .padding(.horizontal, 14).padding(.vertical, 10)
        .focusEffectDisabled()         // no blue focus ring on the first-load selected tab
    }
}

// MARK: - Content area (per tab)

private struct ContentArea: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        Group {
            switch m.tab {
            case .loops: LoopsView()
            case .accounts: AccountsView()
            case .undo: UndoView()
            case .policy: PolicyView()
            }
        }
        .id(m.tab)
        .transition(.opacity)
    }
}

// MARK: - Open loops

private struct LoopsView: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        if m.state == nil || m.state?.needsBuild == true {
            SkeletonView()
        } else if m.isKeeping {
            TidyingView(message: m.job?.message ?? "Starting…")
        } else {
            let rows = m.loopRows
            let total = m.state?.totalLoops ?? rows.count
            let failed = (m.state?.accounts ?? []).filter { !$0.ok }
            if total == 0 && !failed.isEmpty {
                EmptyState(symbol: "exclamationmark.triangle", warn: true,
                           title: "Couldn’t check your inboxes",
                           message: "\(failed.count == 1 ? "An account" : "\(failed.count) accounts") didn’t respond, so this isn’t a real “all clear”. \(failed.first?.error ?? "")")
            } else if total == 0 {
                EmptyState(symbol: "checkmark", warn: false,
                           title: "Your inboxes are clear",
                           message: "Nothing is waiting on you across \(m.state?.accounts.count ?? 0) accounts. Everything else was set aside, reversibly.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !failed.isEmpty { Banner(text: bannerText(failed), error: true) }
                        HeroCount(total: total, accounts: m.state?.accounts.count ?? 0)
                        SectionLabel("Waiting on you")
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in LoopRowView(row: row) }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 14)
                    }
                }
            }
        }
    }
    private func bannerText(_ failed: [Account]) -> String {
        let names = failed.map(\.short).joined(separator: ", ")
        return "Couldn’t read \(failed.count == 1 ? "an account" : "\(failed.count) accounts") (\(names)). Counts below may be incomplete."
    }
}

private struct HeroCount: View {
    let total: Int; let accounts: Int
    var body: some View {
        VStack(spacing: 2) {
            Text("\(total)").font(.system(size: 46, weight: .bold)).foregroundStyle(Paper.accent).kerning(-1)
            Text(total == 1 ? "thing still needs you" : "things still need you")
                .font(.system(size: 15, weight: .medium))
            Text("Across \(accounts) accounts. Tap any to open it in Gmail.")
                .font(.system(size: 12)).foregroundStyle(Paper.ink3)
        }
        .frame(maxWidth: .infinity).padding(.top, 22).padding(.bottom, 16)
    }
}

private struct LoopRowView: View {
    @EnvironmentObject var m: KeeperModel
    let row: LoopRow
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 11) {
            InitialsChip(text: row.account.short, color: Color(hex: row.account.color))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.loop.sender).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(row.loop.subject).font(.system(size: 12.5)).foregroundStyle(Paper.ink3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { m.open(row) }

            Text(relTime(row.loop.epoch)).font(.system(size: 11)).foregroundStyle(Paper.ink4)

            HStack(spacing: 2) {
                RowAction(symbol: "arrowshape.turn.up.left", help: "Draft a reply") { m.openComposer(row) }
                RowAction(symbol: "archivebox", help: "Set aside (reversible)") {
                    withAnimation(.easeOut(duration: 0.18)) { m.dismiss(row) }
                }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hovering ? Paper.raised.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
    }
}

private struct RowAction: View {
    let symbol: String; let help: String; let action: () -> Void
    @State private var over = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(over ? Paper.accent : Paper.ink3)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(over ? Paper.accentSoft.opacity(0.16) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help).onHover { over = $0 }
    }
}

// MARK: - Accounts

private struct AccountsView: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        let accts = m.state?.accounts ?? []
        if accts.isEmpty {
            VStack(spacing: 14) {
                EmptyState(symbol: "archivebox", warn: false,
                           title: "Connect your first inbox",
                           message: "Add a Gmail account and the keeper starts watching for what needs you.")
                Button { m.addAccount() } label: { Label("Add a Gmail account", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(accts) { a in AccountCard(account: a) }
                    Button { m.addAccount() } label: {
                        Label("Add a Gmail account", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GhostButtonStyle()).padding(.top, 4)
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
        }
    }
}

private struct AccountCard: View {
    let account: Account
    var body: some View {
        HStack(spacing: 12) {
            InitialsChip(text: account.short, color: Color(hex: account.color), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(statLine).font(.system(size: 11.5))
                    .foregroundStyle(account.ok ? Paper.ink3 : Paper.danger).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(spacing: 0) {
                Text(account.ok ? "\(account.inboxThreads)" : "—").font(.system(size: 17, weight: .bold))
                Text("open").font(.system(size: 10)).foregroundStyle(Paper.ink4)
            }
        }
        .padding(12)
        .glassSurface(12)
    }
    private var statLine: String {
        guard account.ok else { return "Couldn’t reach this account" }
        var bits = ["\(account.unread) unread"]
        if account.archivedCount > 0 { bits.append("\(account.archivedCount) archived") }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Undo

private struct UndoView: View {
    @EnvironmentObject var m: KeeperModel
    private var items: [(point: UndoPoint, account: Account)] {
        var out: [(UndoPoint, Account)] = []
        for a in m.state?.accounts ?? [] { for u in a.undoPoints { out.append((u, a)) } }
        return out.sorted { $0.0.date > $1.0.date }
    }
    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "checkmark", warn: false, title: "Nothing to undo",
                       message: "Archived mail is grouped by the day it was set aside. Restore points appear here.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing is ever deleted. Each point restores a day’s set-aside threads back to the inbox in one tap.")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink3)
                        .padding(.horizontal, 4).padding(.bottom, 4)
                    ForEach(items, id: \.point.id) { item in
                        UndoRow(point: item.point, account: item.account)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
        }
    }
}

private struct UndoRow: View {
    @EnvironmentObject var m: KeeperModel
    let point: UndoPoint; let account: Account
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(point.count) \(point.count == 1 ? "thread" : "threads") set aside")
                    .font(.system(size: 13, weight: .medium))
                Text("\(account.email) · \(point.date)").font(.system(size: 11.5)).foregroundStyle(Paper.ink3)
            }
            Spacer()
            Button("Restore") { m.undo(point, slug: account.slug) }
                .buttonStyle(GhostButtonStyle()).disabled(m.isBusy)
        }
        .padding(12)
        .glassSurface(12)
    }
}

// MARK: - Policy

private struct PolicyView: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("The **only** thing you configure. Describe what counts as “still needs me” in plain English. The agent reads each thread and enforces it.")
                    .font(.system(size: 12)).foregroundStyle(Paper.ink2)

                TextEditor(text: $m.policyDraft)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Paper.sunken.opacity(0.24))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Paper.hairline.opacity(0.12), lineWidth: 0.5)))

                let learned = (m.state?.learned ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if learned.isEmpty {
                    Text("As you set loops aside and edit drafts, the keeper learns your preferences and shows them here.")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink4)
                } else {
                    SectionLabel("Learned from your actions").padding(.top, 4)
                    MarkdownLite(text: stripLeadingHeading(learned))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
    }
    private func stripLeadingHeading(_ s: String) -> String {
        guard s.hasPrefix("#") else { return s }
        return s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
    }
}

// Minimal markdown for the learned block: ## headings, - bullets, **bold**.
private struct MarkdownLite: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                if line.hasPrefix("#") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(.system(size: 12.5, weight: .semibold)).padding(.top, 3)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(Paper.ink4)
                        Text(inline(String(line.dropFirst(2)))).font(.system(size: 12)).foregroundStyle(Paper.ink2)
                    }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(inline(line)).font(.system(size: 12)).foregroundStyle(Paper.ink2)
                }
            }
        }
    }
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// MARK: - Reply composer

private struct ComposerView: View {
    @EnvironmentObject var m: KeeperModel
    @StateObject private var rich = RichTextController()
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reply to \(m.composer?.loop.sender ?? "")").font(.system(size: 13, weight: .semibold))
                        Text(m.composer?.loop.subject ?? "").font(.system(size: 11.5)).foregroundStyle(Paper.ink3).lineLimit(1)
                    }
                    Spacer()
                    Button { m.closeComposer() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(Paper.ink3).accessibilityLabel("Close")
                }
                .padding(14)
                .background(Paper.sunken.opacity(0.24))
                .overlay(alignment: .bottom) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }

                if m.composerLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Drafting in your voice…").font(.system(size: 12.5)).foregroundStyle(Paper.ink3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 178)
                } else {
                    FormatBar(rich: rich)
                    RichTextEditor(controller: rich, initialText: m.composerText)
                        .frame(minHeight: 150)
                        .padding(.horizontal, 8).padding(.bottom, 4)
                    HStack(spacing: 8) {
                        TextField("Adjust the draft (e.g. shorter, warmer, decline politely)", text: $m.composerSteer)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Paper.sunken.opacity(0.24)))
                        Button { m.regenerate() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(GhostButtonStyle()).accessibilityLabel("Regenerate draft")
                    }
                    .padding(.horizontal, 12).padding(.bottom, 6)
                }

                HStack {
                    Spacer()
                    Button { m.sendReply(plain: rich.plainText(), html: rich.html()) } label: {
                        HStack(spacing: 6) {
                            if m.composerSending { ProgressView().controlSize(.small).tint(.white) }
                            Text(m.composerSending ? "Sending…" : "Send reply")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(m.composerLoading || m.composerSending)
                }
                .padding(12)
                .background(Paper.sunken.opacity(0.24))
                .overlay(alignment: .top) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
            }
            .background(Paper.paper.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Paper.hairline.opacity(0.2), Paper.hairline.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
            .padding(10)
        }
    }
}

// Formatting toolbar that drives the rich-text editor. mousedown-style buttons keep
// the editor's selection while applying the format.
private struct FormatBar: View {
    @ObservedObject var rich: RichTextController
    var body: some View {
        HStack(spacing: 4) {
            fmt({ Text("B").font(.system(size: 13, weight: .bold)) }, "Bold") { rich.toggleBold() }
            fmt({ Text("I").font(.system(size: 13, weight: .medium)).italic() }, "Italic") { rich.toggleItalic() }
            fmt({ Image(systemName: "list.bullet").font(.system(size: 12)) }, "Bulleted list") { rich.toggleBullet() }
            fmt({ Image(systemName: "link").font(.system(size: 12)) }, "Add link") { rich.addLink() }
            Spacer()
        }
        .foregroundStyle(Paper.ink2)
        .padding(.horizontal, 12).padding(.top, 8)
    }
    private func fmt<L: View>(@ViewBuilder _ label: () -> L, _ a11y: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label().frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Paper.sunken.opacity(0.24)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(a11y)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        HStack(spacing: 10) {
            if m.tab == .policy {
                Spacer()
                Button("Save policy") { m.savePolicy() }.buttonStyle(GhostButtonStyle())
            } else {
                Text(statusText)
                    .font(.system(size: 11.5)).foregroundStyle(m.isBusy ? Paper.accent : Paper.ink3)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { m.runKeeper() } label: {
                    HStack(spacing: 6) {
                        if m.isBusy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)) }
                        Text(m.isBusy ? "Keeping…" : "Run keeper now")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !m.isBusy)).disabled(m.isBusy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Paper.raised.opacity(0.05))
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
    }
    private var statusText: String {
        if m.isBusy { return m.job?.message ?? "Working…" }
        return "Tidies every inbox to only what needs you."
    }
}

// MARK: - Shared pieces

private struct TidyingView: View {
    let message: String
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Tidying your inboxes").font(.system(size: 17, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(Paper.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyState: View {
    let symbol: String; let warn: Bool; let title: String; let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(warn ? Paper.danger : Paper.clear)
                .frame(width: 60, height: 60)
                .background(Circle().fill((warn ? Paper.danger : Paper.clear).opacity(0.12)))
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(Paper.ink3)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

private struct Banner: View {
    let text: String; let error: Bool
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(error ? Paper.danger : Paper.ink2)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill((error ? Paper.danger : Paper.ink4).opacity(0.1)))
            .padding(.horizontal, 14).padding(.top, 12)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.5)
            .foregroundStyle(Paper.ink4).padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 4)
    }
}

private struct SkeletonView: View {
    var body: some View {
        VStack(spacing: 14) {
            ForEach(0..<6, id: \.self) { _ in
                HStack(spacing: 11) {
                    RoundedRectangle(cornerRadius: 7).fill(Paper.raised.opacity(0.09)).frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).fill(Paper.raised.opacity(0.09)).frame(width: 120, height: 9)
                        RoundedRectangle(cornerRadius: 3).fill(Paper.raised.opacity(0.06)).frame(maxWidth: .infinity).frame(height: 9)
                    }
                }
            }
            Spacer()
        }
        .padding(18)
    }
}

private struct ToastView: View {
    let info: ToastInfo
    var body: some View {
        HStack(spacing: 12) {
            Text(info.message).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
            if let undo = info.undo {
                Button("Undo") { undo() }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Paper.accentSoft)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Paper.paper.opacity(0.96)).shadow(color: .black.opacity(0.22), radius: 12, y: 4))
    }
}
