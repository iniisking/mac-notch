import SwiftUI

/// Hover state: a card with title, subtitle and a few lines of body.
struct PeekView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: NotificationStore

    var body: some View {
        let g = vm.geometry
        let sideWidth = max(80, (vm.shapeSize.width - g.notchSize.width) / 2 - vm.topRadius - 16)
        VStack(alignment: .leading, spacing: 0) {
            // Top band beside the camera housing.
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    if let n = vm.current {
                        AppIconView(bundleID: n.bundleID, size: min(20, g.notchSize.height - 8))
                        Text(AppInfoProvider.shared.info(for: n.bundleID).name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        Image(systemName: "bell").foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: sideWidth)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if vm.pendingCount > 0 {
                        Text("+\(vm.pendingCount) more").foregroundStyle(.white.opacity(0.5))
                    }
                    if let n = vm.current { Text(n.date.notchRelative).foregroundStyle(.white.opacity(0.5)) }
                }
                .font(.system(size: 11))
                .frame(width: sideWidth)
            }
            .frame(height: g.notchSize.height)

            Group {
                if store.status.needsFullDiskAccess && vm.current == nil {
                    FullDiskAccessPrompt(compact: true, action: vm.openFullDiskAccess)
                } else if let n = vm.current {
                    VStack(alignment: .leading, spacing: 3) {
                        if !n.title.isEmpty {
                            Text(n.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        if !n.subtitle.isEmpty {
                            Text(n.subtitle).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        }
                        if !n.body.isEmpty {
                            Text(n.body).font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(n.subtitle.isEmpty ? 3 : 2)
                        }
                    }
                } else {
                    Text("No notifications yet").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)

            Spacer(minLength: 0)
            Text("Click to open")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, vm.topRadius + 16)
    }
}

struct FullDiskAccessPrompt: View {
    var compact = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Full Disk Access needed", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
            if !compact {
                Text("Notch reads Notification Center's database so it works while Focus silences banners. Allow Notch in Privacy & Security › Full Disk Access, then relaunch it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Privacy Settings", action: action)
                .buttonStyle(PillButtonStyle(prominent: true))
        }
    }
}
