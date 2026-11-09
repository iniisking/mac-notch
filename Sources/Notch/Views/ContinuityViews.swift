import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Moment (compact)

/// A device / Continuity moment: glyphs in the wings, "Title - detail" in the strip. While the
/// pointer is on it and it has an action, the strip shows the hint ("Click to join").
struct CompactMomentView: View {
    @ObservedObject var vm: NotchViewModel
    let moment: Moment
    @State private var hovering = false

    var body: some View {
        let h = vm.geometry.notchSize.height
        let (left, right) = vm.wings
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                MomentGlyphView(glyph: moment.left, size: min(22, h - 12)).frame(width: left)
                Color.clear.frame(width: vm.gapWidth)
                MomentGlyphView(glyph: moment.right, size: min(20, h - 14)).frame(width: right)
            }
            .frame(height: h)
            Group {
                if hovering, let hint = moment.actionHint {
                    Text(hint)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                } else {
                    MarqueeText(text: moment.detail.isEmpty ? moment.title : "\(moment.title) - \(moment.detail)",
                                font: .system(size: 11.5), height: 16, alignment: .center,
                                styled: CompactView.styled((moment.title, moment.detail)))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: NotchViewModel.lyricStripHeight - 4, alignment: .top)
        }
        .padding(.horizontal, vm.topRadius)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .id(moment.id)
    }
}

struct MomentGlyphView: View {
    let glyph: Moment.Glyph
    var size: CGFloat = 20

    var body: some View {
        switch glyph {
        case .symbol(let name, let color):
            Image(systemName: name)
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
        case .image(let img):
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        case .appIcon(let id):
            AppIconView(bundleID: id, size: size)
        case .text(let t, let color):
            Text(t)
                .font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
        case .battery(let pct, let charging):
            BatteryGlyph(percent: pct, color: ContinuityColors.battery(pct, charging: charging), bolt: charging)
                .scaleEffect(0.85)
        case .none:
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

// MARK: - AirDrop drop zone

/// Shown while files are dragged over the notch: drop them to open the AirDrop picker.
struct DropZoneView: View {
    @ObservedObject var vm: NotchViewModel
    @State private var targeted = false

    var body: some View {
        let h = vm.geometry.notchSize.height
        VStack(spacing: 0) {
            Color.clear.frame(height: h)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(ContinuityColors.blue.opacity(targeted ? 0.45 : 0.22))
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .scaleEffect(targeted ? 1.08 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirDrop").font(.system(size: 13.5, weight: .semibold))
                    Text(targeted ? "Release to choose a device" : "Drop files here to send them to your iPhone")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.white.opacity(targeted ? 0.7 : 0.3)))
            .padding(.horizontal, vm.topRadius + 10)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            Self.loadURLs(providers) { vm.dropFiles($0) }
            return true
        }
    }

    static func loadURLs(_ providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(urls) } }
    }
}

// MARK: - Expanded › Devices

/// Devices page: headphones, iPhone (via the Shortcuts bridge), Focus / hotspot, next event,
/// Universal Clipboard, AirDrop and quick actions.
struct DevicesPage: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var audio: AudioDeviceMonitor
    @ObservedObject var bridge: DeviceBridge
    @ObservedObject var focus: FocusMonitor
    @ObservedObject var hotspot: HotspotMonitor
    @ObservedObject var calendar: CalendarMonitor
    @ObservedObject var clipboard: ClipboardMonitor
    @ObservedObject var airdrop: AirDropMonitor
    @ObservedObject var calls: CallMonitor

    init(vm: NotchViewModel, settings: SettingsStore, calls: CallMonitor) {
        self.vm = vm
        self.settings = settings
        let hub = vm.hub
        audio = hub.audio; bridge = hub.bridge; focus = hub.focus; hotspot = hub.hotspot
        calendar = hub.calendar; clipboard = hub.clipboard; airdrop = hub.airdrop
        self.calls = calls
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    devicesCard
                    if settings.showCalendar { UpNextCard(calendar: calendar) }
                    statusRow
                }
            }
            .frame(maxWidth: .infinity)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    if settings.showUniversalClipboard { clipboardCard }
                    if settings.showAirDrop || settings.airDropDropZone { airDropCard }
                    actionsCard
                }
            }
            .frame(width: 250)
        }
        .padding(.top, 8)
    }

    // MARK: Devices

    private var devicesCard: some View {
        DeviceCard {
            VStack(alignment: .leading, spacing: 9) {
                DeviceCardHeader(title: "Devices", symbol: "laptopcomputer.and.iphone")
                ForEach(bridge.devices) { d in
                    deviceRow(symbol: d.symbol, name: d.name,
                              detail: bridgedDetail(d),
                              battery: d.battery, charging: d.charging ?? false)
                }
                ForEach(audio.devices) { d in
                    deviceRow(symbol: d.symbol, name: d.name,
                              detail: d.batteryDetail.isEmpty ? "Connected" : d.batteryDetail,
                              battery: d.headline, charging: false)
                }
                if calls.cameraIsIPhone {
                    deviceRow(symbol: "web.camera", name: "Continuity Camera", detail: "iPhone camera in use",
                              battery: nil, charging: false)
                }
                if bridge.devices.isEmpty && audio.devices.isEmpty && !calls.cameraIsIPhone {
                    Text(settings.bridgeEnabled
                         ? "Waiting for your iPhone. Build the battery Shortcut on it and run it once (steps in Settings › iPhone bridge)."
                         : "No headphones connected. Turn on the iPhone bridge in Settings to see your iPhone's battery here.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bridgedDetail(_ d: BridgedDevice) -> String {
        var parts: [String] = []
        if d.charging == true { parts.append(d.battery == 100 ? "Charged" : "Charging") }
        if d.lowPower == true { parts.append("Low Power") }
        parts.append("updated \(d.updated.notchRelative)")
        return parts.joined(separator: " · ")
    }

    private func deviceRow(symbol: String, name: String, detail: String, battery: Int?, charging: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if let b = battery {
                Text("\(b)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(ContinuityColors.battery(b, charging: charging))
                BatteryGlyph(percent: b, color: ContinuityColors.battery(b, charging: charging), bolt: charging)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if settings.showFocus {
                statusPill(symbol: focus.active?.symbol ?? "moon",
                           text: focus.active.map { $0.name } ?? "No Focus",
                           color: focus.active != nil ? ContinuityColors.purple : .white.opacity(0.45))
            }
            if settings.showHotspot {
                statusPill(symbol: "personalhotspot",
                           text: hotspot.active ? (hotspot.networkName ?? "Hotspot") : "No hotspot",
                           color: hotspot.active ? ContinuityColors.green : .white.opacity(0.45))
            }
        }
    }

    private func statusPill(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
    }

    // MARK: Clipboard

    private var clipboardCard: some View {
        DeviceCard {
            VStack(alignment: .leading, spacing: 7) {
                DeviceCardHeader(title: "Universal Clipboard", symbol: "doc.on.clipboard")
                if let clip = clipboard.last {
                    HStack(alignment: .top, spacing: 8) {
                        if let img = clip.image {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.preview).font(.system(size: 11.5)).lineLimit(2)
                            Text(clip.date.notchRelative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    if let url = clip.url {
                        Button { NSWorkspace.shared.open(url); vm.collapse() } label: {
                            Label("Open link", systemImage: "safari")
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                } else {
                    Text("Copy something on your iPhone or iPad and it shows up here.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: AirDrop

    private var airDropCard: some View {
        DeviceCard {
            VStack(alignment: .leading, spacing: 7) {
                DeviceCardHeader(title: "AirDrop", symbol: "dot.radiowaves.up.forward")
                ForEach(airdrop.recent.prefix(3)) { b in
                    HStack(spacing: 8) {
                        if let t = b.thumbnail {
                            Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(b.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Text(b.date.notchRelative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting(b.files); vm.collapse() }
                    .help("Show in Finder")
                }
                if settings.airDropDropZone {
                    Text("Drag files onto the notch to AirDrop them.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    // MARK: Actions

    private var actionsCard: some View {
        DeviceCard {
            VStack(alignment: .leading, spacing: 8) {
                DeviceCardHeader(title: "Quick actions", symbol: "bolt.fill")
                FlowButtons {
                    if QuickActions.mirroringURL != nil {
                        Button { QuickActions.openMirroring(); vm.collapse() } label: {
                            Label("iPhone Mirroring", systemImage: "iphone.gen3")
                        }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    }
                    ForEach(settings.pinnedShortcuts, id: \.self) { name in
                        ShortcutButton(name: name)
                    }
                }
                if settings.pinnedShortcuts.isEmpty {
                    Text("Pin Shortcuts in Settings to run them from here.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

/// Runs a pinned Shortcut, showing a spinner and then a tick or a cross.
private struct ShortcutButton: View {
    let name: String
    /// nil while idle; the last run's result for two seconds after it finishes.
    @State private var outcome: Bool?
    @State private var running = false

    var body: some View {
        Button {
            running = true
            QuickActions.runShortcut(name) { ok in
                running = false
                outcome = ok
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { outcome = nil }
            }
        } label: {
            HStack(spacing: 4) {
                if running {
                    ProgressView().controlSize(.mini)
                } else if let ok = outcome {
                    Image(systemName: ok ? "checkmark" : "xmark")
                } else {
                    Image(systemName: "square.2.layers.3d")
                }
                Text(name).lineLimit(1)
            }
        }
        .buttonStyle(PillButtonStyle())
        .disabled(running)
    }
}

/// Wraps pill buttons onto as many lines as needed.
struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        FlowLayout(spacing: 6) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + s.width > width {
                rows.append(Row())
            }
            var r = rows[rows.count - 1]
            r.width += (r.indices.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.indices.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Up next

/// Next calendar event (synced from iPhone), with Join when it has a meeting link.
struct UpNextCard: View {
    @ObservedObject var calendar: CalendarMonitor
    /// Compact: no header, and nothing at all when there's no upcoming event (Home page).
    var compact = false

    var body: some View {
        if compact && calendar.next == nil {
            EmptyView()
        } else {
            card
        }
    }

    private var card: some View {
        DeviceCard {
            VStack(alignment: .leading, spacing: 7) {
                if !compact { DeviceCardHeader(title: "Up next", symbol: "calendar") }
                if let e = calendar.next {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: e.calendarColor ?? .systemOrange))
                                .frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                Text(subtitle(e)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if let url = e.joinURL {
                                Button { NSWorkspace.shared.open(url) } label: {
                                    Label("Join", systemImage: "video.fill")
                                }
                                .buttonStyle(PillButtonStyle(prominent: true))
                                .help("Join on \(e.serviceName ?? "the web")")
                            }
                        }
                    }
                } else if calendar.denied {
                    HStack {
                        Text("Calendar access is off.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button("Allow…") { calendar.openPrivacySettings() }.buttonStyle(PillButtonStyle())
                    }
                } else {
                    Text("Nothing else in the next 12 hours.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private func subtitle(_ e: UpcomingEvent) -> String {
        let time = e.start.formatted(date: .omitted, time: .shortened) + " – " + e.end.formatted(date: .omitted, time: .shortened)
        let when = e.isNow ? "Now" : e.whenText.prefix(1).uppercased() + e.whenText.dropFirst()
        return [when, time, e.location].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Messages quick reply

/// Reply field under a Messages notification in the expanded panel.
struct MessageReplyField: View {
    let chat: String
    @State private var text = ""
    @State private var sending = false
    @State private var result: Bool?

    var body: some View {
        HStack(spacing: 6) {
            TextField("Reply with iMessage / SMS…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.1)))
                .onSubmit(send)
                .disabled(sending)
            Button(action: send) {
                Group {
                    if sending { ProgressView().controlSize(.mini) }
                    else if let r = result { Image(systemName: r ? "checkmark" : "exclamationmark.triangle.fill") }
                    else { Image(systemName: "arrow.up") }
                }
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(result == false ? ContinuityColors.red : ContinuityColors.blue))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            .help(result == false ? "Couldn't send. Check Automation permission for Messages." : "Send")
        }
        .id(chat)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !sending else { return }
        sending = true
        result = nil
        QuickActions.sendMessage(t, chat: chat) { ok in
            sending = false
            result = ok
            if ok { text = "" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if result == ok { result = nil } }
        }
    }
}

// MARK: - Card chrome

struct DeviceCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.07)))
    }
}

struct DeviceCardHeader: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(title).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase)
        }
        .foregroundStyle(.white.opacity(0.5))
    }
}
