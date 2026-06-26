// zero — macOS menu-bar app.
//
// Lives in the menu bar (no Dock icon). The panel is fully native SwiftUI hosted
// inside a real macOS 26 "Liquid Glass" surface (NSGlassEffectView) — not a web
// view, and not a hand-painted bitmap. The AppKit shell owns the status item, the
// borderless floating panel, and the local keeper server's lifecycle. A single
// long-lived KeeperModel backs the UI, so closing and reopening the panel never
// loses an in-progress run: it re-attaches to the live server-side job on open.

import AppKit
import SwiftUI
import UserNotifications
import Carbon.HIToolbox   // RegisterEventHotKey — global shortcut without Accessibility permission

let PORT = ProcessInfo.processInfo.environment["KEEPER_PORT"] ?? "8765"
let PANEL_W: CGFloat = 420
let PANEL_H: CGFloat = 640
let CORNER: CGFloat = 17        // menu-surface corner radius
let ARROW_W: CGFloat = 44       // arrow base width (wide raised-cosine ogee = gentle, smooth join)
let ARROW_H: CGFloat = 11       // how far the arrow tip protrudes above the body
let ARROW_CLAMP: CGFloat = 42   // keep the arrow (incl. its wide base) off the rounded top corners
let GAP: CGFloat = 5            // arrow tip to the menu bar

func resolveRepoRoot() -> String? {
    let fm = FileManager.default
    // Dev opt-in: run straight from a source checkout when explicitly pointed at one.
    if let env = ProcessInfo.processInfo.environment["MAIL_TRIAGE_DIR"],
       fm.fileExists(atPath: "\(env)/lib/keeper_server.py") { return env }
    // A packaged app must NOT auto-grab a source checkout by guessing home-dir paths:
    // that path may be inside ~/Documents, which macOS TCC blocks for the app's helper
    // processes (and the daily LaunchAgent). We only use a source tree when the binary
    // is being run from *inside* one (walk up from the executable — the dev build case);
    // otherwise we seed the bundle into Application Support (not TCC-protected) and run
    // from there. That makes a downloaded .dmg behave identically for every user.
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<6 {
        if fm.fileExists(atPath: dir.appendingPathComponent("lib/keeper_server.py").path) {
            // Don't auto-run from a source checkout that lives inside a TCC-protected
            // folder (~/Documents, ~/Desktop, ~/Downloads). The server reads and writes
            // repo files (logs, state, learning, drafts) on every launch and on the
            // daily LaunchAgent run — doing that inside ~/Documents triggers the macOS
            // "zero would like to access your Documents folder" prompt every time.
            // Seed into Application Support instead (not TCC-protected). A dev who wants
            // live source from such a location can still force it via MAIL_TRIAGE_DIR.
            if isInTCCProtectedDir(dir.path) { break }
            return dir.path
        }
        dir = dir.deletingLastPathComponent()
    }
    // Packaged .app (or a checkout inside a protected folder): seed the bundled
    // runtime into a writable support dir and run from there.
    return seedFromBundle()
}

/// True if `path` is inside one of the macOS TCC-gated home folders, where any
/// file access pops the per-folder privacy prompt.
private func isInTCCProtectedDir(_ path: String) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let protected = ["\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads"]
    let p = URL(fileURLWithPath: path).standardized.path
    return protected.contains { p == $0 || p.hasPrefix($0 + "/") }
}

/// Application Support location the packaged app runs from. The code lives in the
/// bundle (read-only, replaced on update); the running copy + all user data live
/// here so updates never clobber accounts, policy, learning, or state.
func supportDirURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/zero", isDirectory: true)
}

/// Append a timestamped breadcrumb to ~/Library/Logs/zero-launch.log. Launch is the
/// one place we can't debug on someone else's Mac: if the app ever "runs but shows
/// nothing", this file says exactly how far startup got (and whether it was running
/// translocated / from a quarantined copy). Truncated at the start of each launch so
/// it only ever holds the most recent run. ponytail: a handful of lines per launch.
func launchLog(_ msg: String, reset: Bool = false) {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/zero-launch.log")
    let line = Data("\(Date()) \(msg)\n".utf8)
    if reset { try? line.write(to: url); return }
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
    } else {
        try? line.write(to: url)
    }
}

/// First run = no connected account yet. accounts.json is written only after the
/// user connects an inbox; seedFromBundle never creates it (only the .example). Read
/// the file directly so we can decide at launch, before the server is up.
func hasConnectedAccount() -> Bool {
    let url = supportDirURL().appendingPathComponent("accounts.json")
    guard let data = try? Data(contentsOf: url),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return false }
    return !arr.isEmpty
}

/// Copy the bundled `Contents/Resources/payload` into the support dir. Pure code is
/// refreshed every launch (so updates apply); user-editable files are seeded only
/// when missing; user data (accounts, learning, drafts, logs, state) is never touched.
private func seedFromBundle() -> String? {
    let fm = FileManager.default
    guard let res = Bundle.main.resourceURL else { return nil }
    let payload = res.appendingPathComponent("payload", isDirectory: true)
    guard fm.fileExists(atPath: payload.appendingPathComponent("lib/keeper_server.py").path) else { return nil }
    let support = supportDirURL()
    // One-time migration from the pre-rename support dir, so existing users keep
    // their accounts, policy, learning, and state across the inbox-keeper→zero rename.
    let legacy = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/inbox-keeper", isDirectory: true)
    if !fm.fileExists(atPath: support.path), fm.fileExists(atPath: legacy.path) {
        try? fm.moveItem(at: legacy, to: support)
    }
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)

    func overwrite(_ rel: String) {
        let src = payload.appendingPathComponent(rel), dst = support.appendingPathComponent(rel)
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        try? fm.copyItem(at: src, to: dst)
    }
    func seedIfMissing(_ rel: String) {
        let dst = support.appendingPathComponent(rel)
        guard !fm.fileExists(atPath: dst.path) else { return }
        let src = payload.appendingPathComponent(rel)
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.copyItem(at: src, to: dst)
    }
    // Code + templates — safe to refresh (never user data). knowledge: only the template.
    ["lib", "bin", "config.py", "config.sh",
     "accounts.json.example", "knowledge/profile.example.md"].forEach(overwrite)
    // User-editable — seed once, then leave their edits alone.
    ["keep-policy.md", "categories.json"].forEach(seedIfMissing)

    return fm.fileExists(atPath: support.appendingPathComponent("lib/keeper_server.py").path)
        ? support.path : nil
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
///
/// SEAM FIX: The beak shares the same mask + vibrancy as the body, but the SwiftUI
/// graphite gradient overlay (in PanelView) only covers the body rect. Without a
/// matching tint the beak shows as raw hudWindow vibrancy — lighter and distinctly
/// different from the dark header just below it. We paint a matching graphite gradient
/// CAGradientLayer directly over the beak region so the beak reads as one continuous
/// surface with the header. The body gradient is intentionally excluded (the SwiftUI
/// layer covers that area) so we don't double-tint the body.
final class GlassSurface: NSView {
    let effect = NSVisualEffectView()
    var arrowX: CGFloat = PANEL_W - 40 { didSet { if oldValue != arrowX { applyMask() } } }

    // ONE gradient tints the whole surface — body AND beak — so the two are the same
    // shade by construction. This replaces the old split where the body was tinted by a
    // SwiftUI gradient and the beak by a separate CALayer: those two sources could never
    // be matched, so the beak always read as a lighter cap with a seam at the join.
    // Masked to the body+beak silhouette, it sits behind the (transparent) SwiftUI content.
    private let tint = CAGradientLayer()
    private let tintMask = CALayer()
    private let tintHost = NSView()   // hosts `tint` as a subview so it composites ABOVE the vibrancy

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

        // Uniform graphite across the whole surface (body + beak). This tint MUST sit
        // ABOVE the vibrancy: AppKit composites subview layers above any manually added
        // sublayers, so `layer.addSublayer(tint)` buried the tint UNDER the vibrancy and
        // the blurred backdrop spilled over it — the panel went near-transparent over a
        // white window and solid over a dark one, and raising the alpha barely helped
        // because the vibrancy was on top. Hosting `tint` in a subview added after
        // `effect` puts it above the vibrancy (and below the content), so the alpha now
        // actually governs how much backdrop shows. ~0.88 reads as a consistent dark
        // glass over any backdrop while a sliver of vibrancy still shimmers through.
        // sRGB to match SwiftUI Color().
        let graphite = CGColor(srgbRed: 0.135, green: 0.132, blue: 0.127, alpha: 0.88)
        tint.colors = [graphite, graphite]
        tint.mask = tintMask
        tintHost.wantsLayer = true
        tintHost.frame = bounds
        tintHost.autoresizingMask = [.width, .height]
        tintHost.layer?.addSublayer(tint)
        addSubview(tintHost)            // after `effect` → renders above the vibrancy

        applyMask()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private func bodyPath() -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: PANEL_H),
                     xRadius: CORNER, yRadius: CORNER)
    }

    /// A smooth "beak", not a triangle: a raised-cosine bump (`h·½(1+cos πt)`) whose
    /// flanks leave the flat top edge with a horizontal tangent, dip through concave
    /// shoulders, and curve over a softly rounded apex — so the arrow flows *out* of
    /// the body instead of rising from a kink. Sampled as a fine polyline; it's
    /// rasterised into the mask anyway, so a curve beats fiddly Bézier control points.
    /// Filled separately from the body (see applyMask) so the two never cancel.
    private func beakPath() -> NSBezierPath {
        let cx = max(ARROW_CLAMP, min(arrowX, bounds.width - ARROW_CLAMP))
        let w = ARROW_W / 2, h = ARROW_H, y0 = PANEL_H - 2   // base sits just inside the body
        let beak = NSBezierPath()
        let steps = 120
        beak.move(to: NSPoint(x: cx - w, y: y0))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) * 2 - 1       // -1 … 1
            beak.line(to: NSPoint(x: cx + t * w, y: y0 + h * 0.5 * (1 + cos(.pi * t))))
        }
        beak.line(to: NSPoint(x: cx + w, y: y0))
        beak.close()
        return beak
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyMask()
    }

    override func layout() {
        super.layout()
        applyMask()
    }

    // Rasterize the body+beak silhouette at the display's backing scale (crisp on Retina)
    // and use it to mask BOTH the vibrancy and the tint gradient — one shape, one shade.
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
        // Two separate fills = union by overpaint. Appending the beak to the body as
        // one path made their overlap cancel under nonzero winding, leaving a white
        // slit at the join — the "not smooth" seam between box and arrow.
        bodyPath().fill()
        beakPath().fill()
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: bounds.size)
        img.addRepresentation(rep)
        effect.maskImage = img
        // The same silhouette masks the tint gradient, so body+beak read as one
        // continuous shade with no seam. No implicit animation on resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tint.frame = bounds
        tintMask.frame = bounds
        tintMask.contents = img
        CATransaction.commit()
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // Created in applicationDidFinishLaunching, NOT here. Building the status item in
    // a property initializer means it's made before the app finishes launching /
    // registers with the status bar, which can leave the icon invisible even though
    // the app runs fine. Create it once the app is up, on the main thread.
    static weak var shared: AppController?
    var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    let model = KeeperModel(port: PORT)
    var panel: KeyablePanel!
    var glassSurface: GlassSurface?
    var server: Process?
    var repoMissing = false
    var clickMonitor: Any?
    var escMonitor: Any?
    var notifDrainTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        Self.shared = self
        launchLog("didFinishLaunching: bundle=\(Bundle.main.bundlePath) id=\(Bundle.main.bundleIdentifier ?? "nil") translocated=\(Bundle.main.bundlePath.contains("/AppTranslocation/"))", reset: true)
        // Dev-only: KEEPER_PREVIEW renders the panel in a normal window for a
        // screenshot of the live glass material (the menu-bar popover is hidden
        // until clicked and can't be captured headlessly).
        if ProcessInfo.processInfo.environment["KEEPER_PREVIEW"] != nil {
            startServer()
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
        // Menu-bar path: put the icon on screen FIRST, before any disk work. On a
        // fresh install startServer() copies the whole bundled payload into
        // Application Support (seedFromBundle) — synchronous file IO that must never
        // delay or hide the status item. So we set up the UI, then boot the server
        // off the main thread. The model already polls the server with retries on
        // panel open, so the icon never waits on the server coming up.
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPanel()
        setupNotifications()
        registerGlobalHotkey()
        // Displays connecting/disconnecting/rearranging can strand the status item on a
        // gone display. Re-assert it so it comes back on an active screen.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        startServerAsync()
        launchLog("didFinishLaunching: setup complete")

        // First-run safety net: a brand-new user's only UI is the menu-bar icon. With
        // multiple displays the icon lands on whichever screen is active (often not the
        // one you're looking at), and macOS gives no way to pin it. Pop the onboarding
        // panel on the screen under the mouse so first launch is always visible and
        // setup is reachable regardless of where the icon went.
        if !hasConnectedAccount() { showPanelWhenIconReady() }
    }

    /// The status item's on-screen frame, but ONLY once macOS has actually placed it
    /// in the menu bar. Before layout the button window sits at the origin (~0,0) —
    /// bottom-left — which still has a real width and "intersects a screen", so a
    /// width/intersection test passes on garbage. A placed menu-bar item lives in the
    /// top band of its screen, so require its top to be up at the menu bar. Returns
    /// nil while unplaced, so callers never anchor the panel to a bogus origin frame
    /// (which clamps to the bottom-left corner — the "random place on first launch" bug).
    func placedIconFrame() -> NSRect? {
        guard let button = statusItem?.button, let bWin = button.window,
              let screen = bWin.screen else { return nil }
        let f = bWin.convertToScreen(button.convert(button.bounds, to: nil))
        guard f.width > 1,
              f.maxY >= screen.frame.maxY - NSStatusBar.system.thickness - 4 else { return nil }
        return f
    }

    /// First-run auto-open: applicationDidFinishLaunching fires before the menu-bar
    /// icon is laid out, so opening the panel synchronously anchors it to a stale
    /// frame and it lands in a random spot. Wait runloop turns for a real (placed)
    /// icon frame, then open under it. After ~1.5s open regardless — positionPanel
    /// then falls back to the top-right, so the panel always appears somewhere sane.
    func showPanelWhenIconReady(attempt: Int = 0) {
        if placedIconFrame() != nil || attempt >= 30 {
            launchLog("showPanelWhenIconReady: opening at attempt=\(attempt) iconFrame=\(placedIconFrame().map { "(midX=\(Int($0.midX)),maxY=\(Int($0.maxY)))" } ?? "nil")")
            showPanel(on: screenUnderMouse())
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.showPanelWhenIconReady(attempt: attempt + 1)
            }
        }
    }

    /// ⌥⌘Z toggles the panel from anywhere — the reliable way in when the menu-bar
    /// icon is on another display or hidden. Carbon RegisterEventHotKey needs no
    /// Accessibility permission (a global NSEvent key monitor would).
    private func registerGlobalHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { AppController.shared?.toggleFromHotkey() }
            return noErr
        }, 1, &eventType, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5A45524F) /* 'ZERO' */, id: 1)
        let mods = UInt32(optionKey | cmdKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_Z), mods, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        launchLog("registerGlobalHotkey: ⌥⌘Z status=\(status)")
    }

    // Re-opening the app from Finder/Spotlight (the natural move when you can't find
    // the menu-bar icon) re-shows the panel instead of silently doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(on: screenUnderMouse())
        return true
    }

    // MARK: notifications

    /// Own notifications at the app level so they carry the app icon and a tap
    /// opens the panel on Open loops. Runs drop a one-shot via the server; we drain
    /// it on launch, on a light timer (catches scheduled runs while idle), and the
    /// model also drains the instant a manual run finishes.
    private func setupNotifications() {
        // UNUserNotificationCenter.current() throws an *uncatchable* ObjC exception when
        // there's no valid bundle proxy (nil bundle id / odd launch context), which would
        // kill the app right after the icon goes up. Guard the precondition so a
        // notification hiccup can never abort launch or take the menu-bar icon down.
        guard Bundle.main.bundleIdentifier != nil else {
            launchLog("setupNotifications: skipped (no bundle identifier)")
            return
        }
        UNUserNotificationCenter.current().delegate = self
        RunNotifier.requestAuthorization()
        launchLog("setupNotifications: done")
        Task { await model.drainPendingNotification() }
        notifDrainTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.model.drainPendingNotification() }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])   // show even though we're a menu-bar app
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            self.model.tab = .loops
            self.showPanel(on: self.screenUnderMouse())   // pop on the display the user is on
            completionHandler()
        }
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

        // focusEffectDisabled: kill the blue keyboard-focus ring that macOS otherwise
        // paints on whichever button becomes first responder (the panel keeps auto-
        // focusing the primary CTA, so it looks "pre-selected"). This is a mouse-driven
        // popover, not a keyboard-nav surface, so the ring only ever reads as a bug.
        let hosting = NSHostingView(rootView: PanelView().environmentObject(model).focusEffectDisabled())
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
        // Canonical menu-bar setup: create the item HERE (in didFinishLaunching), never
        // as a property initializer — building it before app.run() races the status-bar
        // server and is the classic "runs fine, no icon" bug.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // autosaveName gives the slot a stable identity across relaunches. NOTE: macOS
        // (Control Center) persists a per-app "NSStatusItem Visible" flag keyed by the
        // app's *bundle id*. If that flag ever gets stuck at 0 — e.g. a first-launch
        // crash loop, or the user ⌘-dragging the icon off the bar — EVERY status item
        // this bundle id creates is force-hidden forever, regardless of code (this is the
        // long-standing "no icon" bug; verified by bisection — a fresh bundle id renders
        // instantly while com.drewling.zero stayed hidden). The escape was the bundle-id
        // change in Info.plist. isVisible=true reasserts our intent each launch.
        statusItem.autosaveName = "zeroMenuBar"
        statusItem.isVisible = true
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "zero") {
                img.isTemplate = true
                button.image = img
            } else {
                // Fallback so the item is never zero-width (= invisible) if the SF
                // Symbol can't be loaded — a menu-bar app with no image and no title
                // renders nothing at all.
                button.title = "zero"
            }
            button.action = #selector(statusItemClicked)
            button.target = self
            // Receive both mouse-up events so we can distinguish right-click.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            launchLog("setupStatusItem: created, button.image=\(button.image != nil) title=\(button.title) visible=\(statusItem.isVisible)")
        } else {
            launchLog("setupStatusItem: created but NO BUTTON")
        }
        // One concise placement line once the bar has laid out — the only ground truth
        // for a headless app's "no icon" reports (notch / wrong display / not placed).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let b = self.statusItem?.button
            let w = b?.window
            launchLog("probe: isActive=\(NSApp.isActive) screens=\(NSScreen.screens.count) thickness=\(NSStatusBar.system.thickness) btn=\(b != nil) win=\(w != nil) winVisible=\(w?.isVisible ?? false) onActiveSpace=\(w?.isOnActiveSpace ?? false) x=\(Int(w?.frame.minX ?? -999)) len=\(self.statusItem?.length ?? -1) visible=\(self.statusItem?.isVisible ?? false)")
        }
    }

    @objc func screensChanged() {
        statusItem?.isVisible = true
        launchLog("screensChanged: re-asserted statusItem visible, iconScreen=\(iconScreen().map{ "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "none")")
    }

    @objc func statusItemClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { togglePanel(); return }
        // Right-click: show a single "Quit zero" NSMenu, then clear it so
        // the next left-click still goes through togglePanel (not the menu).
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let menu = NSMenu()
        if let v = version {
            let versionItem = NSMenuItem(title: "zero \(v)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Quit zero", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // open the menu
        statusItem.menu = nil                  // clear immediately so left-click stays toggle
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

    @objc func togglePanel() {                       // icon click → open under the icon
        if panel.isVisible { hidePanel() } else { showPanel(on: iconScreen()) }
    }

    func toggleFromHotkey() {                         // ⌥⌘Z → open on the display you're using
        if panel.isVisible { hidePanel() } else { showPanel(on: screenUnderMouse()) }
    }

    /// The screen the menu-bar icon currently lives on (nil if macOS hasn't displayed it).
    func iconScreen() -> NSScreen? { statusItem?.button?.window?.screen }

    /// The screen under the mouse pointer — i.e. the display the user is actually on.
    func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    func showPanel(on preferred: NSScreen? = nil) {
        removeMonitors()                    // never double-register (showPanel without a paired hide)
        let target = preferred ?? iconScreen() ?? NSScreen.main ?? NSScreen.screens.first
        if let target { positionPanel(on: target) }
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

    // Open the panel on `target`. If the menu-bar icon is on this same screen, anchor the
    // arrow snugly under it (pointing at the item's centre). Otherwise — the icon is on
    // another display, or macOS isn't showing it at all — drop the panel top-centre of
    // this screen with the arrow centred. Either way it lands where the user is looking,
    // never on a display they aren't on. This is the core multi-display fix.
    func positionPanel(on target: NSScreen) {
        let winH = PANEL_H + ARROW_H
        let visible = target.visibleFrame
        var originX: CGFloat, originY: CGFloat
        if let f = placedIconFrame(),
           statusItem?.button?.window?.screen?.frame == target.frame {
            // Anchor only to a REAL placed icon frame (placedIconFrame() rejects the
            // un-laid-out origin frame), so we never compute a negative origin that
            // clamps to the bottom-left corner.
            originX = f.midX - (PANEL_W - 40)
            originX = max(visible.minX + 8, min(originX, visible.maxX - PANEL_W - 8))
            originY = f.minY - GAP - winH
            setArrowX(f.midX - originX)               // item centre in window coords
        } else {
            // Icon isn't placed yet, isn't on this screen, or isn't shown — drop the
            // panel at the top-RIGHT, where a menu-bar item lives, so it reads as coming
            // from the bar rather than floating dead-centre.
            originX = visible.maxX - PANEL_W - 12
            originY = visible.maxY - winH - 12
            setArrowX(PANEL_W - 40)                    // arrow near the right edge
        }
        // ALWAYS clamp fully on-screen. On first launch the panel can open before the
        // status-item window exists (or while one is stale / on a display that just
        // changed), and an unclamped originY lands the panel off the screen edge — the
        // user sees nothing and the app looks dead. This is THE first-run safety net:
        // wherever we anchored, the whole panel must end up inside the visible frame.
        originX = max(visible.minX + 8, min(originX, visible.maxX - PANEL_W - 8))
        originY = max(visible.minY + 8, min(originY, visible.maxY - winH - 8))
        panel.setFrame(NSRect(x: originX, y: originY, width: PANEL_W, height: winH), display: true)
        panel.invalidateShadow()                      // shadow follows the rounded glass silhouette
    }

    /// Build and launch the Python keeper server. Pure (no main-actor state) so it
    /// can run off the main thread on first launch, where resolveRepoRoot()/
    /// seedFromBundle() do synchronous payload-copy disk IO. Returns nil on failure.
    nonisolated static func launchServer(root: String) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "\(root)/lib/keeper_server.py"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPath()
        env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
        env["KEEPER_PORT"] = PORT
        env["MAIL_TRIAGE_DIR"] = root
        // gws uses per-account keyring creds, never a global token. Strip any stray
        // GOOGLE_WORKSPACE_CLI_TOKEN (e.g. exported from the user's shell) so it can't
        // poison the Authorization header and break every account.
        env.removeValue(forKey: "GOOGLE_WORKSPACE_CLI_TOKEN")
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        do { try p.run(); return p } catch { return nil }
    }

    // Synchronous boot — used by the dev/preview path that needs the server up
    // before it renders the screenshot window.
    func startServer() {
        guard let root = resolveRepoRoot(), let p = Self.launchServer(root: root) else {
            repoMissing = true
            return
        }
        server = p
    }

    // Menu-bar boot — resolve the root (copies the bundled payload on first launch)
    // and launch the server entirely off the main thread, so the status item that
    // was already put up in applicationDidFinishLaunching is never blocked by disk IO.
    func startServerAsync() {
        // Strong self: AppController is the app delegate and lives for the whole
        // process, so there's nothing to leak and nothing to outlive.
        Task.detached(priority: .userInitiated) {
            let proc = resolveRepoRoot().flatMap { Self.launchServer(root: $0) }
            await MainActor.run {
                if let proc { self.server = proc } else { self.repoMissing = true }
            }
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
