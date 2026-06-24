// inbox-keeper — macOS menu-bar shell.
//
// Lives in the menu bar (no Dock icon). On launch it starts the local panel
// server (lib/keeper_server.py) and shows the web panel in a borderless floating
// window anchored under the menu-bar item. A custom window (rather than NSPopover)
// gives full control of the corner radius, shadow, and background, with no system
// arrow or edge material. Quitting terminates the server. The shell is thin: all
// UI is the web panel, all logic is the Python the rest of the repo already uses.

import AppKit
import WebKit

let PORT = ProcessInfo.processInfo.environment["KEEPER_PORT"] ?? "8765"
let PANEL_URL = URL(string: "http://127.0.0.1:\(PORT)/?app=1")!
let PANEL_W: CGFloat = 420
let PANEL_H: CGFloat = 640
let CORNER: CGFloat = 14

func resolveRepoRoot() -> String? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["MAIL_TRIAGE_DIR"],
       fm.fileExists(atPath: "\(env)/lib/keeper_server.py") { return env }
    let home = fm.homeDirectoryForCurrentUser.path
    let guess = "\(home)/mail-triage"
    if fm.fileExists(atPath: "\(guess)/lib/keeper_server.py") { return guess }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<6 {
        if fm.fileExists(atPath: dir.appendingPathComponent("lib/keeper_server.py").path) {
            return dir.path
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

// A generous PATH so a Finder-launched app can still find gws / node / python,
// mirroring config.sh (launchd & Finder give a minimal PATH otherwise).
func augmentedPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var parts = ["/opt/homebrew/bin", "/opt/homebrew/anaconda3/bin", "/usr/local/bin",
                 "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    let nvm = "\(home)/.nvm/versions/node"
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
        for e in entries.sorted().reversed() { parts.insert("\(nvm)/\(e)/bin", at: 0) }
    }
    if let existing = ProcessInfo.processInfo.environment["PATH"] { parts.append(existing) }
    return parts.joined(separator: ":")
}

final class AppController: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var panel: NSPanel!
    var server: Process?
    var webView: WKWebView!
    var loadRetries = 0
    var repoMissing = false
    var clickMonitor: Any?
    var escMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startServer()
        setupStatusItem()
        setupPanel()
    }

    func setupStatusItem() {
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "inbox-keeper")
            img?.isTemplate = true
            button.image = img
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    func setupPanel() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H), configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.wantsLayer = true
        webView.layer?.cornerRadius = CORNER
        webView.layer?.masksToBounds = true
        // Opaque paper fill so the rounded window has a clean solid edge and shadow.
        webView.setValue(true, forKey: "drawsBackground")

        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = webView
        panel.delegate = nil

        if repoMissing {
            showError("Can’t find the inbox-keeper folder",
                      "Set <code>MAIL_TRIAGE_DIR</code> to your clone, or put it at <code>~/mail-triage</code>. Looked for <code>lib/keeper_server.py</code>.")
        } else {
            loadPanel()
        }
    }

    func loadPanel() { webView.load(URLRequest(url: PANEL_URL)) }

    func showError(_ title: String, _ detail: String) {
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{height:100%}body{font:14px -apple-system,system-ui;color:#3a342e;
        background:#f7f3ec;margin:0;display:flex;align-items:center;justify-content:center;text-align:center}
        .b{max-width:300px;padding:24px}h2{font-size:17px;margin:0 0 8px}p{color:#7a7268;line-height:1.5}
        code{background:#ece6dc;padding:2px 5px;border-radius:4px;font-size:12px}</style></head>
        <body><div class="b"><h2>\(title)</h2><p>\(detail)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // The server may not be listening the instant the webview loads; retry briefly,
    // then surface the failure instead of leaving a blank panel.
    func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
        guard loadRetries < 25 else {
            showError("Couldn’t reach the panel",
                      "The local keeper server didn’t respond on port \(PORT). Try quitting and reopening, or run <code>./bin/inbox-keeper dashboard</code> from the repo.")
            return
        }
        loadRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.loadPanel() }
    }

    // Open external links (a tapped open-loop -> Gmail) in the user's real browser.
    func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, let host = url.host,
           host != "127.0.0.1", host != "localhost" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ wv: WKWebView, createWebViewWith config: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: - show / hide

    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        positionPanel()
        webView.reload()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Click outside the panel dismisses it, except a click on the status item
        // itself (the toggle action handles that, so we must not also hide here).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self = self else { return }
            if let button = self.statusItem.button, let bWin = button.window {
                let f = bWin.convertToScreen(button.convert(button.bounds, to: nil))
                if f.contains(NSEvent.mouseLocation) { return }
            }
            self.hidePanel()
        }
        // Escape closes the panel.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.hidePanel(); return nil }
            return e
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    // Anchor the panel just under the status item, right edge aligned, clamped to screen.
    func positionPanel() {
        guard let button = statusItem.button, let bWin = button.window else { return }
        let inScreen = bWin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bWin.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = inScreen.maxX - PANEL_W
        x = max(visible.minX + 8, min(x, visible.maxX - PANEL_W - 8))
        let y = inScreen.minY - PANEL_H - 6
        panel.setFrame(NSRect(x: x, y: y, width: PANEL_W, height: PANEL_H), display: true)
    }

    // Esc closes the panel (it's key while shown).
    func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) {}

    func startServer() {
        guard let root = resolveRepoRoot() else {
            repoMissing = true
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "\(root)/lib/keeper_server.py"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPath()
        env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
        env["KEEPER_PORT"] = PORT
        env["MAIL_TRIAGE_DIR"] = root
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        do {
            try p.run()
            server = p
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.showError("Couldn’t start the keeper server",
                                "Failed to launch python3: \(error.localizedDescription). Make sure Python 3 is installed.")
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        server?.terminate()
    }
}

// A borderless panel can still become key so the webview gets keyboard + Escape.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
