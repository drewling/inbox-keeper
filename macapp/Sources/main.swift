// inbox-keeper — macOS menu-bar shell.
//
// Lives in the menu bar (no Dock icon). On launch it starts the local panel
// server (lib/keeper_server.py) and shows the web panel in a popover anchored
// under the menu-bar item. The popover's background is tinted to the panel's
// paper colour so the arrow matches the body. Quitting terminates the server.
// The shell is thin: all UI is the web panel, all logic is the Python the rest
// of the repo already uses.

import AppKit
import WebKit

let PORT = ProcessInfo.processInfo.environment["KEEPER_PORT"] ?? "8765"
let PANEL_URL = URL(string: "http://127.0.0.1:\(PORT)/?app=1")!
let PANEL_W: CGFloat = 420
let PANEL_H: CGFloat = 640
// Matches CSS --paper: oklch(98.6% 0.006 75).
let PAPER = NSColor(srgbRed: 0.974, green: 0.957, blue: 0.930, alpha: 1)

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

// A generous PATH so a Finder-launched app can still find gws / node / python.
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
    let popover = NSPopover()
    var server: Process?
    var webView: WKWebView!
    var loadRetries = 0
    var repoMissing = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        startServer()
        setupStatusItem()
        setupPopover()
    }

    func setupStatusItem() {
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "inbox-keeper")
            img?.isTemplate = true
            button.image = img
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    func setupPopover() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H), configuration: cfg)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Transparent so the popover's paper background (incl. the arrow) shows through.
        webView.setValue(false, forKey: "drawsBackground")
        let vc = NSViewController()
        vc.view = webView
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: PANEL_W, height: PANEL_H)
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .aqua)
        // Tint the whole popover (body + arrow) to the panel's paper colour. This is
        // a KVC-set background that NSPopover honours, giving a seamless arrow.
        popover.setValue(PAPER, forKey: "backgroundColor")

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
        background:transparent;margin:0;display:flex;align-items:center;justify-content:center;text-align:center}
        .b{max-width:300px;padding:24px}h2{font-size:17px;margin:0 0 8px}p{color:#7a7268;line-height:1.5}
        code{background:#ece6dc;padding:2px 5px;border-radius:4px;font-size:12px}</style></head>
        <body><div class="b"><h2>\(title)</h2><p>\(detail)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // The server may not be listening the instant the webview loads; retry briefly,
    // then surface the failure instead of leaving a blank popover.
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

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            webView.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

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

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
