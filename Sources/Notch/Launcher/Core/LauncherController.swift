import AppKit
import SwiftUI

/// The launcher window: a borderless, non-activating panel that hangs from the notch. Because it
/// never activates Notch, the app you were in stays frontmost, which is what makes paste-back work.
final class LauncherPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class LauncherController {
    let model: LauncherModel
    private let services: LauncherServices
    private var panel: LauncherPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var field: NSTextField?
    private(set) var isVisible = false
    /// The app that was frontmost when the launcher opened (gets focus back if we had to activate).
    private var previousApp: NSRunningApplication?
    private var activatedSelf = false

    init(services: LauncherServices) {
        self.services = services
        model = LauncherModel(services: services)
        model.hideHandler = { [weak self] in self?.hide() }
    }

    /// Hotkey: open in that mode, or close if it's already showing it.
    func toggle(_ mode: LauncherMode) {
        if isVisible, model.mode == mode || mode == .root { hide() } else { show(mode) }
    }

    func show(_ mode: LauncherMode) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let geometry = NotchGeometry.detect(for: screen)
        model.geometry = geometry
        model.prepare(mode)

        let size = CGSize(width: LauncherModel.size.width, height: LauncherModel.size.height + geometry.notchSize.height)
        let panel = self.panel ?? makePanel(size: size)
        let midX = geometry.hasNotch ? geometry.notchRect.midX : screen.frame.midX
        panel.setFrame(NSRect(x: (midX - size.width / 2).rounded(), y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        if let field { panel.makeFirstResponder(field) }
        installMonitors(panel)
        isVisible = true
        DispatchQueue.main.async { self.model.isOpen = true }
        // A non-activating panel normally takes the keyboard without activating Notch. If macOS
        // refuses (no user event behind the request), activate and hand focus back on close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.isVisible, let panel = self.panel, !panel.isKeyWindow else { return }
            self.activatedSelf = true
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            if let f = self.field { panel.makeFirstResponder(f) }
            DebugLog.write("launcher: activated to take focus")
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        model.isOpen = false
        model.showActions = false
        model.cancelEditing()
        panel?.orderOut(nil)
        removeMonitors()
        services.files.reset()
        if activatedSelf {
            activatedSelf = false
            // Only if we still hold focus (not when you clicked into another app to close it).
            if NSApp.isActive { previousApp?.activate() }
        }
    }

    /// Debug (`--launcher … --snapshot`): renders the panel to
    /// ~/Library/Application Support/Notch/snapshots/launcher-<name>.png.
    func snapshot(_ name: String) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            DebugLog.write("launcher snapshot: no view (panel \(panel == nil ? "missing" : "present"))")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let dir = LauncherSettings.supportDirectory.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("launcher-\(name).png"))
    }

    private func makePanel(size: CGSize) -> LauncherPanel {
        let p = LauncherPanel(size: size)
        let root = LauncherView(model: model, services: services, settings: services.settings) { [weak self] f in
            self?.field = f
            DispatchQueue.main.async {
                guard let self, self.isVisible else { return }
                self.panel?.makeFirstResponder(f)
            }
        }
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        panel = p
        return p
    }

    private func installMonitors(_ panel: LauncherPanel) {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.window === self.panel else { return event }
            return self.model.handleKey(event) ? nil : event
        }
        // Clicking anywhere else closes it (like Spotlight).
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                // Quick Look / Settings may take key briefly; only close when nothing of ours is key.
                if NSApp.keyWindow == nil || !(NSApp.keyWindow is LauncherPanel) { self.hide() }
            }
        }
    }

    private func removeMonitors() {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
        resignObserver = nil
    }
}
