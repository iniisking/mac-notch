import AppKit
import Combine
import SwiftUI

/// UI state for one notch window (one per screen). History lives in the shared NotificationStore.
@MainActor
final class NotchViewModel: ObservableObject {
    enum State: Equatable { case idle, music, call, battery, compact, peek, musicPeek, callPeek, expanded }

    @Published private(set) var state: State = .idle
    @Published private(set) var current: NotchNotification?
    @Published private(set) var pendingCount = 0
    @Published var selectedID: NotchNotification.ID?
    /// Notification pinned at the top of the music hover panel (just shown, or arrived while it was open).
    @Published private(set) var peekHighlight: NotchNotification?
    private var lastShown: (item: NotchNotification, at: Date)?
    @Published var geometry: NotchGeometry

    let store: NotificationStore
    let settings: SettingsStore
    let player: NowPlayingService
    let lyrics: LyricsService
    let calls: CallMonitor
    let power: PowerMonitor
    /// What the brief battery moment is showing (plugged in / low).
    @Published private(set) var batteryEvent: PowerEvent?
    private var pendingBattery: (event: PowerEvent, at: Date)?
    private var batteryWork: DispatchWorkItem?
    var openSettings: () -> Void = {}
    var openFullDiskAccess: () -> Void = {}

    /// Size of the panel that hosts the shape; big enough for the expanded state.
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
         player: NowPlayingService, lyrics: LyricsService, calls: CallMonitor, power: PowerMonitor) {
        self.geometry = geometry
        self.store = store
        self.settings = settings
        self.player = player
        self.lyrics = lyrics
        self.calls = calls
        self.power = power
        // Calls take over the resting state from music, and hand it back when they end.
        calls.$call
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    if [.idle, .music, .call].contains(self.state) { self.state = self.restingState }
                    if self.state == .callPeek, self.calls.call == nil { self.collapse() }
                }
            }
            .store(in: &cancellables)
        power.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.showBattery($0) }
            .store(in: &cancellables)
        // Music comes and goes underneath notifications.
        player.$showInNotch
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if [.idle, .music, .call].contains(self.state) { self.state = self.restingState }
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
        case .music, .call, .battery, .compact: return 8
        case .peek, .musicPeek, .callPeek: return 12
        case .expanded: return 14
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .idle: return 8
        case .music, .call, .battery, .compact: return 12
        case .peek, .musicPeek, .callPeek: return 20
        case .expanded: return 26
        }
    }

    /// Dynamic-Island style wing: about as wide as the notch is tall.
    var wing: CGFloat { geometry.notchSize.height + 6 }

    /// Clearance kept on each side of the camera housing.
    var gapPadding: CGFloat { geometry.hasNotch ? 4 : 0 }

    /// Width of the no-draw zone over the camera (housing + clearance).
    var gapWidth: CGFloat { geometry.notchSize.width + 2 * gapPadding }

    /// Strip under the compact notch (notification label or lyric line).
    static let lyricStripHeight: CGFloat = 20
    static let stripFont = Font.system(size: 11.5, weight: .semibold)

    /// The compact notification shows its label in the strip under the notch.
    var showsLabelStrip: Bool { state == .compact && current != nil }

    /// Lyric line under the compact music notch (hidden in gaps / without lyrics).
    var showsLyricStrip: Bool {
        state == .music && settings.showLyrics && settings.showLyricStrip && lyrics.currentLine != nil
    }

    /// Notifications listed in the music hover panel.
    static let peekListLimit = 5
    static let peekRowHeight: CGFloat = 30

    private var musicPeekHeight: CGFloat {
        var hgt = geometry.notchSize.height                          // top band beside the camera
        if peekHighlight != nil { hgt += 78 }                        // pinned notification card
        hgt += 70                                                    // compact player
        if case .synced = lyrics.state, settings.showLyrics { hgt += 62 + (lyrics.hasExtraLine ? 16 : 0) }
        let count = store.visibleHistory.count
        hgt += 24 + (count == 0 ? 22 : CGFloat(min(count, Self.peekListLimit)) * Self.peekRowHeight)
        return hgt + 14
    }

    /// (left wing, right wing) for the compact states. Calls past an hour widen both wings
    /// symmetrically so "1:02:33" fits.
    var wings: (CGFloat, CGFloat) {
        if state == .call, calls.pastHour { return (wing + 12, wing + 12) }
        return (wing, wing)
    }

    var shapeSize: CGSize {
        let w = geometry.notchSize.width, h = geometry.notchSize.height
        switch state {
        case .idle: return CGSize(width: w + 2 * topRadius, height: h)
        case .compact, .music, .call, .battery:
            let (l, r) = wings
            let strip = (showsLyricStrip || showsLabelStrip || state == .battery) ? Self.lyricStripHeight : 0
            return CGSize(width: gapWidth + 2 * topRadius + l + r, height: h + strip)
        case .callPeek: return CGSize(width: max(w + 2 * topRadius + 2 * 150, 440), height: h + 64)
        case .peek: return CGSize(width: max(w + 2 * topRadius + 2 * 150, 470), height: h + 112)
        case .musicPeek: return CGSize(width: 480, height: min(musicPeekHeight, Self.panelSize.height - 20))
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
        if state == .musicPeek && !isAutoPeek {
            // The music hover panel is open: pin the new one at the top instead of queueing it.
            peekHighlight = n
            lastShown = (n, Date())
            queue.removeAll { $0.id == n.id }
            pendingCount = queue.count
        } else if [.idle, .music, .call, .battery].contains(state) || (state == .musicPeek && isAutoPeek) {
            showNext()
        } else if state == .compact {
            // Others are waiting now: don't hold the current one for the full duration.
            scheduleAdvance(after: min(settings.displayDuration, 2.0))
        }
    }

    /// What the notch shows when nothing else is going on: a call, then music, then nothing.
    var restingState: State {
        if settings.showCalls, calls.call != nil { return .call }
        return player.showInNotch ? .music : .idle
    }

    // MARK: - Battery moment

    private func showBattery(_ event: PowerEvent) {
        switch event {
        case .pluggedIn: guard settings.showCharging else { return }
        case .low: guard settings.lowBatteryAlerts else { return }
        }
        // Busy with a notification or a card: show it once things settle (if still relevant).
        let canShow = [.idle, .music, .call, .battery].contains(state) || (state == .musicPeek && isAutoPeek)
        guard canShow, !isHovering else {
            pendingBattery = (event, Date())
            return
        }
        presentBattery(event)
    }

    private func presentBattery(_ event: PowerEvent) {
        pendingBattery = nil
        isAutoPeek = false
        autoPeekWork?.cancel()
        batteryEvent = event
        state = .battery
        batteryWork?.cancel()
        let isLow: Bool = { if case .low = event { return true } else { return false } }()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .battery else { return }
            self.state = self.restingState
        }
        batteryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isLow ? 5 : 3), execute: work)
    }

    /// A battery event that was held back while a notification was showing (fresh ones only).
    private func takePendingBattery() -> PowerEvent? {
        guard let p = pendingBattery else { return nil }
        pendingBattery = nil
        return Date().timeIntervalSince(p.at) < 20 ? p.event : nil
    }

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
            if let b = takePendingBattery() { presentBattery(b) } else { state = restingState }
            return
        }
        current = queue.removeFirst()
        pendingCount = queue.count
        if let c = current { lastShown = (c, Date()) }
        state = .compact
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
                if [.peek, .musicPeek, .callPeek, .expanded].contains(self.state) { self.collapse() }
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
            if player.hasSession {
                // Music + notification: the panel shows both, with this notification on top.
                peekHighlight = current
                state = .musicPeek
            } else {
                state = .peek
            }
        case .music:
            peekHighlight = recentlyShown
            state = .musicPeek
        case .call:
            state = .callPeek
        case .battery:
            // Hovering ends the battery moment and behaves like hovering the resting notch.
            batteryWork?.cancel()
            state = restingState
            hoverBegan()
        case .musicPeek:
            isAutoPeek = false   // hovering takes over from the auto-peek timer
        case .idle:
            // A paused session can still be controlled from the idle notch.
            if player.hasSession {
                peekHighlight = recentlyShown
                state = .musicPeek
            } else {
                current = store.visibleHistory.first
                state = .peek
            }
        case .peek, .callPeek, .expanded:
            break
        }
    }

    /// A notification shown in the last ~10 s (so hovering never buries a new message).
    private var recentlyShown: NotchNotification? {
        guard let l = lastShown, Date().timeIntervalSince(l.at) < 10,
              store.visibleHistory.contains(where: { $0.id == l.item.id }) else { return nil }
        return l.item
    }

    func expand(selecting id: NotchNotification.ID? = nil) {
        compactWork?.cancel()
        selectedID = id ?? peekHighlight?.id ?? current?.id ?? store.visibleHistory.first?.id
        peekHighlight = nil
        state = .expanded
    }

    /// Opens the expanded panel from outside (status menu).
    func showExpanded() {
        current = current ?? store.visibleHistory.first
        expand()
    }

    /// Double-click: open the notification's conversation (or app) and fold the notch away.
    func open(_ n: NotchNotification) {
        NotificationOpener.open(n)
        collapse()
    }

    func collapse() {
        isAutoPeek = false
        peekHighlight = nil
        showNext()   // queued notifications, then a held-back battery moment, then the resting state
    }
}
