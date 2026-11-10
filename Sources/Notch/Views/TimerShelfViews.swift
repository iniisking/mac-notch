import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Timer (compact + hover)

/// Resting state while a timer runs: its glyph in the left wing, time in the right wing.
struct CompactTimerView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var timers: TimerService

    var body: some View {
        let h = vm.geometry.notchSize.height
        let (left, right) = vm.wings
        if let t = timers.timer {
            HStack(spacing: 0) {
                Image(systemName: t.symbol)
                    .font(.system(size: min(15, h * 0.42), weight: .semibold))
                    .foregroundStyle(ContinuityColors.orange)
                    .symbolEffect(.pulse, isActive: t.isPaused)
                    .frame(width: left)
                Color.clear.frame(width: vm.gapWidth)
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    Text(t.display(at: ctx.date))
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(t.isPaused ? ContinuityColors.orange.opacity(0.5) : ContinuityColors.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: right)
            }
            .frame(height: h)
            .padding(.horizontal, vm.topRadius)
        }
    }
}

/// Hover card for the timer: name, progress, Pause / +1 min / Stop.
struct TimerPeekView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var timers: TimerService

    var body: some View {
        let h = vm.geometry.notchSize.height
        let side = (vm.shapeSize.width - vm.gapWidth) / 2 - vm.topRadius - 16
        if let t = timers.timer {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        Image(systemName: t.symbol).font(.system(size: 10, weight: .semibold))
                        Text(t.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: side, alignment: .leading)
                    Spacer(minLength: 0)
                    Text(t.isPaused ? "Paused" : (t.length == nil ? "Running" : "Left"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ContinuityColors.orange)
                        .frame(width: side, alignment: .trailing)
                }
                .frame(height: h)

                HStack(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(t.display(at: ctx.date))
                                .font(.system(size: 24, weight: .semibold).monospacedDigit())
                                .foregroundStyle(ContinuityColors.orange)
                            if let len = t.length, len > 0 {
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.12))
                                        Capsule().fill(ContinuityColors.orange)
                                            .frame(width: g.size.width * min(1, t.elapsed(at: ctx.date) / len))
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if t.length != nil {
                        Button { timers.addMinute() } label: { Text("+1 min") }
                            .buttonStyle(PillButtonStyle())
                    }
                    circleButton(t.isPaused ? "play.fill" : "pause.fill", help: t.isPaused ? "Resume" : "Pause") { timers.togglePause() }
                    circleButton("xmark", help: "Stop", tint: ContinuityColors.red.opacity(0.85)) { timers.stop() }
                }
                .padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, vm.topRadius + 16)
            .padding(.bottom, 10)
        }
    }

    private func circleButton(_ symbol: String, help: String, tint: Color = .white.opacity(0.14), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Drop zone with Shelf + AirDrop

/// Two targets while files are dragged over the notch: keep them on the Shelf, or AirDrop them.
struct FileDropTargets: View {
    @ObservedObject var vm: NotchViewModel
    @State private var shelfTargeted = false
    @State private var airTargeted = false

    var body: some View {
        let h = vm.geometry.notchSize.height
        let showShelf = vm.launcher.settings.shelfEnabled
        let showAir = vm.settings.airDropDropZone
        VStack(spacing: 0) {
            Color.clear.frame(height: h)
            HStack(spacing: 10) {
                if showShelf {
                    target(symbol: "tray.and.arrow.down.fill", title: "Shelf",
                           detail: shelfTargeted ? "Release to keep them here" : "Keep files for later",
                           color: ContinuityColors.orange, targeted: shelfTargeted)
                        .onDrop(of: [UTType.fileURL], isTargeted: $shelfTargeted) { providers in
                            DropZoneView.loadURLs(providers) { vm.shelveFiles($0) }
                            return true
                        }
                }
                if showAir {
                    target(symbol: "dot.radiowaves.up.forward", title: "AirDrop",
                           detail: airTargeted ? "Release to choose a device" : "Send to a nearby device",
                           color: ContinuityColors.blue, targeted: airTargeted)
                        .onDrop(of: [UTType.fileURL], isTargeted: $airTargeted) { providers in
                            DropZoneView.loadURLs(providers) { vm.dropFiles($0) }
                            return true
                        }
                }
            }
            .padding(.horizontal, vm.topRadius + 10)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.15), value: shelfTargeted)
        .animation(.easeOut(duration: 0.15), value: airTargeted)
    }

    private func target(symbol: String, title: String, detail: String, color: Color, targeted: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(color.opacity(targeted ? 0.45 : 0.22))
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            }
            .frame(width: 40, height: 40)
            .scaleEffect(targeted ? 1.08 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.white.opacity(targeted ? 0.7 : 0.3)))
        .contentShape(Rectangle())
    }
}

// MARK: - Expanded › Shelf

struct ShelfPage: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: ShelfStore
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shelf.items.isEmpty ? "Shelf" : "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") on the shelf")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !shelf.items.isEmpty {
                    Button { AirDropMonitor.send(shelf.items) } label: { Label("AirDrop All", systemImage: "dot.radiowaves.up.forward") }
                        .buttonStyle(PillButtonStyle())
                    Button { shelf.clear() } label: { Label("Clear", systemImage: "trash") }
                        .buttonStyle(PillButtonStyle())
                }
            }
            if shelf.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.3))
                    Text("Drag files onto the notch to keep them here,\nthen drag them out wherever you need them.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(shelf.items, id: \.self) { url in
                            ShelfTile(url: url, shelf: shelf)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.never)
                Text("Drag a file out to use it. It stays on the shelf until you remove it.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.top, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(dropTargeted ? 0.06 : 0)))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            DropZoneView.loadURLs(providers) { shelf.add($0) }
            return true
        }
    }
}

private struct ShelfTile: View {
    let url: URL
    @ObservedObject var shelf: ShelfStore
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: shelf.icon(url))
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5))
                .lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
                .frame(height: 28, alignment: .top)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hovering ? 0.1 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { shelf.remove(url) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Quick Look") { QuickLookSource.shared.show([url]) }
            Button("AirDrop") { AirDropMonitor.send([url]) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
            Divider()
            Button("Remove from Shelf") { shelf.remove(url) }
        }
        .help(url.path)
    }
}
