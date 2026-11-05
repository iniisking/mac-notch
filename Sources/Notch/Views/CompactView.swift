import SwiftUI

/// "Light up" state, Dynamic-Island sized. The app icon sits in the left wing beside the camera;
/// the label (sender / event / mail sender, never the app name) sits in a strip directly under
/// the notch, styled like the lyric line, scrolling if it's too long. The right wing only shows
/// a count when more notifications are queued.
struct CompactView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let g = vm.geometry
        let h = g.notchSize.height
        let (left, right) = vm.wings
        if let n = vm.current {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    AppIconView(bundleID: n.bundleID, size: min(22, h - 12))
                        .frame(width: left)
                    Color.clear.frame(width: vm.gapWidth)       // camera housing: never draw here
                    ZStack {
                        if vm.pendingCount > 0 {
                            Text("+\(vm.pendingCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(0.16)))
                        }
                    }
                    .frame(width: right)
                }
                .frame(height: h)

                MarqueeText(text: n.shortLabel, font: NotchViewModel.stripFont,
                            color: .white.opacity(0.92), height: 16, alignment: .center)
                    .padding(.horizontal, 10)
                    .frame(height: NotchViewModel.lyricStripHeight - 4, alignment: .top)
            }
            .padding(.horizontal, vm.topRadius)
            .id(n.id)
        }
    }
}
