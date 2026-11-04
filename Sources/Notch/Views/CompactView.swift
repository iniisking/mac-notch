import SwiftUI

/// "Light up" state: icon + app name in the left wing, one-line summary in the right wing.
struct CompactView: View {
    @ObservedObject var vm: NotchViewModel

    var body: some View {
        let g = vm.geometry
        let h = g.notchSize.height
        if let n = vm.current {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    AppIconView(bundleID: n.bundleID, size: min(22, h - 8))
                    Text(AppInfoProvider.shared.info(for: n.bundleID).name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(width: NotchViewModel.wing)

                Color.clear.frame(width: g.notchSize.width)

                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Text(n.summary)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if vm.pendingCount > 0 {
                        Text("+\(vm.pendingCount)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.2)))
                    }
                }
                .padding(.trailing, 12)
                .frame(width: NotchViewModel.wing)
            }
            .padding(.horizontal, vm.topRadius)
            .frame(height: h)
            .id(n.id)
        }
    }
}
