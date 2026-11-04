import AppKit
import Combine
import SwiftUI

/// UI state for one notch window (one per screen). History lives in the shared NotificationStore.
@MainActor
final class NotchViewModel: ObservableObject {
    enum State: Equatable { case idle, compact, peek, expanded }

    @Published private(set) var state: State = .idle
    @Published private(set) var current: NotchNotification?
    @Published private(set) var pendingCount = 0
    @Published private(set) var glowPulse = false
    @Published var selectedID: NotchNotification.ID?
    @Published var geometry: NotchGeometry

    let store: NotificationStore
    let settings: SettingsStore
    var openSettings: () -> Void = {}
    var openFullDiskAccess: () -> Void = {}

    static let wing: CGFloat = 150
    /// Size of the panel that hosts the shape; big enough for the expanded state plus glow.
    static let panelSize = CGSize(width: 720, height: 470)

    private var queue: [NotchNotification] = []
    private var compactWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private(set) var isHovering = false
    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, store: NotificationStore, settings: SettingsStore) {
        self.geometry = geometry
        self.store = store
        self.settings = settings
        store.arrivals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.enqueue($0) }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    var topRadius: CGFloat {
        switch state {
        case .idle: return 6
        case .compact: return 8
        case .peek: return 12
        case .expanded: return 14
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return 8
        case .compact: return 12
        case .peek: return 20
        case .expanded: return 26
        }
    }

    var shapeSize: CGSize {
        let w = geometry.notchSize.width, h = geometry.notchSize.height
        let compactWidth = w + 2 * topRadius + 2 * Self.wing
        switch state {
        case .idle: return CGSize(width: w + 2 * topRadius, height: h)
        case .compact: return CGSize(width: compactWidth, height: h)
        case .peek: return CGSize(width: max(compactWidth, 470), height: h + 112)
        case .expanded: return CGSize(width: 660, height: 430)
        }
    }

    /// The idle shape is drawn invisibly so it can grow out of the hardware notch.
    var shapeOpacity: Double { state == .idle ? 0 : 1 }

    /// Region (in shape coordinates, top-centred) that should receive the mouse.
    var hitSize: CGSize {
        if state == .idle {
            let h = geometry.notchSize.height
            return geometry.hasNotch ? CGSize(width: geometry.notchSize.width, height: h)
                                     : CGSize(width: 200, height: max(4, h * 0.6))
        }
        return shapeSize
    }

    // MARK: - Notifications

    private func enqueue(_ n: NotchNotification) {
        queue.append(n)
        pendingCount = queue.count
        if state == .idle { showNext() }
    }

    private func showNext() {
        compactWork?.cancel()
        guard !queue.isEmpty else {
            state = .idle
            return
        }
        current = queue.removeFirst()
        pendingCount = queue.count
        state = .compact
        pulseGlow()
        // Shorter dwell while others are waiting.
        let dwell = queue.isEmpty ? settings.displayDuration : min(settings.displayDuration, 2.0)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .compact else { return }
            self.showNext()
        }
        compactWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func pulseGlow() {
        glowPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.glowPulse = false }
    }

    // MARK: - Interaction

    /// Debug (`--peek` launch flag): keep the hover state so the peek card can be inspected.
    var debugPinHover = false

    func setHovering(_ inside: Bool) {
        if debugPinHover && !inside { return }
        guard inside != isHovering else { return }
        isHovering = inside
        hoverWork?.cancel()
        if inside {
            let work = DispatchWorkItem { [weak self] in self?.hoverBegan() }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovering else { return }
                if self.state == .peek || self.state == .expanded { self.collapse() }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func hoverBegan() {
        guard isHovering else { return }
        switch state {
        case .compact:
            compactWork?.cancel()
            state = .peek
        case .idle:
            current = store.visibleHistory.first
            state = .peek
        case .peek, .expanded:
            break
        }
    }

    func expand() {
        compactWork?.cancel()
        selectedID = current?.id ?? store.visibleHistory.first?.id
        state = .expanded
    }

    /// Opens the expanded panel from outside (status menu).
    func showExpanded() {
        current = current ?? store.visibleHistory.first
        expand()
    }

    func collapse() {
        if queue.isEmpty { state = .idle } else { showNext() }
    }
}
