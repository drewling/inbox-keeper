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
            if m.needsOnboarding {
                OnboardingView()
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
                    .font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color(0.99, 0.99, 1.0)))
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
                    Text(account.inboxThreads > 99 ? "99+" : "\(account.inboxThreads)")
                        .font(.system(size: 9.5, weight: .bold)).foregroundStyle(Paper.ink)
                        .monospacedDigit()
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
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if on {
                                // A real Liquid-Glass pill that flows between tabs — it
                                // looks like a single blob of glass migrating, catching
                                // light, rather than a box snapping position.
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Paper.raised.opacity(0.10))
                                    .glassSurface(7)
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
            // The count rolls digit-by-digit when something is set aside or a run
            // finishes — the inbox visibly getting lighter.
            Text("\(total)").font(.system(size: 46, weight: .bold)).foregroundStyle(Paper.accent).kerning(-1)
                .contentTransition(.numericText(value: Double(total)))
                .animation(Motion.settle, value: total)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { m.open(row) }

            Text(relTime(row.loop.epoch)).font(.system(size: 11)).foregroundStyle(Paper.ink4)

            HStack(spacing: 2) {
                RowAction(symbol: "arrowshape.turn.up.left", help: "Draft a reply") { m.openComposer(row) }
                RowAction(symbol: "archivebox", help: "Set aside (reversible)") {
                    withAnimation(Motion.sweep) { m.dismiss(row) }
                }
            }
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(hovering ? Paper.raised.opacity(0.08) : .clear))
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
                    Text("Nothing is ever deleted. Each point restores a day’s set-aside threads back to the inbox in one tap.")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink3)
                        .padding(.horizontal, 4).padding(.bottom, 4)
                    // Key on position: an undo point's label/date can repeat across
                    // accounts, so \.point.id alone collides and SwiftUI duplicates rows.
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
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

// MARK: - Settings (keep policy · categories · learned)

private struct PolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                KeepPolicySection()
                CategoriesSection()
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
            SettingsHeader("What to keep",
                           "Describe what counts as “still needs me” in plain English. The agent reads every thread and enforces it.")
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

// MARK: Categories editor

private struct CategoriesSection: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("Categories",
                           "Buckets the keeper sorts your open loops into. Each becomes a Gmail label and a tag on the list. They pass to the agent on the next run.")
            VStack(spacing: 8) {
                ForEach($m.categoriesDraft) { $cat in
                    CategoryEditRow(cat: $cat) { m.removeCategory(cat.id) }
                }
            }
            HStack(spacing: 10) {
                Button { withAnimation(.snappy(duration: 0.25)) { m.addCategory() } } label: {
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

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: cat.color) }, set: { cat.color = $0.hexString() })
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Emoji, framed in the category's own colour so the row reads as a chip.
            TextField("🏷️", text: $cat.emoji)
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .font(.system(size: 15)).frame(width: 30, height: 30)
                .background(Circle().fill(Color(hex: cat.color).opacity(0.20)))
                .overlay(Circle().strokeBorder(Color(hex: cat.color).opacity(0.5), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name", text: $cat.name)
                    .textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Paper.ink)
                TextField("When should the keeper use this?", text: $cat.description)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Paper.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden().frame(width: 22)
                .help("Tag colour")

            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Paper.danger : Paper.ink4)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityLabel("Delete category")
        }
        .padding(10)
        .glassSurface(11)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}

// MARK: Learned-from-your-actions

private struct LearnedSection: View {
    @EnvironmentObject var m: KeeperModel
    var body: some View {
        let learned = (m.state?.learned ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 10) {
            SettingsHeader("Learned from your actions",
                           "Built from your draft edits and what you restore. Delete anything that’s off; it won’t come back.")
            if learned.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Paper.accentSoft)
                    Text("Nothing yet. As you edit drafts and restore threads, the keeper learns your voice and what matters to you here.")
                        .font(.system(size: 12)).foregroundStyle(Paper.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(11)
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
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items) { item in
                if item.heading {
                    Text(item.text.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6)
                        .foregroundStyle(Paper.ink3).padding(.top, 8).padding(.horizontal, 2)
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
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "sparkle").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Paper.accentSoft).padding(.top, 1)
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
            .buttonStyle(.plain).help("Delete this — it won’t be learned again")
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
                    DraftingPlaceholder()
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

// While the reply is being written, lines of "text" shimmer into place — the draft
// visibly materialising in your voice, rather than a bare spinner.
private struct DraftingPlaceholder: View {
    private let widths: [CGFloat] = [0.92, 0.74, 0.96, 0.58, 0.84]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Paper.accentSoft)
                Text("Drafting in your voice…").font(.system(size: 12.5)).foregroundStyle(Paper.ink3)
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
        VStack(spacing: 16) {
            BreathingOrb()
            Text("Tidying your inboxes").font(.system(size: 17, weight: .semibold))
            Text(message).font(.system(size: 12.5)).foregroundStyle(Paper.accent)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// A soft glass orb that breathes while the keeper works — calmer and more alive than
// a system spinner, and unmistakably the same glass as the rest of the panel.
private struct BreathingOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().fill(Paper.accentHi.opacity(0.20)).blur(radius: 7)
            Image(systemName: "tray.full").font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Paper.accentSoft)
        }
        .frame(width: 66, height: 66)
        .glassSurface(33)
        .phaseAnimator(reduceMotion ? [1.0] : [0.95, 1.06]) { view, scale in
            view.scaleEffect(scale).opacity(scale < 1 ? 0.9 : 1)
        } animation: { _ in .easeInOut(duration: 1.15) }
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
