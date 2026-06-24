// inbox-keeper — macOS menu-bar app.
//
// Lives in the menu bar (no Dock icon). The panel is fully native SwiftUI hosted
// inside a real macOS 26 "Liquid Glass" surface (NSGlassEffectView) — not a web
// view, and not a hand-painted bitmap. The AppKit shell owns the status item, the
// borderless floating panel, and the local keeper server's lifecycle. A single
// long-lived KeeperModel backs the UI, so closing and reopening the panel never
// loses an in-progress run: it re-attaches to the live server-side job on open.

import AppKit
import SwiftUI

let PORT = ProcessInfo.processInfo.environment["KEEPER_PORT"] ?? "8765"
let PANEL_W: CGFloat = 420
let PANEL_H: CGFloat = 640
let CORNER: CGFloat = 17        // menu-surface corner radius
let ARROW_W: CGFloat = 26       // arrow base width
let ARROW_H: CGFloat = 10       // how far the arrow tip protrudes above the body
let ARROW_CLAMP: CGFloat = 32   // keep the arrow off the rounded top corners
let GAP: CGFloat = 5            // arrow tip to the menu bar

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

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Dark frosted surface for the panel — classic vibrancy (what Raycast-style panels
/// use), masked to a rounded body + upward arrow. Unlike NSGlassEffectView this has
/// no bright specular rim, so there's no hairline outline around the window.
final class GlassSurface: NSView {
    let effect = NSVisualEffectView()
    var arrowX: CGFloat = PANEL_W - 40 { didSet { if oldValue != arrowX { applyMask() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        effect.material = .hudWindow            // dark, translucent
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        applyMask()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private func bubblePath() -> NSBezierPath {
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: PANEL_H)
        let path = NSBezierPath(roundedRect: body, xRadius: CORNER, yRadius: CORNER)
        let cx = max(ARROW_CLAMP, min(arrowX, bounds.width - ARROW_CLAMP))
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: cx - ARROW_W / 2, y: PANEL_H - 1))
        tri.line(to: NSPoint(x: cx, y: PANEL_H + ARROW_H))
        tri.line(to: NSPoint(x: cx + ARROW_W / 2, y: PANEL_H - 1))
        tri.close()
        path.append(tri)
        return path
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyMask()
    }

    // Rasterize the bubble+arrow at the display's backing scale so the mask edge
    // stays crisp on Retina.
    private func applyMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let pw = Int((bounds.width * scale).rounded()), ph = Int((bounds.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        bubblePath().fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        effect.maskImage = img
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let model = KeeperModel(port: PORT)
    var panel: KeyablePanel!
    var glassSurface: GlassSurface?
    var server: Process?
    var repoMissing = false
    var clickMonitor: Any?
    var escMonitor: Any?

    func applicationDidFinishLaunching(_ note: Notification) {
        startServer()
        // Dev-only: KEEPER_PREVIEW renders the panel in a normal window for a
        // screenshot of the live glass material (the menu-bar popover is hidden
        // until clicked and can't be captured headlessly).
        if ProcessInfo.processInfo.environment["KEEPER_PREVIEW"] != nil {
            NSApp.setActivationPolicy(.regular)
            // Borderless, like the real panel, so the screenshot shows the true chrome
            // (arrow, rounded corners, shadow) — not a titlebar window.
            let total = NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H + ARROW_H)
            panel = KeyablePanel(contentRect: total, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .popUpMenu
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.contentView = makeGlassContent()
            setArrowX(PANEL_W - 40)
            if let vf = NSScreen.main?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: vf.minX + 140, y: vf.maxY - 40))
            }
            if let t = ProcessInfo.processInfo.environment["KEEPER_TAB"], let tab = Tab(rawValue: t) {
                model.tab = tab
            }
            panel.makeKeyAndOrderFront(nil)
            panel.invalidateShadow()
            NSApp.activate(ignoringOtherApps: true)
            model.onPanelOpen()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
    }

    /// Build the dark frosted surface (masked vibrancy, body + arrow) hosting the
    /// SwiftUI panel. The vibrancy is the surface; the SwiftUI content sits on top
    /// clipped to the rounded body.
    func makeGlassContent() -> NSView {
        let dark = NSAppearance(named: .darkAqua)
        let total = NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H + ARROW_H)
        let bodyRect = NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H)

        let surface = GlassSurface(frame: total)
        glassSurface = surface

        let hosting = NSHostingView(rootView: PanelView().environmentObject(model))
        hosting.frame = bodyRect
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        hosting.layer?.cornerRadius = CORNER
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        hosting.appearance = dark
        surface.addSubview(hosting)                   // content on top of the vibrancy
        return surface
    }

    func setArrowX(_ x: CGFloat) { glassSurface?.arrowX = x }

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
        let content = NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H + ARROW_H)
        let glass = makeGlassContent()

        panel = KeyablePanel(contentRect: content,
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
        panel.contentView = glass
    }

    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        removeMonitors()                    // never double-register (showPanel without a paired hide)
        positionPanel()
        model.onPanelOpen()                 // reload + re-attach to any live job (never reload-blow-away)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            guard let self = self else { return }
            if let button = self.statusItem.button, let bWin = button.window {
                let f = bWin.convertToScreen(button.convert(button.bounds, to: nil))
                if f.contains(NSEvent.mouseLocation) { return }  // toggle handles the item click
            }
            self.hidePanel()
        }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.hidePanel(); return nil }
            return e
        }
    }

    func hidePanel() {
        panel.orderOut(nil)
        removeMonitors()
    }

    func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    // Snug under the menu-bar item: the arrow tip sits just below the bar, pointing
    // at the item's centre; the window is clamped to the screen.
    func positionPanel() {
        guard let button = statusItem.button, let bWin = button.window else { return }
        let f = bWin.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (bWin.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let winH = PANEL_H + ARROW_H
        var originX = f.midX - (PANEL_W - 40)
        originX = max(visible.minX + 8, min(originX, visible.maxX - PANEL_W - 8))
        let originY = f.minY - GAP - winH
        setArrowX(f.midX - originX)                  // item centre in window coords
        panel.setFrame(NSRect(x: originX, y: originY, width: PANEL_W, height: winH), display: true)
        panel.invalidateShadow()                     // shadow follows the rounded glass silhouette
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
            repoMissing = true
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        server?.terminate()
    }
}

// Top-level entry runs on the main thread; assert that to the concurrency checker.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.run()
}
