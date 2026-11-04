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

    init(screen: NSScreen, store: NotificationStore, settings: SettingsStore) {
        self.screen = screen
        viewModel = NotchViewModel(geometry: .detect(for: screen), store: store, settings: settings)
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: NotchViewModel.panelSize))
        let root = NotchRootView(vm: viewModel, store: store, settings: settings)
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
            }
            .store(in: &cancellables)
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
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
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
                if (state == .expanded || state == .peek), !self.hitRect.contains(NSEvent.mouseLocation) {
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
