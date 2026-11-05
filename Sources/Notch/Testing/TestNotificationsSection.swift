import SwiftUI

/// Settings › Test notifications.
struct TestNotificationsSection: View {
    @ObservedObject var store: NotificationStore
    @ObservedObject var notifier: SystemTestNotifier

    @State private var appID = TestPreset.installedCustomApps.first?.bundleID ?? "com.apple.MobileSMS"
    @State private var useOtherID = false
    @State private var otherID = ""
    @State private var title = "Grace Hopper"
    @State private var subtitle = ""
    @State private var bodyText = "Found the bug: it was a moth. 🦋"

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(TestPreset.allCases) { preset in
                    Button {
                        store.injectTest(preset.make())
                    } label: {
                        HStack(spacing: 6) {
                            AppIconView(bundleID: preset.make().bundleID, size: 16)
                            Text(preset.title).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button {
                    for (i, p) in [TestPreset.whatsapp, .mail, .calendar].enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.25) { store.injectTest(p.make()) }
                    }
                } label: {
                    Label("Burst of 3", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            DisclosureGroup("Custom notification") {
                Picker("App", selection: $appID) {
                    ForEach(TestPreset.installedCustomApps, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .disabled(useOtherID)
                Toggle("Use another bundle id", isOn: $useOtherID)
                if useOtherID {
                    TextField("Bundle id", text: $otherID, prompt: Text("com.example.app"))
                }
                TextField("Title", text: $title)
                TextField("Subtitle", text: $subtitle)
                TextField("Body", text: $bodyText, axis: .vertical).lineLimit(2...5)
                HStack {
                    Spacer()
                    Button("Send") {
                        let bundle = useOtherID ? otherID.trimmingCharacters(in: .whitespaces) : appID
                        store.injectTest(TestPreset.item(bundle: bundle.isEmpty ? "com.apple.MobileSMS" : bundle,
                                                         title: title, subtitle: subtitle, body: bodyText))
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.isEmpty && bodyText.isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Button("Send real system notification", action: notifier.send)
                Text(notifier.status.isEmpty
                     ? "Posts an actual macOS notification from Notch and lets it come back through Notification Center's database: the same path as real notifications, including with Focus on. It can take a second or two to appear."
                     : notifier.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Test notifications")
        } footer: {
            Text("Test items behave like real ones but aren't saved to history.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
