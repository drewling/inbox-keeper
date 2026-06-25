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

// Per-account label-cleanup sheet state.
struct CleanupState {
    let slug: String
    let email: String
    var labels: [LabelInfo] = []
    var selected: Set<String> = []   // selected label ids
    var loading = true
    var deleting = false
    var error: String?
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

    // Label cleanup sheet (one account at a time).
    @Published var cleanup: CleanupState?

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

    // Has the user configured a Google OAuth client yet? Defaults true so the
    // onboarding credential step never flashes before the check completes.
    @Published var hasClient = true

    // Timing: protect mail newer than N days (the keeper run honors this).
    @Published var graceDays: Int = 0
    // Schedule settings (loaded from server; defaults match server defaults).
    @Published var scheduleHour: Int = 7
    @Published var scheduleMinute: Int = 0
    @Published var scheduleDays: Set<Int> = [1, 2, 3, 4, 5]
    @Published var notifyOnRun: Bool = true
    @Published var autoDraft: Bool = false
    @Published var provider: String = "claude"
    // True while a just-switched provider is being re-verified against the server.
    @Published var verifyingProvider: Bool = false
    @Published var labelArchivedDays: Int = 30
    // Provider availability — fetched alongside settings on panel open.
    @Published var providerStatus: ProviderStatus?
    // Undo tab: emails under each recovery batch, loaded on demand. Keyed "slug|label".
    @Published var undoThreads: [String: [UndoThread]] = [:]
    @Published var undoLoading: Set<String> = []
    @Published var undoRestored: [String: Int] = [:]   // per-batch count restored this session
    // Open loops: read-in-place preview. Which rows are expanded + the fetched bodies,
    // both keyed by threadId so re-expanding never refetches.
    @Published var expandedLoops: Set<String> = []
    @Published var previews: [String: MessagePreview] = [:]
    @Published var previewLoading: Set<String> = []
    // First-run backlog offer: shown once after the first inbox connects.
    @Published var backlogOffered: Bool = UserDefaults.standard.bool(forKey: "backlogOffered")

    // ponytail: transient flags for delight moments — no persistence needed
    /// Pulses true briefly after a reload so the header can sweep a "fresh" sheen.
    @Published var refreshSheenToken: UUID = UUID()
    /// Set to true for ~0.8 s after a send succeeds so the composer can show a confirmation.
    @Published var sentConfirmation: Bool = false

    /// True once the server has responded to at least one /api/state call.
    /// Guards against showing onboarding or main UI while the server is still booting.
    @Published var serverReady = false

    let api: KeeperAPI
    private var pollTask: Task<Void, Never>?
    private var activeJobId = -1
    private var autoRanThisOpen = false
    private var toastToken = UUID()

    init(port: String) { api = KeeperAPI(port: port) }

    /// One-time first-run offer to clear the backlog, shown once after the first
    /// inbox connects (and never again once dismissed).
    var showBacklogStep: Bool {
        guard !backlogOffered, !needsOnboarding, let s = state else { return false }
        return s.accounts.contains { $0.ok }
    }

    /// Show the welcome/setup takeover until at least one account is connected.
    /// Returns false while the server is still booting or rebuilding state — prevents
    /// the premature onboarding flash when the server returns empty accounts mid-build.
    var needsOnboarding: Bool {
        if ProcessInfo.processInfo.environment["KEEPER_ONBOARD"] == "1" { return true }  // dev/preview
        // ponytail: gate on serverReady so a boot with empty accounts never flashes onboarding
        guard serverReady, let s = state, !(s.building ?? false) else { return false }
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
    /// A light, non-archiving job in flight (label backfill or backlog archive) —
    /// surfaced via the slim banner, never the full takeover.
    var isWorkingInline: Bool {
        job?.isRunning == true && (job?.kind == "populate" || job?.kind == "archive_before")
    }
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
            // If the server isn't ready yet, retry reaching it every 600 ms for up to
            // 25 attempts (~15 s). Only toast "Can't reach" once the budget is exhausted.
            // ponytail: loop capped at 25; no exponential back-off needed for a local server.
            if !serverReady {
                var attempts = 0
                while !serverReady && attempts < 25 {
                    if let s = try? await api.state() {
                        state = s
                        if !s.needsBuild { policyDraft = s.policy }
                        serverReady = true
                        refreshSheenToken = UUID()
                    } else {
                        attempts += 1
                        try? await Task.sleep(nanoseconds: 600_000_000)
                    }
                }
                if !serverReady {
                    toast("Can't reach the zero server")
                    return
                }
            } else {
                await reload()
            }
            await checkCredentials()
            await loadCategories()
            await loadSettings()
            await fetchProviderStatus()
            await syncJob()
            maybeAutoRun()
        }
    }

    /// Pull timing settings from the server (grace window + schedule + flags).
    func loadSettings() async {
        guard let s = try? await api.settings() else { return }
        graceDays = s.graceDays
        scheduleHour = s.scheduleHour
        scheduleMinute = s.scheduleMinute
        scheduleDays = Set(s.scheduleDays)
        notifyOnRun = s.notifyOnRun
        autoDraft = s.autoDraft
        provider = s.provider
        labelArchivedDays = s.labelArchivedDays
    }

    /// Persist the grace window; honored by the next keeper run.
    func saveGraceDays(_ n: Int) {
        graceDays = n
        Task {
            do { try await api.saveSettings(["grace_days": n]) }
            catch { toast("Couldn't save timing") }
        }
    }

    /// Persist schedule fields in one PUT, updating local state from the merged result.
    func saveSchedule() {
        let partial: [String: Any] = [
            "schedule_hour": scheduleHour,
            "schedule_minute": scheduleMinute,
            "schedule_days": Array(scheduleDays).sorted(),
        ]
        Task {
            do {
                let s = try await api.saveSettings(partial)
                scheduleHour = s.scheduleHour; scheduleMinute = s.scheduleMinute
                scheduleDays = Set(s.scheduleDays)
            } catch { toast("Couldn't save schedule") }
        }
    }

    func saveNotifyOnRun(_ v: Bool) {
        notifyOnRun = v
        Task {
            do { try await api.saveSettings(["notify_on_run": v]) }
            catch { toast("Couldn't save notification preference") }
        }
    }

    func saveAutoDraft(_ v: Bool) {
        autoDraft = v
        Task {
            do { try await api.saveSettings(["auto_draft": v]) }
            catch { toast("Couldn't save draft preference") }
        }
    }

    func saveLabelArchivedDays(_ n: Int) {
        labelArchivedDays = n
        Task {
            do { try await api.saveSettings(["label_archived_days": n]) }
            catch { toast("Couldn't save label setting") }
        }
    }

    /// Switch to a different AI provider. The server validates that it's available; a
    /// 400 means the provider isn't installed — surface that as a toast.
    func saveProvider(_ name: String) {
        guard name != provider else { return }
        let previous = provider
        provider = name
        verifyingProvider = true
        Task {
            do {
                let s = try await api.saveSettings(["provider": name])
                provider = s.provider
                // Re-verify: re-runs the server's CLI detection so the chip reflects
                // the newly selected engine's real availability and version.
                await fetchProviderStatus()
            } catch let KeeperAPI.KeeperError.http(_, msg) where !msg.isEmpty {
                provider = previous; toast(msg)
            } catch {
                provider = previous; toast("Couldn't switch provider")
            }
            verifyingProvider = false
        }
    }

    /// Refresh provider availability (e.g. user just installed a new CLI).
    func fetchProviderStatus() async {
        providerStatus = try? await api.providerStatus()
    }

    /// Whether a Google OAuth client is configured. Drives the onboarding credential
    /// step so a new user can set up Google access in-app instead of placing a file.
    func checkCredentials() async {
        if let s = try? await api.credentialsStatus() { hasClient = s.hasClient }
    }

    /// Onboarding sub-step: gws is installed but no Google OAuth client is set up yet.
    var needsCredentials: Bool { needsOnboarding && preflight.gws && !hasClient }

    /// Save the user's pasted client_secret.json, then reveal the connect step.
    func saveCredentials(_ json: String) {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { toast("Paste your client_secret.json first"); return }
        Task {
            do {
                try await api.setCredentials(json: text)
                hasClient = true
                toast("Google access set up — now connect your inbox")
            } catch let KeeperAPI.KeeperError.http(_, msg) where !msg.isEmpty {
                toast(msg)   // surface the server's specific guidance (bad paste, etc.)
            } catch {
                toast("Couldn't save those credentials")
            }
        }
    }

    /// Mark the one-time first-run backlog offer as seen so it never shows again.
    func dismissBacklog() {
        backlogOffered = true
        UserDefaults.standard.set(true, forKey: "backlogOffered")
    }

    func reload() async {
        if let s = try? await api.state() {
            state = s
            if !s.needsBuild { policyDraft = s.policy }
            serverReady = true   // mark ready on any successful response
            // Moment 9: bump the sheen token so observers can sweep a "fresh" highlight.
            refreshSheenToken = UUID()
        } else if state == nil {
            toast("Can't reach the zero server")
        }
        // If state != nil and we get a transient failure, stay silent (keep showing last-known state).
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
    /// Label-only backfill over the last `windowDays` for one account. Shows in the
    /// slim banner (not the full takeover) since it never archives.
    func populateLabels(slug: String, windowDays: Int) {
        beginJob(kind: "populate", starting: "Sorting recent mail…") {
            try await self.api.populateLabels(slug: slug, windowDays: windowDays)
        }
    }
    /// Reversibly archive everything before `before` (YYYY/MM/DD). `slug` nil = all.
    func archiveBefore(slug: String? = nil, before: String) {
        beginJob(kind: "archive_before", starting: "Clearing older mail…") {
            try await self.api.archiveBefore(slug: slug, before: before)
        }
    }
    func undo(_ point: UndoPoint, slug: String) {
        beginJob(kind: "undo", starting: "Restoring…") { try await self.api.undo(slug: slug, label: point.label) }
    }

    /// Expand/collapse a loop's inline preview, lazily fetching the body on first open.
    func togglePreview(_ row: LoopRow) {
        let tid = row.loop.threadId
        if expandedLoops.contains(tid) { expandedLoops.remove(tid); return }
        expandedLoops.insert(tid)
        guard previews[tid] == nil, !previewLoading.contains(tid) else { return }
        previewLoading.insert(tid)
        Task {
            let p = try? await api.threadPreview(slug: row.account.slug, threadId: tid)
            previews[tid] = p ?? MessagePreview(body: "", sender: row.loop.sender, subject: row.loop.subject)
            previewLoading.remove(tid)
        }
    }

    func undoKey(_ slug: String, _ label: String) -> String { slug + "|" + label }

    /// Lazily load the emails in one recovery batch (once). Idempotent.
    func loadUndoThreads(slug: String, label: String) {
        let key = undoKey(slug, label)
        guard undoThreads[key] == nil, !undoLoading.contains(key) else { return }
        undoLoading.insert(key)
        Task {
            let list = (try? await api.undoThreads(slug: slug, label: label)) ?? []
            undoThreads[key] = list
            undoLoading.remove(key)
        }
    }

    /// Un-archive a single email from a batch. Optimistic: drop the row immediately.
    func restoreThread(slug: String, label: String, thread: UndoThread) {
        let key = undoKey(slug, label)
        undoThreads[key]?.removeAll { $0.id == thread.id }
        undoRestored[key, default: 0] += 1
        Haptic.tap()
        Task {
            do { try await api.undoThread(slug: slug, label: label, id: thread.id, threadId: thread.threadId) }
            catch {
                // Put it back so the user isn't misled into thinking it was restored.
                undoThreads[key, default: []].append(thread)
                undoRestored[key, default: 0] -= 1
                toast("Couldn't restore that email")
            }
        }
    }
    func addAccount() {
        beginJob(kind: "add_account", starting: "Opening your browser…") { try await self.api.addAccount() }
    }

    private func beginJob(kind: String, starting: String, _ start: @escaping () async throws -> Int) {
        guard !isBusy else { toast("zero is already running"); return }
        // Optimistic running state so the UI reacts instantly and can't flash "done".
        job = Job(id: -1, kind: kind, state: "running", message: starting)
        Task {
            do {
                let id = try await start()
                activeJobId = id
                if job?.id == -1 { job?.id = id }
                ensurePolling()
            } catch let KeeperAPI.KeeperError.http(code, _) where code == 409 {
                job = nil; toast("zero is already running")
            } catch {
                job = nil; toast("Couldn't start — check the server")
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
        case "populate": msg = j.message.isEmpty ? "Labels updated" : j.message
        case "archive_before": msg = (j.message.isEmpty ? "Backlog cleared" : j.message) + " — undo any time"
        case "add_account": msg = "Account added"
        case "undo": msg = "Restored"
        default: msg = "Updated"
        }
        toast(msg)
        // A manual run just wrote its notification server-side; post it now so the
        // banner is immediate (scheduled runs are caught by the launch/timer drain).
        if j.kind == "run" { await drainPendingNotification() }
    }

    /// Pop any queued run notification from the server and post it as a native,
    /// app-owned banner (carries the app icon; tapping opens the panel on Open loops).
    func drainPendingNotification() async {
        guard let note = try? await api.pendingNotification() else { return }
        RunNotifier.post(title: note.title, body: note.body)
    }

    private func failJob(_ j: Job) async {
        await reload()
        if j.kind == "add_account" {
            // Refresh credential status: if the OAuth client is now missing, let the
            // CredentialsCard surface (needsCredentials → true) rather than toasting the
            // long setup wall. If the client IS present, show the server's short error.
            await checkCredentials()
            if !hasClient {
                // needsCredentials is now true → CredentialsCard shows automatically.
                return
            }
            // Server now returns a short error when the client is present.
            // Cap at 120 chars defensively so a multi-line message never floods the toast.
            let raw = j.error ?? "Sign-in failed"
            let msg = raw.count > 120 ? String(raw.prefix(117)) + "…" : raw
            toast("Couldn't add account: " + msg)
        } else {
            toast("Run failed: " + (j.error ?? "unknown"))
        }
    }

    // MARK: cancel job

    /// Cancel the currently running sign-in (or any job) and refresh state.
    func cancelJob() {
        Task {
            try? await api.cancelJob()
            job = nil   // optimistic clear
            await reload()
            await syncJob()
        }
    }

    // MARK: set-aside (dismiss) + per-thread undo

    func dismiss(_ row: LoopRow) {
        let loop = row.loop, slug = row.account.slug
        state?.dropLoop(slug: slug, threadId: loop.threadId)   // optimistic
        Task {
            do {
                let label = try await api.dismiss(loop, slug: slug)
                Haptic.tap()
                toast("Set aside") { [weak self] in self?.restoreThread(loop, slug: slug, label: label) }
                await reload()   // pull the server's bumped Undo bucket so the count moves now
            } catch {
                toast("Couldn't set aside")
                await reload()
            }
        }
    }

    private func restoreThread(_ loop: Loop, slug: String, label: String) {
        state?.readdLoop(slug: slug, loop: loop)
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
            catch { toast("Couldn't save policy") }
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
            if categoriesDraft.isEmpty { toast("Couldn't load categories") }
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
                toast("Couldn't save categories")
            }
        }
    }

    // MARK: label cleanup

    func openCleanup(_ a: Account) {
        cleanup = CleanupState(slug: a.slug, email: a.email)
        loadCleanupLabels()
    }
    func closeCleanup() { cleanup = nil }

    func loadCleanupLabels() {
        guard let slug = cleanup?.slug else { return }
        cleanup?.loading = true; cleanup?.error = nil
        Task {
            do {
                let labels = try await api.labels(slug: slug)
                guard cleanup?.slug == slug else { return }
                cleanup?.labels = labels
                cleanup?.selected = Set(labels.filter(\.ours).map(\.id))   // pre-check app-made labels
                cleanup?.loading = false
            } catch {
                guard cleanup?.slug == slug else { return }
                cleanup?.loading = false; cleanup?.error = "Couldn't load labels"
            }
        }
    }

    func toggleCleanup(_ id: String) {
        guard var sel = cleanup?.selected else { return }
        if sel.contains(id) { sel.remove(id) } else { sel.insert(id) }
        cleanup?.selected = sel
    }
    func setAllCleanup(_ on: Bool) {
        guard let labels = cleanup?.labels else { return }
        cleanup?.selected = on ? Set(labels.map(\.id)) : []
    }

    /// Delete the selected labels. Reversible-safe: this removes labels only, never
    /// mail. Refreshes the sheet + state afterwards (counts/undo points can shift).
    func deleteCleanupSelected() {
        guard let c = cleanup, !c.selected.isEmpty, !c.deleting else { return }
        let slug = c.slug, ids = Array(c.selected)
        cleanup?.deleting = true
        Task {
            defer { cleanup?.deleting = false }
            do {
                let r = try await api.deleteLabels(slug: slug, ids: ids)
                Haptic.tap()
                if cleanup?.slug == slug, let labels = try? await api.labels(slug: slug) {
                    cleanup?.labels = labels
                    cleanup?.selected = Set(labels.filter(\.ours).map(\.id))
                }
                await reload()
                toast(r.failed == 0 ? "Removed \(r.deleted) label\(r.deleted == 1 ? "" : "s")"
                                    : "Removed \(r.deleted), \(r.failed) failed")
            } catch {
                toast("Couldn't delete labels")
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
            do { try await api.rejectLearned(key); toast("Removed — it won't come back") }
            catch { locallyRejected.remove(key); toast("Couldn't remove that") }
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
                guard let body = d.body, !body.isEmpty else { toast("Couldn't draft a reply"); return }
                composerOriginal = body
                composerText = body
                if let e = d.toEmail, !e.isEmpty { composerToEmail = e }
                if let s = d.subject, !s.isEmpty { composerSubject = s }
            } catch is CancellationError {
            } catch {
                toast("Couldn't draft — write one or try Regenerate")
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
                state?.dropLoop(slug: row.account.slug, threadId: row.loop.threadId)
                // Moment 7: show the sent checkmark briefly, then close.
                sentConfirmation = true
                try? await Task.sleep(nanoseconds: 800_000_000)
                sentConfirmation = false
                closeComposer()
                toast("Reply sent")
            } catch {
                composerSending = false
                toast("Couldn't send — check Gmail before retrying")
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
