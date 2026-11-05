import AppKit
import SwiftUI

/// Click state: recent list grouped by app on the left, full detail with actions on the right.
struct ExpandedView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var store: NotificationStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var player: NowPlayingService
    @State private var copiedID: String?

    private struct AppGroup: Identifiable {
        let bundleID: String
        let items: [NotchNotification]
        var id: String { bundleID }
    }

    private var groups: [AppGroup] {
        var order: [String] = []
        var map: [String: [NotchNotification]] = [:]
        for n in store.visibleHistory {
            let key = n.bundleID.lowercased()
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(n)
        }
        return order.map { AppGroup(bundleID: map[$0]![0].bundleID, items: map[$0]!) }
    }

    private var selected: NotchNotification? {
        let all = store.visibleHistory
        return all.first { $0.id == vm.selectedID } ?? all.first
    }

    var body: some View {
        let g = vm.geometry
        let sideWidth = (vm.shapeSize.width - vm.gapWidth) / 2 - vm.topRadius - 18
        VStack(spacing: 0) {
            // Top band beside the camera housing.
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("Notifications").font(.system(size: 12, weight: .semibold))
                    Text("\(store.visibleHistory.count)")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.15)))
                    Spacer(minLength: 0)
                }
                .frame(width: sideWidth)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    iconButton("trash", help: "Clear all") { store.clearAll() }
                        .disabled(store.visibleHistory.isEmpty)
                    iconButton("gearshape", help: "Settings") { vm.openSettings() }
                    iconButton("chevron.up", help: "Close") { vm.collapse() }
                }
                .frame(width: sideWidth)
            }
            .frame(height: max(g.notchSize.height, 28))

            if player.hasSession {
                PlayerControlsView(player: player, artSize: 52)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
                    .padding(.top, 6)
            }

            if store.status.needsFullDiskAccess {
                FullDiskAccessPrompt(action: vm.openFullDiskAccess)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.18)))
                    .padding(.top, 6)
            }

            if store.visibleHistory.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash").font(.system(size: 22))
                    Text("Nothing here yet").font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 230)
                    Rectangle().fill(.white.opacity(0.1)).frame(width: 1).padding(.vertical, 8)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, vm.topRadius + 16)
        .padding(.bottom, 16)
    }

    // MARK: - List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                ForEach(groups) { group in
                    HStack(spacing: 6) {
                        AppIconView(bundleID: group.bundleID, size: 14)
                        Text(AppInfoProvider.shared.info(for: group.bundleID).name)
                            .font(.system(size: 10, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Text("\(group.items.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 8).padding(.bottom, 2)

                    ForEach(group.items) { n in
                        row(n)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    private func row(_ n: NotchNotification) -> some View {
        let isSelected = n.id == selected?.id
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(n.summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(n.date.notchRelative).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            if !n.body.isEmpty, n.body != n.summary {
                Text(n.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(isSelected ? 0.14 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.open(n) }
        .onTapGesture { vm.selectedID = n.id }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let n = selected {
            let info = AppInfoProvider.shared.info(for: n.bundleID)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AppIconView(bundleID: n.bundleID, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.name).font(.system(size: 12, weight: .semibold))
                        Text(n.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    if n.isTest {
                        Text("TEST").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().stroke(.white.opacity(0.4)))
                    }
                }
                if !n.title.isEmpty {
                    Text(n.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                }
                if !n.subtitle.isEmpty {
                    Text(n.subtitle).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
                }
                ScrollView(.vertical) {
                    Text(n.body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 8) {
                    let exact = NotificationOpener.deepLink(for: n) != nil
                    Button {
                        vm.open(n)
                    } label: {
                        Label(exact ? "Open conversation" : "Open \(info.name)",
                              systemImage: exact ? "bubble.left.and.text.bubble.right" : "arrow.up.forward.app")
                    }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(info.url == nil && !exact)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(n.fullText, forType: .string)
                        copiedID = n.id
                    } label: {
                        Label(copiedID == n.id ? "Copied" : "Copy", systemImage: copiedID == n.id ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(PillButtonStyle())

                    Button {
                        let next = nextSelection(after: n)
                        store.dismiss(n.id)
                        vm.selectedID = next
                    } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                    .buttonStyle(PillButtonStyle())
                    Spacer()
                }
            }
            .padding(.leading, 14)
            .padding(.top, 4)
        }
    }

    private func nextSelection(after n: NotchNotification) -> String? {
        let all = store.visibleHistory
        guard let i = all.firstIndex(where: { $0.id == n.id }) else { return nil }
        if i + 1 < all.count { return all[i + 1].id }
        return i > 0 ? all[i - 1].id : nil
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
