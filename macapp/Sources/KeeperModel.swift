// KeeperModel.swift — the app's single source of truth. One instance is owned by
// AppController for the whole app lifetime, so it SURVIVES the panel closing and
// reopening. That's the fix for "run keeper, close, reopen → looks stopped": the
// run is a detached server-side job that never actually stopped; the old web panel
// just forgot it on reload. This model re-attaches to the live job on every open
// and keeps polling across hide, so the UI always reflects reality.

import SwiftUI
import AppKit

enum Tab: String, CaseIterable, Identifiable {
    case loops, accounts, undo, policy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .loops: return "Open loops"
        case .accounts: return "Accounts"
        case .undo: return "Undo"
        case .policy: return "Settings"
        }
    }
}

struct ToastInfo: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var undo: (() -> Void)?
    static func == (a: ToastInfo, b: ToastInfo) -> Bool { a.id == b.id }
}

@MainActor
final class KeeperModel: ObservableObject {
    @Published var state: AppState?
    @Published var job: Job?
    @Published var tab: Tab = .loops
    @Published var toastInfo: ToastInfo?
    @Published var policyDraft: String = ""
    // The editable categories, loaded once per open so in-progress edits aren't
    // clobbered by background reloads. state.categories stays the source for tags.
    @Published var categoriesDraft: [Category] = []
    @Published var categoriesSaving = false

    // Composer (one reply at a time).
    @Published var composer: LoopRow?
    @Published var composerText: String = ""
    @Published var composerSteer: String = ""
    @Published var composerLoading = false
    @Published var composerSending = false
    private var composerOriginal = ""
    private var composerToEmail = ""
    private var composerSubject = ""

    // First-run preflight: are the external CLIs the server shells out to present?
    struct Preflight: Equatable {
        var python = true, gws = true, claude = true, checked = false
        var allGood: Bool { python && gws && claude }
    }
    @Published var preflight = Preflight()

    let api: KeeperAPI
    private var pollTask: Task<Void, Never>?
    private var activeJobId = -1
    private var autoRanThisOpen = false
    private var toastToken = UUID()

    init(port: String) { api = KeeperAPI(port: port) }

    /// Show the welcome/setup takeover until at least one account is connected.
    var needsOnboarding: Bool {
        if ProcessInfo.processInfo.environment["KEEPER_ONBOARD"] == "1" { return true }  // dev/preview
        guard let s = state else { return false }   // nil → still loading (skeleton)
        return s.accounts.isEmpty
    }

    /// Check that python3 / gws / claude are on PATH so onboarding can tell the user
    /// exactly what's missing instead of failing cryptically on the first run.
    func runPreflight() {
        Task.detached(priority: .utility) {
            func has(_ bin: String) -> Bool {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = ["which", bin]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = augmentedPath()
                p.environment = env
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit() } catch { return false }
                return p.terminationStatus == 0
            }
            let pf = Preflight(python: has("python3"), gws: has("gws"),
                               claude: has("claude"), checked: true)
            await MainActor.run { self.preflight = pf }
        }
    }

    // MARK: derived state
    /// A full-inbox cleanup run is in flight — show the takeover "Tidying…" state.
    var isKeeping: Bool { job?.isRunning == true && job?.kind == "run" }
    /// Any background job is in flight — disable the action button.
    var isBusy: Bool { job?.isRunning == true }

    var loopRows: [LoopRow] {
        guard let s = state else { return [] }
        var rows: [LoopRow] = []
        for a in s.accounts where a.ok { for l in a.loops { rows.append(LoopRow(loop: l, account: a)) } }
        return rows.sorted { $0.loop.epoch > $1.loop.epoch }
    }

    // MARK: lifecycle

    /// Called when the panel becomes visible. Reloads state, then re-attaches to any
    /// live job so an in-progress run shows its real progress again.
    func onPanelOpen() {
        autoRanThisOpen = false
        runPreflight()
        Task {
            await reload()
            await loadCategories()
            await syncJob()
            maybeAutoRun()
        }
    }

    func reload() async {
        if let s = try? await api.state() {
            state = s
            if !s.needsBuild { policyDraft = s.policy }
        } else if state == nil {
            toast("Can’t reach the keeper server")
        }
    }

    /// Adopt whatever the server says about the current job. If it's running, make
    /// sure we're polling it — this is what survives a close/reopen.
    private func syncJob() async {
        guard let j = try? await api.job() else { return }
        if j.isRunning {
            activeJobId = j.id
            job = j
            ensurePolling()
        }
    }

    private func maybeAutoRun() {
        guard !autoRanThisOpen, !isBusy, let s = state, !s.needsBuild else { return }
        let age = Date().timeIntervalSince1970 - Double(s.generatedAt)
        if age > 1800, s.accounts.contains(where: { $0.ok }) {
            autoRanThisOpen = true
            runKeeper()
        }
    }

    // MARK: jobs

    func runKeeper() {
        beginJob(kind: "run", starting: "Starting…") { try await self.api.run() }
    }
    func undo(_ point: UndoPoint, slug: String) {
        beginJob(kind: "undo", starting: "Restoring…") { try await self.api.undo(slug: slug, label: point.label) }
    }
    func addAccount() {
        beginJob(kind: "add_account", starting: "Opening your browser…") { try await self.api.addAccount() }
    }

    private func beginJob(kind: String, starting: String, _ start: @escaping () async throws -> Int) {
        guard !isBusy else { toast("A keeper run is already going"); return }
        // Optimistic running state so the UI reacts instantly and can't flash "done".
        job = Job(id: -1, kind: kind, state: "running", message: starting)
        Task {
            do {
                let id = try await start()
                activeJobId = id
                if job?.id == -1 { job?.id = id }
                ensurePolling()
            } catch let KeeperAPI.KeeperError.http(code, _) where code == 409 {
                job = nil; toast("A keeper run is already going")
            } catch {
                job = nil; toast("Couldn’t start — check the server")
            }
        }
    }

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let j = try? await api.job() else { continue }   // transient: keep polling
            guard j.id == activeJobId else { continue }            // ignore stale snapshots
            job = j
            guard j.state == "done" || j.state == "error" else { continue }
            // Clear the handle BEFORE the async completion work: if the user taps Run
            // during finishJob()'s await, ensurePolling() (which gates on pollTask ==
            // nil) can then start a fresh loop for the new job instead of silently
            // no-op'ing and leaving the new run with no poller.
            pollTask = nil
            if j.state == "done" { await finishJob(j) } else { await failJob(j) }
            return
        }
        pollTask = nil
    }

    private func finishJob(_ j: Job) async {
        await reload()
        if j.kind != "refresh" { Haptic.tap() }   // a quiet confirmation on real completions
        let msg: String
        switch j.kind {
        case "run": msg = j.message.isEmpty ? "Inbox updated" : j.message
        case "add_account": msg = "Account added"
        case "undo": msg = "Restored"
        default: msg = "Updated"
        }
        toast(msg)
    }

    private func failJob(_ j: Job) async {
        await reload()
        let what = j.kind == "add_account" ? "Couldn’t add account" : "Run failed"
        toast(what + ": " + (j.error ?? "unknown"))
    }

    // MARK: set-aside (dismiss) + per-thread undo

    func dismiss(_ row: LoopRow) {
        let loop = row.loop, slug = row.account.slug
        if state != nil { state!.dropLoop(slug: slug, threadId: loop.threadId) }   // optimistic
        Task {
            do {
                let label = try await api.dismiss(loop, slug: slug)
                Haptic.tap()
                toast("Set aside") { [weak self] in self?.restoreThread(loop, slug: slug, label: label) }
                await reload()   // pull the server's bumped Undo bucket so the count moves now
            } catch {
                toast("Couldn’t set aside")
                await reload()
            }
        }
    }

    private func restoreThread(_ loop: Loop, slug: String, label: String) {
        if state != nil { state!.readdLoop(slug: slug, loop: loop) }
        Task {
            try? await api.restoreThread(loop, slug: slug, label: label)
            await reload()   // reflect the decremented Undo bucket
        }
    }

    // MARK: policy

    func savePolicy() {
        let text = policyDraft
        Task {
            do { try await api.savePolicy(text); state?.policy = text; toast("Policy saved") }
            catch { toast("Couldn’t save policy") }
        }
    }

    // MARK: categories

    /// Pull the editable list from disk. Skipped while saving so we don't clobber an
    /// in-flight edit with a stale read.
    func loadCategories() async {
        guard !categoriesSaving else { return }
        do { categoriesDraft = try await api.categories() }
        catch {
            // Don't clobber an in-memory edit, but surface a hard failure so an empty
            // editor isn't mistaken for "no categories".
            if categoriesDraft.isEmpty { toast("Couldn’t load categories") }
        }
    }

    func addCategory() {
        categoriesDraft.append(Category(name: "New category", description: "", color: "#5C6BC0", emoji: "🏷️"))
    }

    func removeCategory(_ id: UUID) {
        categoriesDraft.removeAll { $0.id == id }
    }

    /// Persist the categories. They feed the classifier on the next run and become
    /// Gmail labels on the threads they're assigned to.
    func saveCategories() {
        // Drop blank rows; a category with no name can't be a label.
        let clean = categoriesDraft
            .map { var c = $0; c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines); return c }
            .filter { !$0.name.isEmpty }
        categoriesSaving = true
        Task {
            defer { categoriesSaving = false }
            do {
                try await api.saveCategories(clean)
                categoriesDraft = clean
                state?.categories = clean
                toast("Categories saved — applied on the next run")
            } catch {
                toast("Couldn’t save categories")
            }
        }
    }

    // MARK: learned preferences

    /// Lines the user deleted this session — hidden immediately, before the server
    /// confirms, so the list reacts instantly.
    @Published var locallyRejected: Set<String> = []

    /// Delete a learned preference. The server suppresses it permanently so future
    /// runs never re-add it; we hide it optimistically and roll back on failure.
    func rejectLearned(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !locallyRejected.contains(key) else { return }
        locallyRejected.insert(key)
        Task {
            do { try await api.rejectLearned(key); toast("Removed — it won’t come back") }
            catch { locallyRejected.remove(key); toast("Couldn’t remove that") }
        }
    }

    // MARK: composer

    func openComposer(_ row: LoopRow) {
        guard composer == nil else { return }
        composer = row
        composerText = ""; composerSteer = ""; composerOriginal = ""
        composerToEmail = row.loop.senderEmail ?? ""
        composerSubject = row.loop.subject
        generateDraft(steer: "")
    }

    func closeComposer() { composer = nil; composerLoading = false; composerSending = false }

    func generateDraft(steer: String) {
        guard let row = composer else { return }
        composerLoading = true
        Task {
            defer { composerLoading = false }
            do {
                let d = try await api.draft(slug: row.account.slug, threadId: row.loop.threadId, steer: steer)
                guard let body = d.body, !body.isEmpty else { toast("Couldn’t draft a reply"); return }
                composerOriginal = body
                composerText = body
                if let e = d.toEmail, !e.isEmpty { composerToEmail = e }
                if let s = d.subject, !s.isEmpty { composerSubject = s }
            } catch is CancellationError {
            } catch {
                toast("Couldn’t draft — write one or try Regenerate")
            }
        }
    }

    func regenerate() {
        let steer = composerSteer.trimmingCharacters(in: .whitespacesAndNewlines)
        composerSteer = ""
        generateDraft(steer: steer)
    }

    func sendReply(plain: String, html: String) {
        guard let row = composer else { return }
        let text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { toast("Write a reply first"); return }
        let body = html.isEmpty ? Self.textToHTML(text) : html
        composerSending = true
        Task {
            do {
                try await api.send(slug: row.account.slug, threadId: row.loop.threadId,
                                   toEmail: composerToEmail, subject: composerSubject,
                                   body: text, html: body, original: composerOriginal)
                Haptic.tap()
                if state != nil { state!.dropLoop(slug: row.account.slug, threadId: row.loop.threadId) }
                closeComposer()
                toast("Reply sent")
            } catch {
                composerSending = false
                toast("Couldn’t send — check Gmail before retrying")
            }
        }
    }

    /// Plain reply text → simple paragraph HTML (blank lines split paragraphs,
    /// single newlines become <br>), matching what the server's send path expects.
    static func textToHTML(_ t: String) -> String {
        let esc = { (s: String) in s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;") }
        return t.components(separatedBy: "\n\n")
            .map { "<p>" + esc($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined()
    }

    // MARK: opening in Gmail

    func open(_ row: LoopRow) {
        let who = row.account.email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "https://mail.google.com/mail/?authuser=\(who)#all/\(row.loop.threadId)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: toast

    func toast(_ message: String, undo: (() -> Void)? = nil) {
        let info = ToastInfo(message: message, undo: undo)
        toastInfo = info
        let token = UUID(); toastToken = token
        let delay: UInt64 = undo == nil ? 2_600_000_000 : 4_500_000_000
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, self.toastToken == token else { return }
            if self.toastInfo?.id == info.id { self.toastInfo = nil }
        }
    }

    func dismissToast() { toastInfo = nil }
}

// Optimistic local mutations so counts + lists stay consistent without waiting for
// a full server rebuild (mirrors the old panel's dropLoop/readdLoop).
extension AppState {
    mutating func dropLoop(slug: String, threadId: String) {
        for i in accounts.indices where accounts[i].slug == slug {
            let before = accounts[i].loops.count
            accounts[i].loops.removeAll { $0.threadId == threadId }
            if accounts[i].loops.count < before {
                accounts[i].inboxThreads = max(0, accounts[i].inboxThreads - 1)
            }
        }
        recomputeTotal()
    }
    mutating func readdLoop(slug: String, loop: Loop) {
        for i in accounts.indices where accounts[i].slug == slug {
            if !accounts[i].loops.contains(where: { $0.threadId == loop.threadId }) {
                accounts[i].loops.insert(loop, at: 0)
                accounts[i].inboxThreads += 1
            }
        }
        recomputeTotal()
    }
    private mutating func recomputeTotal() {
        totalLoops = accounts.filter { $0.ok }.reduce(0) { $0 + $1.inboxThreads }
    }
}
