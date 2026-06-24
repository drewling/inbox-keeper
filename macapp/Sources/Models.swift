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

    enum K: String, CodingKey {
        case generatedAt, ok, totalLoops, needsBuild, failedAccounts, accounts, policy, learned
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
    }
}

struct Account: Decodable, Identifiable {
    var slug = ""
    var email = ""
    var short = ""
    var color = "#888888"
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
        case slug, email, short, color, ok, error, inboxThreads, unread, partial, loops, undoPoints
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        short = try c.decodeIfPresent(String.self, forKey: .short) ?? ""
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#888888"
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

    var id: String { threadId }

    enum K: String, CodingKey {
        case threadId, sender, senderEmail, subject, snippet, epoch, accountSlug
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
    }
    // Constructed locally for optimistic undo re-insertion.
    init(threadId: String, sender: String, senderEmail: String?, subject: String,
         snippet: String?, epoch: Int, accountSlug: String?) {
        self.threadId = threadId; self.sender = sender; self.senderEmail = senderEmail
        self.subject = subject; self.snippet = snippet; self.epoch = epoch; self.accountSlug = accountSlug
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
