import SwiftUI

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: NotificationStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: NowPlayingService
    @ObservedObject var lyrics: LyricsService

    var body: some View {
        let size = vm.shapeSize
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)
        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .opacity(vm.shapeOpacity)

            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
                .mask(CameraExclusionMask(gap: vm.geometry.hasNotch ? vm.gapWidth : 0,
                                          height: vm.geometry.notchSize.height))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: vm.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.current?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: vm.showsLyricStrip)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: vm.peekHighlight?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: store.visibleHistory.count)
    }

    @ViewBuilder private var content: some View {
        switch vm.state {
        case .idle:
            Color.clear
        case .music:
            CompactMusicView(vm: vm, player: player, lyrics: lyrics)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
                .contentShape(Rectangle())
                .onTapGesture { vm.expand() }
        case .musicPeek:
            MusicPeekView(vm: vm, player: player, lyrics: lyrics, store: store)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        case .compact:
            CompactView(vm: vm)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let n = vm.current { vm.open(n) } }
                .onTapGesture { vm.expand() }
        case .peek:
            PeekView(vm: vm, store: store)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let n = vm.current { vm.open(n) } }
                .onTapGesture { vm.expand() }
        case .expanded:
            ExpandedView(vm: vm, store: store, settings: settings, player: player)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        }
    }
}

// MARK: - Shared bits

/// Opaque everywhere except a top-centred rect over the camera housing (+ clearance), so no
/// content can ever be drawn behind the camera, even mid-animation or mid-scroll.
struct CameraExclusionMask: View {
    let gap: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.black)
            if gap > 0 {
                Rectangle().fill(.black).frame(width: gap, height: height).blendMode(.destinationOut)
            }
        }
        .compositingGroup()
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 20
    var body: some View {
        Image(nsImage: AppInfoProvider.shared.info(for: bundleID).icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.75 : 0.9)
                                         : Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .foregroundStyle(prominent ? Color.black : Color.white)
    }
}

extension Date {
    var notchRelative: String {
        let s = Date().timeIntervalSince(self)
        if s < 60 { return "now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: self, relativeTo: Date())
    }
}
