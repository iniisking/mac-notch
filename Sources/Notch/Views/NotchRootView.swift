import SwiftUI

struct NotchRootView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: NotificationStore
    @ObservedObject var settings: SettingsStore

    private var tint: Color {
        guard let n = vm.current else { return .white }
        return Color(nsColor: AppInfoProvider.shared.info(for: n.bundleID).tint)
    }

    private var glowOpacity: Double {
        switch vm.state {
        case .compact: return vm.glowPulse ? 0.95 : 0.5
        case .peek: return 0.25
        default: return 0
        }
    }

    var body: some View {
        let size = vm.shapeSize
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)
        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: tint.opacity(glowOpacity), radius: vm.glowPulse ? 14 : 9)
                .overlay(shape.stroke(tint.opacity(vm.state == .compact ? 0.35 : 0), lineWidth: 1))
                .frame(width: size.width, height: size.height)
                .opacity(vm.shapeOpacity)

            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: vm.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.current?.id)
        .animation(.easeInOut(duration: 0.35), value: vm.glowPulse)
    }

    @ViewBuilder private var content: some View {
        switch vm.state {
        case .idle:
            Color.clear
        case .compact:
            CompactView(vm: vm)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
                .contentShape(Rectangle())
                .onTapGesture { vm.expand() }
        case .peek:
            PeekView(vm: vm, store: store)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
                .contentShape(Rectangle())
                .onTapGesture { vm.expand() }
        case .expanded:
            ExpandedView(vm: vm, store: store, settings: settings)
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.15)),
                                        removal: .opacity.animation(.easeIn(duration: 0.1))))
        }
    }
}

// MARK: - Shared bits

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
