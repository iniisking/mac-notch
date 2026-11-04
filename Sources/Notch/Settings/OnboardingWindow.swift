import AppKit
import SwiftUI

/// Shown when the Notification Center DB can't be opened (no Full Disk Access).
struct OnboardingView: View {
    @ObservedObject var store: NotificationStore
    let openSettings: () -> Void
    let relaunch: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notch needs Full Disk Access").font(.title3.bold())
                    Text(store.status.label).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Because Focus mode silences banners, Notch reads Notification Center's own database (read-only) to see new notifications. macOS protects that file, so Notch needs Full Disk Access.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click **Open Privacy Settings**.")
                Text("2. Turn on **Notch** in the Full Disk Access list (or click + and choose Notch.app at \(Bundle.main.bundlePath)).")
                Text("3. Click **Relaunch Notch**.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if case .running = store.status {
                Label("Access granted — reading notifications.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack {
                Button("Reveal Notch.app") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button("Later", action: close)
                Button("Relaunch Notch", action: relaunch)
                Button("Open Privacy Settings", action: openSettings).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let store: NotificationStore
    private let openSettings: () -> Void
    private let relaunch: () -> Void

    init(store: NotificationStore, openSettings: @escaping () -> Void, relaunch: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
        self.relaunch = relaunch
    }

    func show() {
        if window == nil {
            let view = OnboardingView(store: store, openSettings: openSettings, relaunch: relaunch,
                                      close: { [weak self] in self?.hide() })
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Notch"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() { window?.orderOut(nil) }
}
