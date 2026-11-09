import AppKit
import Combine
import SwiftUI

/// Owns one NotchPanel on one screen, keeps it positioned on the notch, and decides
/// when the panel should take the mouse (only inside the current shape, so the
/// menu bar keeps working everywhere else).
@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    private(set) var screen: NSScreen
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    init(screen: NSScreen, store: NotificationStore, settings: SettingsStore, player: NowPlayingService,
         lyrics: LyricsService, calls: CallMonitor, power: PowerMonitor) {
        self.screen = screen
        viewModel = NotchViewModel(geometry: .detect(for: screen), store: store, settings: settings, player: player,
                                   lyrics: lyrics, calls: calls, power: power)
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchViewModel.panelSize))
        let root = NotchRootView(vm: viewModel, store: store, settings: settings, player: player, lyrics: lyrics,
                                 calls: calls, power: power)
        let host = FirstMouseHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: NotchViewModel.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        layout()
        panel.orderFrontRegardless()
        installMonitors()

        viewModel.$state
            .removeDuplicates()
            .sink { [weak self] state in
                // Re-evaluate the hit area once the new size is in effect.
                DispatchQueue.main.async { self?.updateMouse() }
                if state == .expanded { self?.panel.makeKey() }
                if CommandLine.arguments.contains("--snapshot") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.snapshot("\(state)") }
                }
            }
            .store(in: &cancellables)
    }

    /// Debug (`--snapshot`): renders the panel's own view to
    /// ~/Library/Application Support/Notch/snapshots/<state>.png (no Screen Recording permission needed).
    func snapshot(_ name: String) {
        guard let view = panel.contentView else { return }
        let size = viewModel.shapeSize
        let y = view.isFlipped ? 0 : view.bounds.height - size.height - 4
        let rect = NSRect(x: (view.bounds.width - size.width) / 2, y: y, width: size.width, height: size.height + 4)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notch/snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func close() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        cancellables.removeAll()
        panel.orderOut(nil)
        panel.close()
    }

    func update(screen: NSScreen) {
        self.screen = screen
        viewModel.geometry = .detect(for: screen)
        layout()
    }

    private func layout() {
        let f = screen.frame
        let size = NotchViewModel.panelSize
        // Centre on the actual camera housing (its rect is in global coordinates).
        let midX = viewModel.geometry.hasNotch ? viewModel.geometry.notchRect.midX : f.midX
        let origin = NSPoint(x: (midX - size.width / 2).rounded(), y: f.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Mouse

    /// Current interactive rect in screen coordinates (top-centred on the panel).
    private var hitRect: NSRect {
        let s = viewModel.hitSize
        let f = panel.frame
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouse() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouse() }
            return event
        }) { monitors.append(l) }
        // Clicks in other apps collapse the expanded / peek panel.
        if let c = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let state = self.viewModel.state
                if [.expanded, .peek, .musicPeek, .callPeek].contains(state), !self.hitRect.contains(NSEvent.mouseLocation) {
                    self.viewModel.collapse()
                }
            }
        }) { monitors.append(c) }
    }

    private func updateMouse() {
        let inside = hitRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        viewModel.setHovering(inside)
    }
}
