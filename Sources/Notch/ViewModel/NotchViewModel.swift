import AppKit
import Combine
import SwiftUI

/// UI state for one notch window (one per screen). History lives in the shared NotificationStore.
@MainActor
final class NotchViewModel: ObservableObject {
    enum State: Equatable { case idle, music, compact, peek, musicPeek, expanded }

    @Published private(set) var state: State = .idle
    @Published private(set) var current: NotchNotification?
    @Published private(set) var pendingCount = 0
    @Published private(set) var glowPulse = false
    @Published var selectedID: NotchNotification.ID?
    @Published var geometry: NotchGeometry

    let store: NotificationStore
    let settings: SettingsStore
    let player: NowPlayingService
    let lyrics: LyricsService
    var openSettings: () -> Void = {}
    var openFullDiskAccess: () -> Void = {}

    /// Compact labels wider than this scroll.
    static let maxLabelWing: CGFloat = 92
    /// Size of the panel that hosts the shape; big enough for the expanded state plus glow.
    static let panelSize = CGSize(width: 720, height: 470)

    private var queue: [NotchNotification] = []
    private var compactWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var autoPeekWork: DispatchWorkItem?
    /// True while the music card is showing because the track changed (not because of hover).
    private(set) var isAutoPeek = false
    private(set) var isHovering = false
    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, store: NotificationStore, settings: SettingsStore,
         player: NowPlayingService, lyrics: LyricsService) {
        self.geometry = geometry
        self.store = store
        self.settings = settings
        self.player = player
        self.lyrics = lyrics
        // Music comes and goes underneath notifications.
        player.$showInNotch
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.state == .idle || self.state == .music { self.state = self.restingState }
            }
            .store(in: &cancellables)
        // Track changes: briefly drop down so you can see what's playing.
        player.$info
            .map { $0?.trackKey }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] key in
                guard key != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.autoPeekIfResting() }
            }
            .store(in: &cancellables)
        store.arrivals
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.enqueue($0) }
            .store(in: &cancellables)
    }

    // MARK: - Geometry

    var topRadius: CGFloat {
        switch state {
        case .idle: return 6
        case .music, .compact: return 8
        case .peek, .musicPeek: return 12
        case .expanded: return 14
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return 8
        case .music, .compact: return 12
        case .peek, .musicPeek: return 20
        case .expanded: return 26
        }
    }

    /// Dynamic-Island style wing: about as wide as the notch is tall.
    var wing: CGFloat { geometry.notchSize.height + 6 }

    /// Right wing in the compact notification state: as wide as the label needs, capped.
    var labelWing: CGFloat {
        guard let n = current else { return wing }
        let text = (n.shortLabel as NSString).size(withAttributes: [.font: Self.labelFont]).width
        return min(Self.maxLabelWing, max(wing, ceil(text) + 12))
    }

    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let lyricStripHeight: CGFloat = 20

    /// Lyric line under the compact music notch (hidden in gaps / without lyrics).
    var showsLyricStrip: Bool {
        state == .music && settings.showLyrics && settings.showLyricStrip && lyrics.currentLine != nil
    }

    private var peekLyricsHeight: CGFloat {
        settings.showLyrics && lyrics.state != .off ? 70 : 0
    }

    /// (left wing, right wing) for the compact states.
    var wings: (CGFloat, CGFloat) {
        switch state {
        case .compact: return (wing, labelWing)
        default: return (wing, wing)
        }
    }

    var shapeSize: CGSize {
        let w = geometry.notchSize.width, h = geometry.notchSize.height
        switch state {
        case .idle: return CGSize(width: w + 2 * topRadius, height: h)
        case .compact, .music:
            let (l, r) = wings
            let strip = showsLyricStrip ? Self.lyricStripHeight : 0
            return CGSize(width: w + 2 * topRadius + l + r, height: h + strip)
        case .peek: return CGSize(width: max(w + 2 * topRadius + 2 * 150, 470), height: h + 112)
        case .musicPeek: return CGSize(width: 480, height: h + 118 + peekLyricsHeight)
        case .expanded: return CGSize(width: 660, height: 430)
        }
    }

    /// Horizontal shift that keeps the camera gap over the hardware notch when wings differ.
    var shapeOffsetX: CGFloat {
        let (l, r) = wings
        return (r - l) / 2
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
        if state == .idle || state == .music || (state == .musicPeek && isAutoPeek) {
            showNext()
        } else if state == .compact {
            // Others are waiting now: don't hold the current one for the full duration.
            scheduleAdvance(after: min(settings.displayDuration, 2.0))
        }
    }

    /// What the notch shows when nothing else is going on.
    var restingState: State { player.showInNotch ? .music : .idle }

    private func autoPeekIfResting(attempt: Int = 0) {
        // Music may only just be starting (still idle): try again shortly.
        if state == .idle, attempt < 4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.autoPeekIfResting(attempt: attempt + 1)
            }
            return
        }
        guard state == .music, !isHovering else { return }
        isAutoPeek = true
        state = .musicPeek
        autoPeekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isAutoPeek, !self.isHovering, self.state == .musicPeek else { return }
            self.isAutoPeek = false
            self.collapse()
        }
        autoPeekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func showNext() {
        compactWork?.cancel()
        isAutoPeek = false
        guard !queue.isEmpty else {
            state = restingState
            return
        }
        current = queue.removeFirst()
        pendingCount = queue.count
        state = .compact
        pulseGlow()
        // Shorter dwell while others are waiting.
        let dwell = queue.isEmpty ? settings.displayDuration : min(settings.displayDuration, 2.0)
        scheduleAdvance(after: dwell)
    }

    private func scheduleAdvance(after dwell: TimeInterval) {
        compactWork?.cancel()
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
                if [.peek, .musicPeek, .expanded].contains(self.state) { self.collapse() }
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
        case .music:
            state = .musicPeek
        case .musicPeek:
            isAutoPeek = false   // hovering takes over from the auto-peek timer
        case .idle:
            // A paused session can still be controlled from the idle notch.
            if player.hasSession {
                state = .musicPeek
            } else {
                current = store.visibleHistory.first
                state = .peek
            }
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
        isAutoPeek = false
        if queue.isEmpty { state = restingState } else { showNext() }
    }
}
