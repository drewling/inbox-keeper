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
            // Starting state: server not yet reachable, or server is building state with
            // no accounts yet. Shown BEFORE needsOnboarding so boot never flashes onboarding.
            if !m.serverReady || (m.state?.building == true && (m.state?.accounts.isEmpty ?? true)) {
                StartingView()
            } else if m.needsOnboarding {
                OnboardingView()
            } else if m.showBacklogStep {
                BacklogStep()
            } else {
                VStack(spacing: 0) {
                    TopBar()
                    SegmentedNav(ns: segNS)
                    ContentArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ActionBar()
                }
            }

            if let t = m.toastInfo {
                ToastView(info: t).padding(.bottom, 66)   // clears the action bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if m.composer != nil {
                ComposerView()
                    // Moment 6: spring rise from below rather than a plain move slide.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom))
                                           .combined(with: .offset(y: 20)),
                        removal:   .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                                           .combined(with: .offset(y: 10))))
            }

            if m.cleanup != nil {
                CleanupView()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: PANEL_W, height: PANEL_H)
        .background(
            // Graphite depth over the vibrancy: clean and neutral, a touch deeper
            // toward the bottom (no brown).
            LinearGradient(colors: [Color(0.125, 0.122, 0.118).opacity(0.30),
                                    Color(0.085, 0.083, 0.08).opacity(0.50)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) {
            // Liquid-glass specular: a hairline of light catching the very top rim.
            LinearGradient(colors: [Paper.hairline.opacity(0.16), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 1.5).allowsHitTesting(false)
        }
        .foregroundStyle(Paper.ink)
        .tint(Paper.accent)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.22), value: m.toastInfo)
        // Moment 6: spring animation for composer open/close.
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: m.composer?.id)
        .animation(.snappy(duration: 0.28), value: m.cleanup?.slug)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @EnvironmentObject var m: KeeperModel
    // Read version once; falls back gracefully if bundle info is absent.
    private static let version: String =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    // Moment 9: one-shot sheen phase (0 → 1) restarted each time refreshSheenToken changes.
    @State private var sheenPhase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            // Wordmark: a glossy blue squircle with a cream check (echoes the
            // app icon) + the "zero" lowercase mark.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Paper.accentHi, Paper.accent], startPoint: .top, endPoint: .bottom))
                .frame(width: 16, height: 16)
                .overlay(Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color(0.99, 0.99, 1.0)))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
                .shadow(color: Paper.accent.opacity(0.4), radius: 3, y: 1)
            Text("zero").fontWeight(.semibold)
                .font(.system(size: 13.5))
                .kerning(-0.1)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                // Moment 2: account dot counts animate via .animation on their enclosing view;
                // the individual count text in AccountDot uses .contentTransition(.numericText()).
                ForEach(m.state?.accounts ?? []) { a in AccountDot(account: a) }
            }

            // Overflow menu — quiet trailing icon, mirrors RowAction / AccountCard ellipsis style.
            Menu {
                Button(role: .destructive) { NSApp.terminate(nil) } label: {
                    Label("Quit zero", systemImage: "power")
                }
                .keyboardShortcut("q")
                if !Self.version.isEmpty {
                    Divider()
                    // Non-interactive version label; disabled so it can't be actioned.
                    Text("zero \(Self.version)")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Paper.ink4)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)     // no accent-filled highlight while the menu is open
            .menuIndicator(.hidden)
            .fixedSize()
            .focusEffectDisabled()   // no blue focus ring when the panel auto-focuses it on open
            .help("More")
        }
        .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 11)
        .glassSurface(0)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
        // Moment 9: a glass sheen sweeps across the header edge after each reload.
        .overlay(alignment: .leading) {
            if !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Paper.hairline.opacity(0.32), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.4)
                        .offset(x: sheenPhase * (geo.size.width + geo.size.width * 0.4))
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
                .clipped()
            }
        }
        .onChange(of: m.refreshSheenToken) { _, _ in
            guard !reduceMotion else { return }
            sheenPhase = -0.4   // reset to left-of-frame
            withAnimation(.easeOut(duration: 0.6)) { sheenPhase = 1.0 }
        }
    }
}

private struct AccountDot: View {
    let account: Account
    private let size: CGFloat = 27
    var body: some View {
        // Same circular avatar the rows and cards use, for one consistent account mark.
        Avatar(text: account.short, color: Color(hex: account.color), photoURL: account.photoURL, size: size)
            .overlay {
                if !account.ok {
                    Circle().strokeBorder(Paper.danger, lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                if account.inboxThreads > 0 {
                    // A clean, neutral count pill cut into the panel — graphite fill +
                    // a faint cool rim — so it reads the same on every account colour
                    // instead of clashing a terracotta badge over a coloured chip.
                    // Moment 2: numericText rolls the digit when the count changes.
                    Text(account.inboxThreads > 99 ? "99+" : "\(account.inboxThreads)")
                        .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Paper.ink)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(account.inboxThreads)))
                        .animation(Motion.settle, value: account.inboxThreads)
                        .padding(.horizontal, account.inboxThreads > 9 ? 3.5 : 0)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Paper.paper))
                        .overlay(Capsule().strokeBorder(Paper.hairline.opacity(0.32), lineWidth: 0.75))
                        .offset(x: 5, y: -6)
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
                        withAnimation(Motion.morph) { m.tab = tab }
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? Paper.ink : Paper.ink3)
                            .legibleOnGlass()
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background {
                                if on {
                                    // A crisp raised pill that slides between tabs via
                                    // matchedGeometry. A subtle raised fill + hairline rim +
                                    // soft shadow reads cleanly as the selected segment (the
                                    // macOS/Raycast standard) — reliable, unlike glass-on-glass
                                    // inside a GlassEffectContainer, which rendered washed out.
                                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                        .fill(Paper.raised.opacity(0.22))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                                .strokeBorder(Paper.hairline.opacity(0.45), lineWidth: 0.75)
                                        )
                                        .shadow(color: .black.opacity(0.22), radius: 4, y: 1)
                                        .matchedGeometryEffect(id: "seg", in: ns)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        .padding(3)
        .background(
            // Subtly sunken track so the raised active pill reads as elevated above it.
            RoundedRectangle(cornerRadius: Radius.small + 3, style: .continuous)
                .fill(Paper.sunken.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.small + 3, style: .continuous)
                        .strokeBorder(Paper.hairline.opacity(0.10), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 14).padding(.vertical, 10)
        .focusEffectDisabled()         // no blue focus ring on the first-load selected tab
    }
}

// MARK: - Content area (per tab)

private struct ContentArea: View {
    @EnvironmentObject var m: KeeperModel
    // Moment 8: track previous tab for directional slide.
    @State private var prevTab: Tab = .loops

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
        // Moment 8: incoming content slides from the direction of the tab it came from.
        // Tab order: loops(0) → accounts(1) → undo(2) → policy(3).
        .transition(spatialTransition(from: prevTab, to: m.tab))
        .onChange(of: m.tab) { old, _ in prevTab = old }
    }

    // ponytail: directional slide ~32pt offset + fade; quick so nav doesn't feel slow.
    private func spatialTransition(from: Tab, to: Tab) -> AnyTransition {
        let allTabs = Tab.allCases
        guard let fromIdx = allTabs.firstIndex(of: from),
              let toIdx   = allTabs.firstIndex(of: to) else { return .opacity }
        let movingRight = toIdx > fromIdx
        let offset: CGFloat = movingRight ? 32 : -32
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: offset, y: 0)),
            removal:   .opacity.combined(with: .offset(x: -offset, y: 0)))
    }
}

// MARK: - Open loops

private struct LoopsView: View {
    @EnvironmentObject var m: KeeperModel

    var body: some View {
        if m.state == nil || m.state?.needsBuild == true {
            SkeletonView()
        } else {
            let rows = m.loopRows
            let total = m.state?.totalLoops ?? rows.count
            let failed = (m.state?.accounts ?? []).filter { !$0.ok }
            // While keeping, never show an "all clear" / error empty state — counts are
            // mid-flight. Fall through to the list path so the slim TidyingBanner shows
            // on top and the inbox stays visible + scrollable instead of a full takeover.
            Group {
                if total == 0 && !failed.isEmpty && !m.isKeeping && !m.isWorkingInline {
                    EmptyState(symbol: "exclamationmark.triangle", warn: true,
                               title: "Couldn't check your inboxes",
                               message: noResponseMsg(failed))
                } else if total == 0 && !m.isKeeping && !m.isWorkingInline {
                    EmptyState(symbol: "checkmark", warn: false,
                               title: "Inbox at zero.",
                               message: "Nothing needs you right now across \(m.state?.accounts.count ?? 0) accounts. Everything else was set aside, reversibly.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if m.isKeeping || m.isWorkingInline { TidyingBanner(message: m.job?.message ?? "Starting…") }
                            if !failed.isEmpty { Banner(text: bannerText(failed), error: true) }
                            HeroCount(total: total, accounts: m.state?.accounts.count ?? 0)
                            SectionLabel("Waiting on you")
                            // Moment 10: staggered first-paint cascade via StaggeredLoopList.
                            StaggeredLoopList(rows: rows)
                                .padding(.horizontal, 10).padding(.bottom, 14)
                        }
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                }
            }
            // Moment 1: gentle haptic the first time total drops to 0.
            .onChange(of: total) { old, new in
                if old > 0 && new == 0 && !m.isKeeping && !m.isWorkingInline {
                    Haptic.tap()
                }
            }
        }
    }

    private func bannerText(_ failed: [Account]) -> String {
        let names = failed.map(\.short).joined(separator: ", ")
        if failed.count == 1 {
            return "Couldn't read an account (\(names)). Counts below may be incomplete."
        }
        return "Couldn't read \(failed.count) accounts (\(names)). Counts below may be incomplete."
    }

    private func noResponseMsg(_ failed: [Account]) -> String {
        let noun = failed.count == 1 ? "An account" : "\(failed.count) accounts"
        let suffix = failed.first?.error ?? ""
        return "\(noun) didn't respond, so this isn't a real all-clear. \(suffix)"
    }
}

// Moment 10: rows stagger in with ~30ms between each, capped so a big list still
// finishes within ~0.4 s. Each row tracks its own visibility to avoid re-staggering
// on minor list updates (only stagger if the row is new to this render pass).
private struct StaggeredLoopList: View {
    let rows: [LoopRow]
    // ponytail: single ID set tracks which rows have already appeared this session.
    @State private var revealed: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                let isNew = !revealed.contains(row.id)
                LoopRowView(row: row)
                    .opacity(isNew ? 0 : 1)
                    .offset(y: isNew ? 8 : 0)
                    .onAppear {
                        guard isNew else { return }
                        if reduceMotion {
                            _ = revealed.insert(row.id)
                        } else {
                            // Cap per-row delay so even 20+ rows finish in ~0.4s.
                            let delay = min(Double(idx) * 0.030, 0.36)
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                withAnimation(Motion.sweep) { _ = revealed.insert(row.id) }
                            }
                        }
                    }
            }
        }
    }
}

private struct HeroCount: View {
    let total: Int; let accounts: Int
    var body: some View {
        VStack(spacing: 2) {
            // The count rolls digit-by-digit when something is set aside or a run
            // finishes — the inbox visibly getting lighter.
            Text("\(total)").font(.system(size: 46, weight: .bold)).foregroundStyle(Paper.accentSoft).kerning(-1)
                .contentTransition(.numericText(value: Double(total)))
                .animation(Motion.settle, value: total)
            Text(total == 1 ? "thing still needs you" : "things still need you")
                .font(.system(size: 15, weight: .medium))
            Text("Across \(accounts) accounts. Tap any to open it in Gmail.")
                .font(.system(size: 12)).foregroundStyle(Paper.ink3)
        }
        .legibleOnGlass()
        .frame(maxWidth: .infinity).padding(.top, 22).padding(.bottom, 16)
    }
}

private struct LoopRowView: View {
    @EnvironmentObject var m: KeeperModel
    let row: LoopRow
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 11) {
            Avatar(text: row.account.short, color: Color(hex: row.account.color), photoURL: row.account.photoURL)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.loop.sender).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let cat = m.state?.category(named: row.loop.category) {
                        CategoryTag(category: cat)
                    }
                }
                Text(row.loop.subject).font(.system(size: 12.5)).foregroundStyle(Paper.ink3).lineLimit(1)
            }
            .legibleOnGlass()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { m.open(row) }

            Text(relTime(row.loop.epoch)).font(.system(size: 11)).foregroundStyle(Paper.ink4).legibleOnGlass()

            HStack(spacing: 2) {
                RowAction(symbol: "arrowshape.turn.up.left", help: "Draft a reply") { m.openComposer(row) }
                RowAction(symbol: "archivebox", help: "Set aside (reversible)") {
                    withAnimation(Motion.sweep) { m.dismiss(row) }
                }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .glassSurface(9, interactive: true)
        // Moment 5: subtle lift on hover — scale + elevated shadow so the row feels
        // like it catches light and floats 1.5pt above the surface.
        .scaleEffect(hovering ? 1.008 : 1, anchor: .center)
        .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: hovering ? 6 : 0, y: hovering ? 2 : 0)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .onHover { hovering = $0 }
        // Leaving rows sweep right and dissolve, like being slid onto the set-aside
        // pile; arrivals (undo) just fade so a restore feels gentle, not jarring.
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .opacity.combined(with: .scale(scale: 0.94)).combined(with: .move(edge: .trailing))))
    }
}

private struct RowAction: View {
    let symbol: String; let help: String; let action: () -> Void
    @State private var over = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(over ? Paper.accentSoft : Paper.ink3)
                .frame(width: 28, height: 28)
                .glassSurface(7, interactive: over)
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
                           message: "Add a Gmail account and zero starts watching for what needs you.")
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
    @EnvironmentObject var m: KeeperModel
    let account: Account
    var body: some View {
        HStack(spacing: 12) {
            Avatar(text: account.short, color: Color(hex: account.color), photoURL: account.photoURL, size: 34)
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
            Menu {
                Button { m.openCleanup(account) } label: { Label("Clean up labels…", systemImage: "tag.slash") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.ink3).frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(!account.ok)
            .help("Account actions")
        }
        .padding(12)
        .glassSurface(12)
    }
    private var statLine: String {
        guard account.ok else { return "Couldn't reach this account" }
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
        // Newest dates first; the undated "earlier" bucket always sorts last.
        return out.sorted { a, b in
            if a.0.date == "earlier" { return false }
            if b.0.date == "earlier" { return true }
            return a.0.date > b.0.date
        }
    }
    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "checkmark", warn: false, title: "Nothing to undo",
                       message: "Archived mail is grouped by the day it was set aside. Restore points appear here.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nothing is ever deleted. Open a day to see the emails it set aside, and put any of them back in one tap.")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink3)
                        .padding(.horizontal, 4).padding(.bottom, 4)
                    // Key on position: an undo point's label/date can repeat across
                    // accounts, so \.point.id alone collides and SwiftUI duplicates rows.
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        UndoBatch(point: item.point, account: item.account)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }
        }
    }
}

// A recovery batch (one day's set-aside mail for one account). Tapping the header
// expands it to list the actual emails, each individually restorable.
private struct UndoBatch: View {
    @EnvironmentObject var m: KeeperModel
    let point: UndoPoint; let account: Account
    @State private var expanded = false

    private var key: String { m.undoKey(account.slug, point.label) }
    private var restored: Int { m.undoRestored[key] ?? 0 }
    private var remaining: Int { max(0, point.count - restored) }
    private var loaded: [UndoThread] { m.undoThreads[key] ?? [] }
    private var loading: Bool { m.undoLoading.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { expanded.toggle() }
                if expanded { m.loadUndoThreads(slug: account.slug, label: point.label) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Paper.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.prettyDate(point.date)).font(.system(size: 13, weight: .medium))
                        Text("\(remaining) set aside · \(account.email)")
                            .font(.system(size: 11.5)).foregroundStyle(Paper.ink3)
                    }
                    Spacer(minLength: 6)
                    Button("Restore all") { m.undo(point, slug: account.slug) }
                        .buttonStyle(GhostButtonStyle()).disabled(m.isBusy)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Rectangle().fill(Paper.hairline.opacity(0.12)).frame(height: 0.5)
                    .padding(.top, 10).padding(.bottom, 2)
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("Loading emails…").font(.system(size: 12)).foregroundStyle(Paper.ink3)
                    }.padding(.vertical, 8)
                } else if loaded.isEmpty {
                    Text("No emails to show here.")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink3).padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(loaded) { t in
                            UndoEmailRow(thread: t) {
                                m.restoreThread(slug: account.slug, label: point.label, thread: t)
                            }
                        }
                    }
                    if point.count > loaded.count {
                        Text("Showing the \(loaded.count) most recent of \(point.count). Restore all to recover the rest.")
                            .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                            .padding(.top, 6)
                    }
                }
            }
        }
        .padding(12)
        .glassSurface(12)
    }

    /// "2026-06-24" -> "Wed 24 Jun"; "earlier" -> "Earlier".
    static func prettyDate(_ raw: String) -> String {
        guard raw != "earlier" else { return "Earlier" }
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: raw) else { return raw }
        let out = DateFormatter(); out.dateFormat = "EEE d MMM"
        return out.string(from: d)
    }
}

private struct UndoEmailRow: View {
    let thread: UndoThread
    let restore: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 12.5)).lineLimit(1)
                Text(senderLine).font(.system(size: 11)).foregroundStyle(Paper.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: restore) {
                Image(systemName: "tray.and.arrow.up")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Paper.accentSoft)
                    .frame(width: 28, height: 26).glassSurface(7, interactive: true)
            }
            .buttonStyle(.plain).help("Put this email back in the inbox")
        }
        .padding(.vertical, 7)
    }

    private var senderLine: String {
        guard thread.epoch > 0 else { return thread.sender }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        let when = f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(thread.epoch)), relativeTo: Date())
        return thread.sender.isEmpty ? when : "\(thread.sender) · \(when)"
    }
}

// MARK: - Settings (keep policy · categories · learned)

private struct PolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                KeepPolicySection()
                CategoriesSection()
                DailyRoutineSection()
                IntelligenceSection()
                LearnedSection()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 18)
        }
    }
}

// Shared section header: a bright title + a quiet one-line description. Kept clearly
// legible on the glass (title in primary ink, subtitle in ink3, never the dim ink4).
private struct SettingsHeader: View {
    let title: String; let subtitle: String
    init(_ title: String, _ subtitle: String) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Paper.ink)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Paper.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KeepPolicySection: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("Rules",
                           "The one thing you configure. In plain English, what still needs you. Everything else is archived, reversibly.")
            TextEditor(text: $m.policyDraft)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Paper.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 130)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Paper.sunken.opacity(0.24))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Paper.hairline.opacity(0.12), lineWidth: 0.5)))
            HStack { Spacer(); Button("Save") { m.savePolicy() }.buttonStyle(GhostButtonStyle()) }
        }
    }
}

// MARK: Daily routine

// Replaces TimingSection. Exposes when the daily run fires, which days, grace window,
// notification preference, and the auto-draft power-user flag. Also keeps the
// backlog-clear one-off control.
private struct DailyRoutineSection: View {
    @EnvironmentObject var m: KeeperModel
    @State private var beforeDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"; return f
    }()

    // Day labels 0=Sun .. 6=Sat, matching the server contract.
    private static let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsHeader("Daily routine",
                           "When zero automatically runs. Changes take effect the next time the launch agent reschedules (if it's installed).")

            // ── When it runs ──────────────────────────────────────────────
            // Three clean rows: time · days · quick presets. Each label is fixed
            // width so it never gets squeezed into a vertical char stack.
            VStack(alignment: .leading, spacing: 11) {

                // Time row
                HStack(spacing: 8) {
                    Text("Run at").font(.system(size: 12.5)).foregroundStyle(Paper.ink2)
                        .fixedSize()
                    TimeStepperField(value: $m.scheduleHour, range: 0...23,
                                     format: { String(format: "%02d", $0) })
                    Text(":").font(.system(size: 13, weight: .semibold)).foregroundStyle(Paper.ink2)
                    TimeStepperField(value: $m.scheduleMinute, range: 0...59,
                                     format: { String(format: "%02d", $0) },
                                     step: 5)
                    Spacer(minLength: 0)
                }
                .onChange(of: m.scheduleHour)   { _, _ in m.saveSchedule() }
                .onChange(of: m.scheduleMinute) { _, _ in m.saveSchedule() }

                // Days-of-week pills
                HStack(spacing: 5) {
                    Text("On").font(.system(size: 12.5)).foregroundStyle(Paper.ink2)
                        .fixedSize()
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { day in
                            DayPill(label: Self.dayLabels[day],
                                    on: m.scheduleDays.contains(day)) {
                                if m.scheduleDays.contains(day) {
                                    if m.scheduleDays.count > 1 { m.scheduleDays.remove(day) }
                                } else {
                                    m.scheduleDays.insert(day)
                                }
                                m.saveSchedule()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                // Quick presets on their own row so nothing crowds the time/day rows.
                HStack(spacing: 8) {
                    Button("Weekdays") {
                        m.scheduleDays = [1, 2, 3, 4, 5]; m.saveSchedule()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Button("Every day") {
                        m.scheduleDays = [0, 1, 2, 3, 4, 5, 6]; m.saveSchedule()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .glassSurface(11)

            // ── Grace window + notify (one cohesive card) ─────────────────
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Protect mail newer than").font(.system(size: 12.5)).foregroundStyle(Paper.ink2)
                    Picker("", selection: Binding(get: { m.graceDays }, set: { m.saveGraceDays($0) })) {
                        Text("Off").tag(0)
                        Text("1 day").tag(1)
                        Text("2 days").tag(2)
                        Text("3 days").tag(3)
                        Text("7 days").tag(7)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Rectangle().fill(Paper.hairline.opacity(0.10)).frame(height: 0.5)
                SettingsToggleRow(
                    label: "Notify me when a run finishes",
                    value: Binding(get: { m.notifyOnRun }, set: { m.saveNotifyOnRun($0) })
                )
            }
            .glassSurface(Radius.card)

            // ── Archived mail labeling ────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Also label archived mail from").font(.system(size: 12.5)).foregroundStyle(Paper.ink2)
                    Picker("", selection: Binding(get: { m.labelArchivedDays }, set: { m.saveLabelArchivedDays($0) })) {
                        Text("Off").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Text("Keeps recent archived mail sorted into categories so there's always plenty labelled. Set to Off to skip.")
                    .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            .glassSurface(Radius.card)

            // ── Backlog clear (one-off) ────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Clear everything before").font(.system(size: 12.5)).foregroundStyle(Paper.ink2)
                    DatePicker("", selection: $beforeDate, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.field).labelsHidden().fixedSize()
                    Spacer(minLength: 6)
                    Button { m.archiveBefore(before: Self.fmt.string(from: beforeDate)) } label: {
                        Text("Clear backlog")
                    }
                    .buttonStyle(GhostButtonStyle()).disabled(m.isBusy)
                }
                Text("Clearing removes the inbox label and adds a dated recovery label — undo any time from the Undo tab. Starred, flagged, and live sign/pay/legal mail is always kept.")
                    .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .glassSurface(Radius.card)
        }
    }
}

// A single pill for the day-of-week selector.
private struct DayPill: View {
    let label: String; let on: Bool; let toggle: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: toggle) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(on ? Paper.ink : Paper.ink3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? Paper.accent.opacity(0.30) : Paper.raised.opacity(hovering ? 0.10 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(on ? Paper.accentSoft.opacity(0.55) : Paper.hairline.opacity(0.14), lineWidth: 0.75)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: on)
    }
}

// An inline stepper field for hour/minute — no system date picker, just up/down arrows
// flanking a fixed-width display. Wraps at range bounds.
private struct TimeStepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String
    var step: Int = 1

    var body: some View {
        HStack(spacing: 0) {
            Button { stepDown() } label: {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 26)
                    .foregroundStyle(Paper.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(format(value))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Paper.ink)
                .frame(width: 26, alignment: .center)

            Button { stepUp() } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 26)
                    .foregroundStyle(Paper.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Paper.sunken.opacity(0.22))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Paper.hairline.opacity(0.14), lineWidth: 0.5))
        )
    }

    private func stepUp() {
        let next = value + step
        value = next > range.upperBound ? range.lowerBound : next
    }
    private func stepDown() {
        let prev = value - step
        value = prev < range.lowerBound ? range.upperBound : prev
    }
}

// A toggle row that fits inside a glassSurface card (same height rhythm as CategoryEditRow).
private struct SettingsToggleRow: View {
    let label: String
    var sublabel: String? = nil
    @Binding var value: Bool
    var body: some View {
        Toggle(isOn: $value) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 12.5)).foregroundStyle(Paper.ink)
                if let sub = sublabel {
                    Text(sub).font(.system(size: 11)).foregroundStyle(Paper.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// MARK: Intelligence

// Shows which AI providers are detected and lets the user pick the active one.
private struct IntelligenceSection: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsHeader("Intelligence",
                               "The AI engine zero uses to read and sort your mail. Only installed providers are selectable.")
                Spacer(minLength: 6)
                Button {
                    Task { await m.fetchProviderStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Paper.ink3)
                        .frame(width: 26, height: 26)
                        .glassSurface(7, interactive: true)
                }
                .buttonStyle(.plain)
                .help("Refresh provider status")
            }

            if let ps = m.providerStatus {
                VStack(spacing: 0) {
                    ForEach(Array(ps.providers.enumerated()), id: \.element.name) { idx, provider in
                        if idx > 0 {
                            Rectangle().fill(Paper.hairline.opacity(0.10)).frame(height: 0.5)
                        }
                        ProviderRow(provider: provider, isSelected: m.provider == provider.name) {
                            if provider.available { m.saveProvider(provider.name) }
                        }
                    }
                }
                .glassSurface(11)

                // Connection status for the SELECTED provider, re-verified on every switch.
                let selected = ps.providers.first(where: { $0.name == m.provider })
                HStack(spacing: 6) {
                    if m.verifyingProvider {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Verifying \(selected?.label ?? m.provider)…")
                            .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                    } else if let p = selected, p.available, let version = p.version {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(Paper.accentSoft)
                        Text("Connected to \(p.label) · \(version)")
                            .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(Color.orange.opacity(0.9))
                        Text("\(selected?.label ?? m.provider) not detected")
                            .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassSurface(Radius.card)
                .animation(.easeOut(duration: 0.2), value: m.verifyingProvider)
                .animation(.easeOut(duration: 0.2), value: m.provider)
            } else {
                // Loading / unreachable
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("Checking providers…").font(.system(size: 12)).foregroundStyle(Paper.ink3)
                }
                .padding(12)
                .glassSurface(11)
            }
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderInfo
    let isSelected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Paper.accent : Paper.hairline.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 16, height: 16)
                    if isSelected {
                        Circle().fill(Paper.accent).frame(width: 8, height: 8)
                    }
                }
                .animation(.easeOut(duration: 0.14), value: isSelected)

                // Label + status chip
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(provider.available ? Paper.ink : Paper.ink4)
                    if provider.available, let ver = provider.version {
                        Text(ver).font(.system(size: 10.5)).foregroundStyle(Paper.ink4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Status chip
                if provider.available {
                    Text("Connected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Paper.accentSoft)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Paper.accentSoft.opacity(0.16)))
                } else {
                    Text("Not detected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Paper.ink4)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Paper.hairline.opacity(0.12)))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(isSelected ? Paper.accent.opacity(0.07) : (hovering && provider.available ? Paper.raised.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!provider.available)
        .onHover { hovering = $0 }
    }
}

// MARK: Categories editor

private struct CategoriesSection: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("Categories",
                           "Buckets zero sorts your open loops into. Each becomes a Gmail label and a tag on the list. They pass to the agent on the next run.")
            VStack(spacing: 6) {
                ForEach($m.categoriesDraft) { $cat in
                    CategoryEditRow(cat: $cat) { m.removeCategory(cat.id) }
                }
            }
            HStack(spacing: 10) {
                Button { withAnimation(Motion.pop) { m.addCategory() } } label: {
                    Label("Add category", systemImage: "plus")
                }
                .buttonStyle(GhostButtonStyle())
                Spacer()
                Button { m.saveCategories() } label: {
                    HStack(spacing: 6) {
                        if m.categoriesSaving { ProgressView().controlSize(.small) }
                        Text("Save categories")
                    }
                }
                .buttonStyle(GhostButtonStyle()).disabled(m.categoriesSaving)
            }
        }
    }
}

private struct CategoryEditRow: View {
    @Binding var cat: Category
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Emoji + colour together form the category's identity "token"
            CategoryToken(emoji: $cat.emoji, hex: $cat.color)

            VStack(alignment: .leading, spacing: 5) {
                TextField("Name", text: $cat.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Paper.ink)
                TextField("When should zero use this?", text: $cat.description)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Paper.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hovering ? Paper.danger : Paper.ink4)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel("Delete category")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassSurface(11)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}

// The emoji + colour "token" — a single pill chip that opens both pickers.
// Emoji tap → emoji popover; colour swatch tap → colour popover.
// The chip pulses with a spring bounce whenever either value changes.
private struct CategoryToken: View {
    @Binding var emoji: String
    @Binding var hex: String
    @State private var pulse = false

    private var tint: Color { Color(hex: hex) }

    var body: some View {
        HStack(spacing: 0) {
            CuteEmojiPicker(emoji: $emoji, tint: tint, onChange: triggerPulse)
            Rectangle().fill(tint.opacity(0.35)).frame(width: 1, height: 20)
                .padding(.horizontal, 3)
            CuteColorPicker(hex: $hex, onChange: triggerPulse)
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.13))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 0.75))
        )
        .scaleEffect(pulse ? 1.10 : 1)
        .animation(Motion.pop, value: pulse)
        // Pulse only on a committed pick (emoji choice, or a swatch tap via the
        // colour picker's onChange) — NOT on every hex value as a slider is dragged,
        // which made the token (and the popover anchored to it) jitter continuously.
        .onChange(of: emoji) { _, _ in triggerPulse() }
    }

    private func triggerPulse() {
        pulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { pulse = false }
    }
}

// MARK: Cute pickers — a curated emoji grid + a full in-app HSB colour control,
// in a glassy popover, so picking a tag's look feels like the rest of the panel.
// No NSColorPanel / system ColorPicker is opened anywhere.

private struct CuteEmojiPicker: View {
    @Binding var emoji: String
    let tint: Color
    var onChange: (() -> Void)? = nil
    @State private var open = false
    @State private var searchText = ""

    // Curated front-page: tasteful spread for email-triage labels, shown when search is empty.
    private static let suggested = [
        "🏷️","✉️","💌","📨","📥","💬","⏳","⌛️","📅","🗓️","⏰","🔔",
        "🔖","📌","📎","⚡️","🔥","🚨","⭐️","✅","☑️","🧾","💡","🎯",
        "🚀","☕️","🌱","🌸","🫶","🤝","🧠","🎉","❤️","👀","💼","🗂️",
        "📝","🔑","🛑","💸"]

    // Full searchable dataset: ~200 emoji with lowercase keyword arrays.
    private static let dataset: [(emoji: String, keywords: [String])] = [
        // Faces / smileys
        ("😀", ["grin","happy","smile","joy"]),
        ("😂", ["laugh","tears","lol","funny"]),
        ("🥲", ["smile","tear","bittersweet"]),
        ("😊", ["happy","blush","warm","smile"]),
        ("😍", ["love","heart eyes","adore"]),
        ("🤩", ["star","excited","wow","amazing"]),
        ("😎", ["cool","sunglasses","confident"]),
        ("🤔", ["think","question","hmm","wonder"]),
        ("😬", ["awkward","grimace","nervous"]),
        ("😴", ["sleep","tired","zzz","rest"]),
        ("😤", ["frustrated","huff","annoyed"]),
        ("😡", ["angry","mad","rage","upset"]),
        ("🥺", ["sad","plead","beg","puppy"]),
        ("😭", ["cry","sob","sad","tears"]),
        ("🤯", ["mind blown","shocked","wow"]),
        ("🫠", ["melt","overwhelmed","stress"]),
        ("🙃", ["silly","upside down","ironic"]),
        ("😇", ["angel","good","innocent","halo"]),
        ("🥳", ["party","celebrate","fun"]),
        // Hands / people
        ("👍", ["thumbs up","good","ok","approve","yes"]),
        ("👎", ["thumbs down","no","reject","bad"]),
        ("👋", ["wave","hello","hi","bye"]),
        ("🙌", ["praise","yay","celebrate","hands"]),
        ("👏", ["clap","applause","well done"]),
        ("🤝", ["handshake","deal","agree","partner"]),
        ("🙏", ["please","thanks","pray","gratitude"]),
        ("🫶", ["love","heart hands","care"]),
        ("✊", ["fist","solidarity","power","fight"]),
        ("👀", ["eyes","look","watch","see"]),
        ("🧠", ["brain","think","smart","idea","intelligence"]),
        ("💪", ["strong","muscle","power","flex"]),
        ("👤", ["person","user","account","profile"]),
        ("🧑‍💻", ["developer","coder","tech","programmer"]),
        // Hearts
        ("❤️", ["heart","love","red","care"]),
        ("🧡", ["orange","heart","love"]),
        ("💛", ["yellow","heart","happy","love"]),
        ("💚", ["green","heart","nature","love"]),
        ("💙", ["blue","heart","calm","love"]),
        ("💜", ["purple","heart","love"]),
        ("🖤", ["black","heart","dark"]),
        ("🤍", ["white","heart","pure","love"]),
        ("💔", ["broken heart","sad","breakup","loss"]),
        ("💕", ["hearts","love","affection","double"]),
        ("❤️‍🔥", ["heart fire","passion","intense","love"]),
        // Nature / animals / plants
        ("🌱", ["plant","grow","seedling","nature","green"]),
        ("🌿", ["herb","leaf","nature","green"]),
        ("🍀", ["clover","luck","lucky","four leaf"]),
        ("🌸", ["flower","cherry blossom","spring","pink"]),
        ("🌻", ["sunflower","sun","happy","bright"]),
        ("🌊", ["wave","ocean","sea","water"]),
        ("⛅", ["cloud","partly cloudy","weather"]),
        ("🌙", ["moon","night","dark","sleep"]),
        ("☀️", ["sun","sunny","bright","day","warm"]),
        ("🐛", ["bug","insect","error","issue"]),
        ("🐝", ["bee","busy","work","honey"]),
        ("🦋", ["butterfly","transform","change","growth"]),
        ("🐢", ["turtle","slow","steady","patient"]),
        ("🦊", ["fox","clever","crafty"]),
        ("🐱", ["cat","cute","meow","pet"]),
        // Food / drink
        ("☕️", ["coffee","cafe","morning","drink","warm"]),
        ("🍵", ["tea","green tea","relax","drink"]),
        ("🍺", ["beer","drink","celebrate","friday"]),
        ("🍕", ["pizza","food","lunch"]),
        ("🍎", ["apple","fruit","health","red"]),
        ("🍇", ["grape","fruit","purple"]),
        ("🎂", ["cake","birthday","celebrate"]),
        ("🍩", ["donut","sweet","treat"]),
        // Objects / tools / tech
        ("💡", ["idea","light","bright","bulb","insight"]),
        ("🔑", ["key","access","unlock","password","security"]),
        ("🔒", ["lock","secure","private","safety"]),
        ("🔓", ["unlock","open","access","release"]),
        ("🛠️", ["tool","fix","build","repair","wrench"]),
        ("⚙️", ["gear","setting","config","cog"]),
        ("🧩", ["puzzle","piece","integrate","fit"]),
        ("📦", ["box","package","ship","deliver"]),
        ("🗂️", ["folder","file","organize","category"]),
        ("📁", ["folder","files","directory"]),
        ("📂", ["open folder","files","browse"]),
        ("📝", ["note","write","edit","memo","task"]),
        ("📋", ["clipboard","copy","list","notes"]),
        ("📊", ["chart","graph","data","analytics"]),
        ("📈", ["chart up","growth","increase","trend"]),
        ("📉", ["chart down","decline","decrease","drop"]),
        ("🖥️", ["monitor","computer","desktop","screen"]),
        ("💻", ["laptop","computer","code","work"]),
        ("📱", ["phone","mobile","device","app"]),
        ("🖨️", ["printer","print","paper"]),
        ("⌨️", ["keyboard","type","input"]),
        ("🖱️", ["mouse","cursor","click"]),
        ("💾", ["floppy","save","disk","storage"]),
        ("💿", ["disc","cd","data"]),
        ("🔌", ["plug","power","connect","cable"]),
        ("🔋", ["battery","power","charge","energy"]),
        ("🧲", ["magnet","attract","pull","stick"]),
        ("⚡️", ["lightning","fast","electric","power","urgent"]),
        ("🔦", ["flashlight","torch","light","dark"]),
        ("🕯️", ["candle","light","soft","warm"]),
        // Mail / communication
        ("✉️", ["email","mail","letter","envelope","message"]),
        ("💌", ["love letter","mail","message","heart","email"]),
        ("📨", ["incoming","mail","email","receive","envelope"]),
        ("📩", ["outgoing","mail","email","send"]),
        ("📥", ["inbox","tray","mail","incoming","receive"]),
        ("📤", ["outbox","send","mail","out"]),
        ("📬", ["mailbox","mail","letter","post"]),
        ("📭", ["mailbox empty","empty","no mail"]),
        ("💬", ["chat","message","talk","comment","reply"]),
        ("💭", ["thought","bubble","thinking","idea"]),
        ("🗣️", ["speak","talk","voice","announce"]),
        ("📢", ["announce","megaphone","loud","broadcast"]),
        ("📣", ["cheer","megaphone","announce"]),
        ("🔔", ["bell","notification","alert","remind"]),
        ("🔕", ["no bell","mute","silent","quiet"]),
        ("📡", ["satellite","antenna","broadcast","signal"]),
        // Symbols / status / flags
        ("✅", ["check","done","complete","tick","yes","success"]),
        ("☑️", ["checkbox","check","done","tick"]),
        ("❌", ["cross","wrong","no","error","delete","cancel"]),
        ("⛔", ["stop","no","forbidden","block"]),
        ("🚫", ["forbidden","no","block","ban"]),
        ("⚠️", ["warning","caution","alert","attention"]),
        ("🚨", ["alert","alarm","urgent","emergency","siren"]),
        ("🛑", ["stop","halt","red","danger","block"]),
        ("💯", ["perfect","100","score","all","complete"]),
        ("🔴", ["red","dot","circle","stop","danger"]),
        ("🟠", ["orange","dot","circle","warning"]),
        ("🟡", ["yellow","dot","circle","caution"]),
        ("🟢", ["green","dot","circle","go","ok","success"]),
        ("🔵", ["blue","dot","circle","info"]),
        ("⭐️", ["star","favorite","highlight","important","rate"]),
        ("🌟", ["star","glow","shine","excellent"]),
        ("💫", ["sparkle","star","spin","dizzy"]),
        ("✨", ["sparkle","shine","magic","new","clean"]),
        ("🎯", ["target","goal","aim","focus","hit","bullseye"]),
        ("🚩", ["flag","mark","issue","problem","red flag"]),
        ("🏁", ["finish","done","complete","race","end"]),
        ("🏷️", ["tag","label","category","mark","price"]),
        ("🔖", ["bookmark","save","mark","page"]),
        ("📌", ["pin","mark","location","important","push pin"]),
        ("📍", ["pin","location","map","place","here"]),
        ("📎", ["clip","attach","paperclip","link","bind"]),
        ("🖇️", ["linked clips","attach","paperclips"]),
        ("🗝️", ["key","old","access","unlock","vintage"]),
        ("🪄", ["magic","wand","spell","transform"]),
        ("🎪", ["circus","event","show","fun"]),
        ("🎭", ["theater","drama","masks","performance"]),
        // Time / calendar
        ("⏳", ["hourglass","wait","time","pending","loading"]),
        ("⌛️", ["hourglass done","time up","wait","end"]),
        ("⏰", ["alarm","wake","ring","alert","time"]),
        ("⏱️", ["timer","stopwatch","measure","time","speed"]),
        ("⏲️", ["timer","clock","countdown"]),
        ("🕐", ["clock","one","time","hour"]),
        ("📅", ["calendar","date","schedule","plan","event"]),
        ("🗓️", ["calendar","date","planner","schedule"]),
        ("📆", ["calendar","date","event","day"]),
        // Activity / celebration / sports
        ("🎉", ["party","celebrate","confetti","hurray","fun"]),
        ("🎊", ["celebration","party","confetti","pop"]),
        ("🏆", ["trophy","win","award","champion","best"]),
        ("🥇", ["gold","medal","first","win","champion"]),
        ("🎖️", ["medal","honor","award","achievement"]),
        ("🎗️", ["ribbon","awareness","support","cause"]),
        ("🏅", ["medal","award","sport","compete"]),
        ("🎮", ["game","play","controller","fun","video"]),
        ("🧘", ["meditate","calm","yoga","relax","peace"]),
        ("🏃", ["run","fast","quick","jog","rush"]),
        ("🚀", ["rocket","launch","ship","fast","go","start","blast"]),
        ("🛸", ["ufo","alien","spaceship","fly"]),
        ("✈️", ["plane","travel","fly","trip","flight"]),
        ("🚂", ["train","commute","travel","rail"]),
        // Weather
        ("🌤️", ["partly cloudy","sun","cloud","weather"]),
        ("🌧️", ["rain","rainy","wet","weather","storm"]),
        ("⛈️", ["storm","thunder","lightning","rain","weather"]),
        ("🌈", ["rainbow","color","hope","bright","after storm"]),
        ("❄️", ["snow","cold","winter","freeze","chill"]),
        ("🔥", ["fire","hot","flame","trending","urgent","burn"]),
        ("💧", ["water","drop","rain","hydrate","blue"]),
        // Finance / work
        ("💰", ["money","cash","bag","rich","funds"]),
        ("💸", ["money","pay","spend","flying","cost","expense"]),
        ("💳", ["card","credit","pay","transaction"]),
        ("🧾", ["receipt","invoice","bill","payment","record"]),
        ("📜", ["scroll","document","contract","old","paper"]),
        ("📃", ["document","page","paper","sheet"]),
        ("📄", ["document","file","paper","page","text"]),
        ("💼", ["briefcase","work","business","office","job"]),
        ("🖊️", ["pen","write","sign","edit"]),
        ("✏️", ["pencil","draw","write","edit","sketch"]),
        ("📏", ["ruler","measure","straight","scale"]),
        ("🗑️", ["trash","delete","bin","remove","waste"]),
    ]

    private var results: [String] {
        if searchText.isEmpty { return Self.suggested }
        let q = searchText.lowercased()
        return Self.dataset.compactMap { entry in
            (entry.emoji.lowercased().contains(q) ||
             entry.keywords.contains(where: { $0.contains(q) })) ? entry.emoji : nil
        }
    }

    var body: some View {
        Button { open.toggle() } label: {
            Text(emoji.isEmpty ? "🏷️" : emoji)
                .font(.system(size: 16)).frame(width: 34, height: 30)
                .opacity(emoji.isEmpty ? 0.5 : 1)
        }
        .buttonStyle(.plain).help("Pick an emoji")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(Paper.ink4)
                    TextField("Search emoji", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Paper.ink)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Paper.sunken.opacity(0.32))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Paper.hairline.opacity(0.14), lineWidth: 0.5)))

                // Emoji grid
                let hits = results
                if hits.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink4)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(32), spacing: 3), count: 8),
                            spacing: 3
                        ) {
                            ForEach(hits, id: \.self) { e in
                                EmojiCell(e: e, selected: e == emoji) {
                                    emoji = e
                                    onChange?()
                                    open = false
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(12).frame(width: 300)
            .background(.ultraThickMaterial)   // system popover glass — stays consistent with native popovers
            .environment(\.colorScheme, .dark)
        }
        .onChange(of: open) { _, isOpen in
            if !isOpen { searchText = "" }
        }
    }
}

private struct EmojiCell: View {
    let e: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(e).font(.system(size: 19))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected
                            ? Paper.accent.opacity(0.30)
                            : hovering ? Paper.accent.opacity(0.12) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(selected ? Paper.accentSoft.opacity(0.55) : .clear, lineWidth: 1)
                )
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(Motion.pop, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// HSB colour state used by CuteColorPicker, derived from a hex string on popover open.
private struct HSBColor {
    var h: Double   // 0–360
    var s: Double   // 0–100
    var b: Double   // 0–100

    init(hex: String) {
        let c = Color(hex: hex)
        var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        NSColor(c).usingColorSpace(.deviceRGB)?.getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
        h = Double(hh) * 360; s = Double(ss) * 100; b = Double(bb) * 100
    }

    var color: Color { Color(hue: h / 360, saturation: s / 100, brightness: b / 100) }
    var hex: String { color.hexString() }
}

private struct CuteColorPicker: View {
    @Binding var hex: String
    var onChange: (() -> Void)? = nil
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            Circle().fill(Color(hex: hex)).frame(width: 22, height: 30)
                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.2))
                .padding(.horizontal, 5)
        }
        .buttonStyle(.plain).help("Tag colour")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ColorPickerPopover(hex: $hex, onChange: {
                onChange?()
                open = false
            })
        }
    }
}

// Fully in-app colour picker popover. Swatch grid + HSB sliders + live preview.
// No system NSColorPanel is opened.
private struct ColorPickerPopover: View {
    @Binding var hex: String
    let onChange: () -> Void

    // ponytail: @State ignores binding changes after first render, so we initialise
    // from hex on .onAppear and write back via onChange(of:) on every slider move.
    @State private var hsb = HSBColor(hex: "#5C6BC0")

    fileprivate static let palette = [
        "#4285F4", "#5C85C8", "#5C6BC0", "#7E67C2",
        "#A856B5", "#D45F8A", "#D45F5F", "#C85050",
        "#C87650", "#C8A050", "#8AB04A", "#4CA870",
        "#26A69A", "#29B6C0", "#5B8FAD", "#6D6D8C",
        "#8C8C8C", "#AAAAAA",
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Swatch grid
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 7), count: 6), spacing: 7) {
                ForEach(Self.palette, id: \.self) { p in
                    Swatch(hex: p, selected: p.caseInsensitiveCompare(hex) == .orderedSame) {
                        hex = p
                        hsb = HSBColor(hex: p)
                        onChange()
                    }
                }
            }

            // Hairline divider
            Rectangle().fill(Paper.hairline.opacity(0.14)).frame(height: 0.5)

            // HSB sliders
            VStack(spacing: 8) {
                HSBSliderRow(label: "H", value: $hsb.h, range: 0...360,
                             track: hueTrack())
                HSBSliderRow(label: "S", value: $hsb.s, range: 0...100,
                             track: satTrack())
                HSBSliderRow(label: "B", value: $hsb.b, range: 0...100,
                             track: briTrack())
            }
            .onChange(of: hsb.h) { _, _ in hex = hsb.hex }
            .onChange(of: hsb.s) { _, _ in hex = hsb.hex }
            .onChange(of: hsb.b) { _, _ in hex = hsb.hex }

            // Live preview chip
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hex: hex))
                    .frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.3), lineWidth: 0.75))
                Text(hex.uppercased())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Paper.ink3)
                    .frame(width: 64, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 224)
        .background(.ultraThickMaterial)   // system popover glass
        .environment(\.colorScheme, .dark)
        .onAppear { hsb = HSBColor(hex: hex) }
    }

    // Gradient tracks for the sliders — gives visual cues for hue/sat/bri.
    private func hueTrack() -> LinearGradient {
        LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1/12).map { h in
            Color(hue: h, saturation: 0.85, brightness: 0.9)
        }, startPoint: .leading, endPoint: .trailing)
    }
    private func satTrack() -> LinearGradient {
        LinearGradient(colors: [
            Color(hue: hsb.h / 360, saturation: 0, brightness: hsb.b / 100),
            Color(hue: hsb.h / 360, saturation: 1, brightness: hsb.b / 100),
        ], startPoint: .leading, endPoint: .trailing)
    }
    private func briTrack() -> LinearGradient {
        LinearGradient(colors: [
            Color(hue: hsb.h / 360, saturation: hsb.s / 100, brightness: 0),
            Color(hue: hsb.h / 360, saturation: hsb.s / 100, brightness: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}

private struct HSBSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let track: LinearGradient

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Paper.ink4)
                .frame(width: 10, alignment: .center)
            GeometryReader { geo in
                // Thumb travels within [0, width-12] so it never clips either end;
                // both track and thumb are vertically centred in the row.
                let frac = max(0, min(1, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(track)
                        .frame(height: 6)
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: (geo.size.width - 12) * frac)
                }
                .frame(height: 12, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    // Map the cursor to the thumb-centre travel range so the thumb
                    // tracks the pointer exactly across the full width.
                    let f = max(0, min(1, (drag.location.x - 6) / (geo.size.width - 12)))
                    value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                })
            }
            .frame(height: 12)
        }
    }
}


private struct Swatch: View {
    let hex: String; let selected: Bool; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Circle().fill(Color(hex: hex)).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0))
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                .scaleEffect(hover ? 1.18 : (selected ? 1.1 : 1))
                .shadow(color: Color(hex: hex).opacity(selected || hover ? 0.6 : 0), radius: 4, y: 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
                .animation(Motion.pop, value: selected)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// MARK: Learned-from-your-actions

private struct LearnedSection: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        let learned = (m.state?.learned ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("Learned from your actions",
                           "Built from your draft edits and what you restore. Delete anything that's off; it won't come back.")
            if learned.isEmpty {
                HStack(spacing: 13) {
                    Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(Paper.accentSoft)
                    Text("Nothing yet. As you edit drafts and restore threads, zero learns your voice and what matters to you here.")
                        .font(.system(size: 12.5)).foregroundStyle(Paper.ink3).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(Radius.card)
            } else {
                LearnedList(text: learned)
            }
        }
    }
}

// Parses the learned markdown into grouped, deletable items. Deleting suppresses an
// item on the server so it's never re-learned.
private struct LearnedList: View {
    @EnvironmentObject var m: KeeperModel
    let text: String

    private struct Item: Identifiable { let id = UUID(); let text: String; let heading: Bool }

    private var items: [Item] {
        var out: [Item] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(">") { continue }   // skip the preamble blockquote
            if line.hasPrefix("##") {                              // h2 → group heading
                let t = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(Item(text: t, heading: true)) }
            } else if line.hasPrefix("#") {                        // h1 title → skip (we show our own)
                continue
            } else {
                let t = (line.hasPrefix("- ") || line.hasPrefix("* ")) ? String(line.dropFirst(2)) : line
                let key = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty, !m.locallyRejected.contains(key) {
                    out.append(Item(text: t, heading: false))
                }
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                if item.heading {
                    Text(item.text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
                        .foregroundStyle(Paper.ink3)
                        .padding(.top, idx == 0 ? 0 : 10).padding(.horizontal, 2)
                } else {
                    LearnedItemRow(text: item.text)
                }
            }
        }
    }
}

private struct LearnedItemRow: View {
    @EnvironmentObject var m: KeeperModel
    let text: String
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Paper.accentSoft)
            Text(inline(text)).font(.system(size: 12.5)).foregroundStyle(Paper.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { m.rejectLearned(text) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Paper.danger : Paper.ink4)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Delete this — it won't be learned again")
            .accessibilityLabel("Delete learned preference")
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .glassSurface(11)
        .onHover { hovering = $0 }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

// MARK: - Reply composer

private struct ComposerView: View {
    @EnvironmentObject var m: KeeperModel
    @StateObject private var rich = RichTextController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            ZStack {
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
                    .glassSurface(8)
                    .overlay(alignment: .bottom) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }

                    // ponytail: RichTextEditor is always in the hierarchy so its NSTextView (and
                    // undo manager) survive composerLoading toggling and Regenerate. DraftingPlaceholder
                    // overlays on top while loading; allowsHitTesting(false) on the editor blocks input.
                    FormatBar(rich: rich).opacity(m.composerLoading ? 0 : 1)
                    ZStack {
                        RichTextEditor(controller: rich, seedText: m.composerText)
                            .frame(minHeight: 150)
                            .allowsHitTesting(!m.composerLoading)
                        if m.composerLoading {
                            DraftingPlaceholder()
                        }
                    }
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
                    .opacity(m.composerLoading ? 0 : 1)

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
                    .glassSurface(8)
                    .overlay(alignment: .top) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
                }

                // Moment 7: brief "sent" glass checkmark overlaid on the composer for ~0.8s
                // after the reply goes out, then the whole composer closes.
                if m.sentConfirmation {
                    SentConfirmationOverlay()
                        .transition(reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .glassSurface(14, tint: Color(0, 0, 0).opacity(0.5))   // real Liquid Glass, tinted dark enough to keep text legible
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Paper.hairline.opacity(0.2), Paper.hairline.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
            .padding(10)
            .animation(Motion.pop, value: m.sentConfirmation)
        }
    }
}

// Moment 7: a glass checkmark that blooms in over the composer while the sent
// state is live, then fades when the composer dismisses.
private struct SentConfirmationOverlay: View {
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Paper.clear.opacity(0.18))
                    .frame(width: 64, height: 64)
                    .glassSurface(32)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Paper.clear)
                    .scaleEffect(appeared ? 1 : 0.5)
            }
            Text("Sent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Paper.ink)
                .opacity(appeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface(14, tint: Color(0, 0, 0).opacity(0.35))   // matches composer glass, hides content beneath
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear {
            withAnimation(Motion.pop) { appeared = true }
        }
    }
}

// While the reply is being written, lines of "text" shimmer into place — the draft
// visibly materialising in your voice, rather than a bare spinner.
private struct DraftingPlaceholder: View {
    private let widths: [CGFloat] = [0.92, 0.74, 0.96, 0.58, 0.84]

    // ponytail: static pool; shuffle gives random-order cycling with no repeats at wrap
    private static let lines = [
        "Reading the whole thread…", "Finding your voice…", "Channeling your inner diplomat…",
        "Choosing words you'd actually say…", "Striking the right tone…", "Warming up the pleasantries…",
        "Deciding how formal to be…", "Reading between the lines…", "Matching your usual sign-off…",
        "Keeping it short, like you do…", "Resisting the urge to over-explain…",
        "Drafting something you won't rewrite…", "Sounding human, not corporate…",
        "Finding a polite way to say no…", "Getting to the point…", "Avoiding \"per my last email\"…",
        "Borrowing your turns of phrase…", "Calibrating the friendliness…",
        "Skipping the corporate jargon…", "Making it sound like you, not a bot…",
        "Checking who's actually asking…", "Finding the one thing they need…",
        "Trimming the throat-clearing…", "Adding just enough warmth…",
        "Deciding whether to say thanks…", "Keeping your reputation intact…",
        "Practising the perfect brevity…", "Reading the mood of the thread…",
        "Turning your thoughts into words…", "Almost ready for your eyes…",
    ]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deck: [String] = Self.lines.shuffled()
    @State private var idx: Int = 0

    private var currentLine: String { deck[idx] }

    private let ticker = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Paper.accentSoft)
                Text(currentLine)
                    .font(.system(size: 12.5)).foregroundStyle(Paper.ink3)
                    .lineLimit(1).truncationMode(.tail)
                    .id(currentLine)   // forces SwiftUI to re-render for transition
                    .transition(reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 5)),
                            removal:   .opacity.combined(with: .offset(y: -5))))
                    .animation(.easeOut(duration: 0.32), value: currentLine)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, w in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Paper.raised.opacity(0.07))
                        .frame(height: 11).frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: w, anchor: .leading)
                        .shimmer(radius: 4)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 178, alignment: .top)
        .onReceive(ticker) { _ in advance() }
    }

    private func advance() {
        let next = idx + 1
        if next >= deck.count {
            // reshuffle; avoid repeating the last shown line at the new front
            var fresh = Self.lines.shuffled()
            if fresh.first == deck.last { fresh = Array(fresh.dropFirst()) + [fresh.first!] }
            deck = fresh
            idx = 0
        } else {
            idx = next
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
                .glassSurface(6, interactive: true)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(a11y)
    }
}

// MARK: - Label cleanup

private struct CleanupView: View {
    @EnvironmentObject var m: KeeperModel
    @State private var confirming = false
    @State private var sortWindow = 30
    private var c: CleanupState? { m.cleanup }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 26)
            VStack(spacing: 0) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clean up labels").font(.system(size: 13, weight: .semibold))
                        Text(c?.email ?? "").font(.system(size: 11.5)).foregroundStyle(Paper.ink3).lineLimit(1)
                    }
                    Spacer()
                    Button { m.closeCleanup() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(Paper.ink3).accessibilityLabel("Close")
                }
                .padding(14).background(Paper.sunken.opacity(0.24))
                .overlay(alignment: .bottom) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }

                // Reassurance banner — always visible so users know what they're doing.
                HStack(spacing: 7) {
                    Image(systemName: "lock.shield").font(.system(size: 11)).foregroundStyle(Paper.accentSoft)
                    Text("Only labels are removed. Your mail is never deleted — every thread stays in All Mail.")
                        .font(.system(size: 11)).foregroundStyle(Paper.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Paper.accentSoft.opacity(0.06))
                .overlay(alignment: .bottom) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }

                // Body
                if c?.loading == true {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading labels…").font(.system(size: 12.5)).foregroundStyle(Paper.ink3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if let err = c?.error {
                    EmptyState(symbol: "exclamationmark.triangle", warn: true,
                               title: "Couldn't read labels", message: err).frame(minHeight: 200)
                } else if c?.labels.isEmpty ?? true {
                    EmptyState(symbol: "tag", warn: false, title: "No custom labels",
                               message: "This account only has Gmail's built-in labels — nothing to clean up.")
                        .frame(minHeight: 200)
                } else {
                    let total = c!.labels.count, sel = c!.selected.count
                    HStack {
                        Text("\(sel) of \(total) selected").font(.system(size: 11.5)).foregroundStyle(Paper.ink3)
                        Spacer()
                        Button(sel == total ? "Select none" : "Select all") { m.setAllCleanup(sel != total) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Paper.accentSoft)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(c!.labels) { label in
                                LabelCleanRow(label: label, selected: c!.selected.contains(label.id)) {
                                    m.toggleCleanup(label.id)
                                }
                            }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .frame(maxHeight: 280)
                }

                // Sort recent mail into category labels (label-only backfill — never
                // archives). Light: skips already-labeled + handled threads server-side.
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Paper.accentSoft)
                    Text("Sort the last").font(.system(size: 11.5)).foregroundStyle(Paper.ink3)
                    Picker("", selection: $sortWindow) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    Text("into labels").font(.system(size: 11.5)).foregroundStyle(Paper.ink3)
                    Spacer(minLength: 6)
                    Button {
                        guard let slug = c?.slug else { return }
                        m.populateLabels(slug: slug, windowDays: sortWindow)
                        m.closeCleanup()
                    } label: { Text("Sort recent mail") }
                    .buttonStyle(GhostButtonStyle()).disabled(m.isBusy)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }

                // Footer
                HStack(spacing: 9) {
                    Spacer(minLength: 0)
                    Button { confirming = true } label: {
                        HStack(spacing: 6) {
                            if c?.deleting == true { ProgressView().controlSize(.small).tint(.white) }
                            Text("Remove \(c?.selected.count ?? 0) label\((c?.selected.count ?? 0) == 1 ? "" : "s")")
                        }
                    }
                    .buttonStyle(DangerButtonStyle(enabled: (c?.selected.isEmpty == false) && c?.deleting != true))
                    .disabled((c?.selected.isEmpty ?? true) || c?.deleting == true)
                }
                .padding(12).background(Paper.sunken.opacity(0.24))
                .overlay(alignment: .top) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
            }
            .glassSurface(14, tint: Color(0, 0, 0).opacity(0.5))   // real Liquid Glass, tinted dark enough to keep text legible
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Paper.hairline.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.32), radius: 24, y: 10)
            .padding(10)
        }
        .confirmationDialog("Remove \(c?.selected.count ?? 0) label\((c?.selected.count ?? 0) == 1 ? "" : "s")?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove labels only", role: .destructive) { m.deleteCleanupSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only labels are removed. No mail is deleted — every thread stays in All Mail and can be found there any time.")
        }
    }
}

private struct LabelCleanRow: View {
    let label: LabelInfo
    let selected: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14)).foregroundStyle(selected ? Paper.accent : Paper.ink4)
                Text(label.name).font(.system(size: 12.5)).foregroundStyle(Paper.ink).lineLimit(1)
                if label.ours {
                    Text("app").font(.system(size: 9, weight: .semibold)).foregroundStyle(Paper.accentSoft)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Paper.accentSoft.opacity(0.16)))
                }
                if label.threads == 0 {
                    Text("empty").font(.system(size: 9, weight: .medium)).foregroundStyle(Paper.ink4)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Paper.hairline.opacity(0.12)))
                }
                Spacer(minLength: 6)
                if label.threads > 0 {
                    Text("\(label.threads)").font(.system(size: 11)).foregroundStyle(Paper.ink4).monospacedDigit()
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(selected ? Paper.accentSoft.opacity(0.10) : Paper.raised.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        HStack(spacing: 10) {
            // Moment 4: status text crossfades between idle copy and live job message.
            Text(statusText)
                .font(.system(size: 11.5)).foregroundStyle(m.isBusy ? Paper.accentSoft : Paper.ink3)
                .lineLimit(1).legibleOnGlass().frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.22), value: m.isBusy)

            // Moment 4: button morphs between "Run zero now" idle pill and a glass progress
            // pill while running — crossfade so there's no hard swap.
            Button { m.runKeeper() } label: {
                HStack(spacing: 6) {
                    if m.isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .transition(.opacity.combined(with: .scale(scale: 0.7)))
                    }
                    // The live progress message lives in the status line (left) only;
                    // the button just shows a short, fixed working label so the text
                    // never appears twice in this bar.
                    Text(m.isBusy ? "Working…" : "Run zero now")
                        .contentTransition(.opacity)
                }
                .animation(.easeOut(duration: 0.22), value: m.isBusy)
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !m.isBusy)).disabled(m.isBusy)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassSurface(0)
        .overlay(alignment: .top) { Rectangle().fill(Paper.hairline.opacity(0.1)).frame(height: 0.5) }
    }
    private var statusText: String {
        if m.isBusy { return m.job?.message ?? "Working…" }
        return "Tidies every inbox to only what needs you."
    }
}

// MARK: - Shared pieces

// A slim glass progress strip pinned at the top of the loops list while the keeper
// runs, so the inbox stays visible + scrollable instead of vanishing behind a
// full-screen takeover. The footer action bar carries the same message + spinner.
private struct TidyingBanner: View {
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(Paper.accentSoft).frame(width: 8, height: 8)
                .phaseAnimator(reduceMotion ? [1.0] : [0.45, 1.0]) { dot, o in
                    dot.opacity(o)
                } animation: { _ in .easeInOut(duration: 0.85) }
            Text(message).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Paper.accentSoft)
                .lineLimit(1).contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: message)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(9, tint: Paper.accent.opacity(0.12))
        .padding(.horizontal, 14).padding(.top, 12)
    }
}

private struct EmptyState: View {
    let symbol: String; let warn: Bool; let title: String; let message: String
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var tint: Color { warn ? Paper.danger : Paper.clear }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 60, height: 60)
                .background(
                    ZStack {
                        Circle().fill(tint.opacity(0.12))
                        // Reaching "all clear" is the milestone — a soft radial bloom
                        // rings out once behind the mark to mark the win.
                        if !warn {
                            Circle().fill(RadialGradient(colors: [tint.opacity(0.4), .clear],
                                                         center: .center, startRadius: 2, endRadius: 58))
                                .scaleEffect(appeared ? 1.9 : 0.2)
                                .opacity(appeared ? 0 : 0.9)
                                .blur(radius: 6).allowsHitTesting(false)
                        }
                    }
                )
                .scaleEffect((appeared || warn || reduceMotion) ? 1 : 0.6)
                .symbolEffect(.bounce, value: appeared)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(Paper.ink3)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        .onAppear {
            if reduceMotion { appeared = true } else { withAnimation(Motion.pop) { appeared = true } }
        }
    }
}

private struct Banner: View {
    let text: String; let error: Bool
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(error ? Paper.danger : Paper.ink2)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(10, tint: error ? Paper.danger.opacity(0.18) : Color.black.opacity(0.4))
            .padding(.horizontal, 14).padding(.top, 12)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.5)
            .foregroundStyle(Paper.ink4).legibleOnGlass().padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 4)
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

// MARK: - Starting state
// Shown during server boot (!serverReady) or while the server rebuilds state in
// the background (building=true). A calm, premium wait — Liquid Glass aesthetic,
// breathing icon, stage-appropriate copy. Never mistakes "loading" for "onboarding".
private struct StartingView: View {
    @EnvironmentObject var m: KeeperModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Pulsing ring that breathes behind the icon while we wait.
    @State private var ring = false

    private var isBuilding: Bool { m.serverReady && m.state?.building == true }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Breathing icon — same squircle as onboarding/top-bar, so the brand reads
            // consistently even during the wait. The ring pulses behind it.
            ZStack {
                // Soft radial glow that expands and fades on a slow loop.
                Circle()
                    .fill(RadialGradient(colors: [Paper.accent.opacity(0.28), .clear],
                                         center: .center, startRadius: 0, endRadius: 44))
                    .frame(width: 88, height: 88)
                    .scaleEffect(ring ? 1.45 : 0.85)
                    .opacity(ring ? 0 : 0.9)
                    .blur(radius: 4)

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Paper.accentHi, Paper.accent],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 56)
                    .overlay(Image(systemName: "checkmark")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(Color(0.99, 0.99, 1.0)))
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.75))
                    .shadow(color: Paper.accent.opacity(0.45), radius: 12, y: 4)
                    // ponytail: same breathing phase-animator as OnboardingView's icon
                    .phaseAnimator(reduceMotion ? [1.0] : [1.0, 1.028]) { v, s in v.scaleEffect(s) }
                        animation: { _ in .easeInOut(duration: 2.2) }
            }

            // Stage-aware copy: "Starting…" while unreachable, "Getting ready…" while building.
            Text("zero")
                .font(.system(size: 21, weight: .semibold)).kerning(-0.2)
                .legibleOnGlass()
                .padding(.top, 18)

            Text(isBuilding ? "Getting your inboxes ready…" : "Starting zero…")
                .font(.system(size: 13.5)).foregroundStyle(Paper.ink3)
                .legibleOnGlass()
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.3), value: isBuilding)
                .padding(.top, 6)

            // A slim glass activity line under the label — less aggressive than a full
            // spinner, just enough motion to show something is happening.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Paper.raised.opacity(0.07))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: [Paper.accentSoft.opacity(0.5), Paper.accent, Paper.accentSoft.opacity(0.5)],
                                              startPoint: .leading, endPoint: .trailing))
                        .frame(height: 3)
                        .shimmer(radius: 2, active: !reduceMotion)
                }
            }
            .frame(width: 120, height: 3)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ring = true }
        }
    }
}

private struct ToastView: View {
    let info: ToastInfo
    @State private var bounce = false
    // An action with an Undo is a set-aside; otherwise it's a confirmation.
    private var symbol: String { info.undo != nil ? "archivebox.fill" : "checkmark.circle.fill" }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(info.undo != nil ? Paper.accentSoft : Paper.clear)
                .symbolEffect(.bounce, value: bounce)
            Text(info.message).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            if let undo = info.undo {
                Button("Undo") { undo() }
                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Paper.accentSoft)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .frame(maxWidth: 320)
        // A slab of real glass (dark-tinted so white text stays crisp over anything
        // behind the panel), with the icon giving a little life on arrival.
        .glassSurface(16, tint: Color(0, 0, 0).opacity(0.55))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        .onAppear { bounce = true }
    }
}
