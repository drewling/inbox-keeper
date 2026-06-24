// Models.swift — the keeper server's JSON contract, as Swift value types, plus a
// small async HTTP client. The Python keeper server (lib/keeper_server.py) remains
// the engine that does the real Gmail work; this is the native app's view of it.
//
// The server serves snake_case JSON; we decode with .convertFromSnakeCase so the
// Swift properties stay idiomatic camelCase.

import Foundation

// MARK: - Wire types

// NOTE: these use explicit init(from:) with decodeIfPresent rather than synthesized
// Decodable. Swift's synthesized Decodable treats a stored-property default as a
// REQUIRED key (it does not fall back to the default when the key is absent), so a
// missing field like `needs_build` in the normal state payload would throw and the
// whole decode would fail. decodeIfPresent gives us the lenient behavior we want.

struct AppState: Decodable {
    var generatedAt = 0
    var ok = false
    var totalLoops = 0
    var needsBuild = false
    var failedAccounts: [String] = []
    var accounts: [Account] = []
    var policy = ""
    var learned = ""
    var categories: [Category] = []

    enum K: String, CodingKey {
        case generatedAt, ok, totalLoops, needsBuild, failedAccounts, accounts, policy, learned, categories
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        generatedAt = try c.decodeIfPresent(Int.self, forKey: .generatedAt) ?? 0
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        totalLoops = try c.decodeIfPresent(Int.self, forKey: .totalLoops) ?? 0
        needsBuild = try c.decodeIfPresent(Bool.self, forKey: .needsBuild) ?? false
        failedAccounts = try c.decodeIfPresent([String].self, forKey: .failedAccounts) ?? []
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        policy = try c.decodeIfPresent(String.self, forKey: .policy) ?? ""
        learned = try c.decodeIfPresent(String.self, forKey: .learned) ?? ""
        categories = try c.decodeIfPresent([Category].self, forKey: .categories) ?? []
    }

    /// Look up a category by name (case-insensitive) so a loop's tag can pull its
    /// colour + emoji from the authoritative list.
    func category(named name: String?) -> Category? {
        guard let name, !name.isEmpty else { return nil }
        return categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// A user-defined bucket the keeper sorts open loops into. Editable in Settings,
// passed to the classifier, and applied as a real Gmail label ("<emoji> <name>").
struct Category: Decodable, Identifiable, Equatable {
    var name = ""
    var description = ""
    var color = "#5C6BC0"
    var emoji = "🏷️"
    // Stable editor identity: the row keeps the same id while you retype its name,
    // so the text field doesn't lose focus on every keystroke. Not part of the wire.
    let uid = UUID()

    var id: UUID { uid }

    enum K: String, CodingKey { case name, description, color, emoji }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#5C6BC0"
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji) ?? "🏷️"
    }
    init(name: String, description: String = "", color: String = "#5C6BC0", emoji: String = "🏷️") {
        self.name = name; self.description = description; self.color = color; self.emoji = emoji
    }

    static func == (a: Category, b: Category) -> Bool {
        a.name == b.name && a.description == b.description && a.color == b.color && a.emoji == b.emoji
    }

    /// The wire shape the server's PUT /api/categories expects.
    var json: [String: Any] { ["name": name, "description": description, "color": color, "emoji": emoji] }
}

struct Account: Decodable, Identifiable {
    var slug = ""
    var email = ""
    var short = ""
    var color = "#888888"
    var photoURL: String?
    var ok = false
    var error: String?
    var inboxThreads = 0
    var unread = 0
    var partial = 0
    var loops: [Loop] = []
    var undoPoints: [UndoPoint] = []

    var id: String { slug }
    /// Threads the user has reversibly set aside, summed across restore points.
    var archivedCount: Int { undoPoints.reduce(0) { $0 + $1.count } }

    enum K: String, CodingKey {
        case slug, email, short, color
        // .convertFromSnakeCase maps "photo_url" → "photoUrl" (lowercase rl), not
        // "photoURL", so the key must be spelled the way the strategy produces it.
        case photoURL = "photoUrl"
        case ok, error, inboxThreads, unread, partial, loops, undoPoints
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        short = try c.decodeIfPresent(String.self, forKey: .short) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#888888"
        photoURL = try c.decodeIfPresent(String.self, forKey: .photoURL)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
        inboxThreads = try c.decodeIfPresent(Int.self, forKey: .inboxThreads) ?? 0
        unread = try c.decodeIfPresent(Int.self, forKey: .unread) ?? 0
        partial = try c.decodeIfPresent(Int.self, forKey: .partial) ?? 0
        loops = try c.decodeIfPresent([Loop].self, forKey: .loops) ?? []
        undoPoints = try c.decodeIfPresent([UndoPoint].self, forKey: .undoPoints) ?? []
    }
}

struct Loop: Decodable, Identifiable {
    var threadId = ""
    var sender = ""
    var senderEmail: String?
    var subject = ""
    var snippet: String?
    var epoch = 0
    var accountSlug: String?
    var category: String?

    var id: String { threadId }

    enum K: String, CodingKey {
        case threadId, sender, senderEmail, subject, snippet, epoch, accountSlug, category
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        threadId = try c.decodeIfPresent(String.self, forKey: .threadId) ?? ""
        sender = try c.decodeIfPresent(String.self, forKey: .sender) ?? ""
        senderEmail = try c.decodeIfPresent(String.self, forKey: .senderEmail)
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        snippet = try c.decodeIfPresent(String.self, forKey: .snippet)
        epoch = try c.decodeIfPresent(Int.self, forKey: .epoch) ?? 0
        accountSlug = try c.decodeIfPresent(String.self, forKey: .accountSlug)
        category = try c.decodeIfPresent(String.self, forKey: .category)
    }
    // Constructed locally for optimistic undo re-insertion.
    init(threadId: String, sender: String, senderEmail: String?, subject: String,
         snippet: String?, epoch: Int, accountSlug: String?, category: String? = nil) {
        self.threadId = threadId; self.sender = sender; self.senderEmail = senderEmail
        self.subject = subject; self.snippet = snippet; self.epoch = epoch; self.accountSlug = accountSlug
        self.category = category
    }
}

struct UndoPoint: Decodable, Identifiable {
    var label = ""
    var date = ""
    var count = 0

    var id: String { label }

    enum K: String, CodingKey { case label, date, count }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
    }
}

struct Job: Decodable {
    var id = 0
    var kind: String?
    var state = "idle"     // idle | running | done | error
    var started = 0
    var finished = 0
    var message = ""
    var error: String?

    var isRunning: Bool { state == "running" }

    enum K: String, CodingKey { case id, kind, state, started, finished, message, error }
    init() {}
    init(id: Int, kind: String?, state: String, message: String) {
        self.id = id; self.kind = kind; self.state = state; self.message = message
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id) ?? 0
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        started = try c.decodeIfPresent(Int.self, forKey: .started) ?? 0
        finished = try c.decodeIfPresent(Int.self, forKey: .finished) ?? 0
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

// One Gmail label in the per-account cleanup sheet. `ours` marks labels inbox-keeper
// created (recovery points, category tags, legacy taxonomy) so they can be pre-checked.
struct LabelInfo: Decodable, Identifiable {
    var id = ""
    var name = ""
    var threads = 0
    var ours = false

    enum K: String, CodingKey { case id, name, threads, ours }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? 0
        ours = try c.decodeIfPresent(Bool.self, forKey: .ours) ?? false
    }
}

// User-controllable timing settings (persisted server-side in app/settings.json).
struct Settings: Decodable {
    var graceDays: Int = 0
    enum K: String, CodingKey { case graceDays }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        graceDays = try c.decodeIfPresent(Int.self, forKey: .graceDays) ?? 0
    }
}

// A loop flattened with its owning account, for the unified "waiting on you" list.
struct LoopRow: Identifiable {
    let loop: Loop
    let account: Account
    var id: String { account.slug + "/" + loop.threadId }
}

// Replies the draft endpoint returns / the send endpoint consumes.
struct Draft: Decodable {
    var ok: Bool = false
    var toName: String?
    var toEmail: String?
    var subject: String?
    var body: String?
    var error: String?
}

// MARK: - API client

/// Thin async wrapper over the local keeper server. All calls are best-effort and
/// throw `KeeperError` on transport/decoding failure so callers can surface a toast.
struct KeeperAPI {
    let base: URL

    init(port: String) {
        base = URL(string: "http://127.0.0.1:\(port)")!
    }

    enum KeeperError: Error { case unreachable, http(Int, String), badData }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: reads
    func state() async throws -> AppState { try await get("/api/state") }
    func job() async throws -> Job { try await get("/api/job") }

    // MARK: jobs (202 + {"job": id})
    @discardableResult func run() async throws -> Int { try await startJob("/api/run", ["grace_days": 0]) }
    @discardableResult func undo(slug: String, label: String) async throws -> Int {
        try await startJob("/api/undo", ["slug": slug, "label": label])
    }
    @discardableResult func addAccount() async throws -> Int { try await startJob("/api/add-account", [:]) }
    @discardableResult func refresh() async throws -> Int { try await startJob("/api/refresh", [:]) }

    /// Label-only backfill: sort the last `windowDays` of inbox mail into categories.
    /// `slug` nil = all accounts. Never archives.
    @discardableResult func populateLabels(slug: String?, windowDays: Int) async throws -> Int {
        var body: [String: Any] = ["window_days": windowDays]
        if let slug { body["slug"] = slug }
        return try await startJob("/api/labels/populate", body)
    }

    /// Reversibly archive inbox mail before `before` (YYYY/MM/DD). `slug` nil = all.
    @discardableResult func archiveBefore(slug: String?, before: String) async throws -> Int {
        var body: [String: Any] = ["before": before]
        if let slug { body["slug"] = slug }
        return try await startJob("/api/archive-before", body)
    }

    // MARK: synchronous mutations
    func dismiss(_ loop: Loop, slug: String) async throws -> String {
        let body: [String: Any] = [
            "slug": slug, "thread_id": loop.threadId, "sender": loop.sender,
            "sender_email": loop.senderEmail ?? "", "subject": loop.subject,
            "snippet": loop.snippet ?? "", "epoch": loop.epoch,
        ]
        let r = try await postRaw("/api/dismiss", body)
        return (r["label"] as? String) ?? ""
    }

    func restoreThread(_ loop: Loop, slug: String, label: String) async throws {
        let body: [String: Any] = [
            "undo": true, "slug": slug, "label": label, "thread_id": loop.threadId,
            "sender": loop.sender, "sender_email": loop.senderEmail ?? "",
            "subject": loop.subject, "snippet": loop.snippet ?? "", "epoch": loop.epoch,
        ]
        _ = try await postRaw("/api/dismiss", body)
    }

    func draft(slug: String, threadId: String, steer: String) async throws -> Draft {
        try await post("/api/draft", ["slug": slug, "thread_id": threadId, "steer": steer], timeout: 135)
    }

    func send(slug: String, threadId: String, toEmail: String, subject: String,
              body: String, html: String, original: String) async throws {
        _ = try await postRaw("/api/draft/send", [
            "slug": slug, "thread_id": threadId, "to_email": toEmail, "subject": subject,
            "body": body, "html": html, "original": original,
        ], timeout: 60)
    }

    func savePolicy(_ policy: String) async throws {
        _ = try await sendJSON("/api/policy", method: "PUT", body: ["policy": policy])
    }

    /// The user's editable categories. Read separately from /api/state so the editor
    /// always reflects the on-disk list even when state is mid-rebuild.
    func categories() async throws -> [Category] {
        struct Wrap: Decodable { var categories: [Category] = [] }
        let w: Wrap = try await get("/api/categories")
        return w.categories
    }

    func saveCategories(_ cats: [Category]) async throws {
        _ = try await sendJSON("/api/categories", method: "PUT", body: ["categories": cats.map(\.json)])
    }

    /// Timing settings (grace window). Read/written server-side.
    func settings() async throws -> Settings { try await get("/api/settings") }
    func saveSettings(graceDays: Int) async throws {
        _ = try await sendJSON("/api/settings", method: "PUT", body: ["grace_days": graceDays])
    }

    /// Delete a learned preference and suppress it so it's never re-learned.
    func rejectLearned(_ text: String) async throws {
        _ = try await sendJSON("/api/learned/reject", method: "POST", body: ["text": text])
    }

    // MARK: label cleanup

    /// Every user label on an account, with thread counts; `ours` flags app-made ones.
    func labels(slug: String) async throws -> [LabelInfo] {
        struct Wrap: Decodable { var labels: [LabelInfo] = []; var error: String? }
        var comps = URLComponents(url: base.appendingPathComponent("/api/labels"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "slug", value: slug)]
        var req = URLRequest(url: comps.url!); req.timeoutInterval = 30
        let data = try await fetch(req)
        guard let w = try? Self.decoder.decode(Wrap.self, from: data) else { throw KeeperError.badData }
        return w.labels
    }

    /// Delete the given labels. Returns (deleted, failed). Mail is never deleted.
    @discardableResult
    func deleteLabels(slug: String, ids: [String]) async throws -> (deleted: Int, failed: Int) {
        let r = try await postRaw("/api/labels/delete", ["slug": slug, "ids": ids], timeout: 60)
        return ((r["deleted"] as? Int) ?? 0, (r["failed"] as? [Any])?.count ?? 0)
    }

    // MARK: - plumbing

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval = 12) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = timeout
        let data = try await fetch(req)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw KeeperError.badData }
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval = 20) async throws -> T {
        let data = try await sendJSON(path, method: "POST", body: body, timeout: timeout)
        do { return try Self.decoder.decode(T.self, from: data) }
        catch { throw KeeperError.badData }
    }

    @discardableResult
    private func postRaw(_ path: String, _ body: [String: Any], timeout: TimeInterval = 20) async throws -> [String: Any] {
        let data = try await sendJSON(path, method: "POST", body: body, timeout: timeout)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func startJob(_ path: String, _ body: [String: Any]) async throws -> Int {
        let r = try await postRaw(path, body)
        return (r["job"] as? Int) ?? 0
    }

    private func sendJSON(_ path: String, method: String, body: [String: Any], timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await fetch(req)
    }

    private func fetch(_ req: URLRequest) async throws -> Data {
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw KeeperError.unreachable }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Surface the server's {"error": ...} message when present.
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? ""
            throw KeeperError.http(http.statusCode, msg)
        }
        return data
    }
}
