import SwiftUI

/// "Light up" state, Dynamic-Island sized: app icon in the small left wing, the sender / event
/// label right of the camera (marquee if it's longer than the capped right wing). No app name.
struct CompactView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let g = vm.geometry
        let h = g.notchSize.height
        let (left, right) = vm.wings
        if let n = vm.current {
            HStack(spacing: 0) {
                AppIconView(bundleID: n.bundleID, size: min(22, h - 12))
                    .frame(width: left)
                Color.clear.frame(width: g.notchSize.width)
                MarqueeText(text: n.shortLabel, font: Font(NotchViewModel.labelFont), height: 16)
                    .padding(.leading, 4)
                    .padding(.trailing, 8)
                .frame(width: right, height: h)
            }
            .padding(.horizontal, vm.topRadius)
            .frame(height: h)
            .id(n.id)
        }
    }
}
