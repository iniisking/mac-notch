import AppKit

/// Resolves a bundle id to an app name and icon (cached).
@MainActor
final class AppInfoProvider {
    struct Info {
        let name: String
        let icon: NSImage
        let url: URL?
    }

    static let shared = AppInfoProvider()
    private var cache: [String: Info] = [:]

    func info(for bundleID: String) -> Info {
        let key = bundleID.lowercased()
        if let hit = cache[key] { return hit }
        let info: Info
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            info = Info(name: name, icon: icon, url: url)
        } else {
            let icon = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage()
            info = Info(name: bundleID.split(separator: ".").last.map(String.init) ?? bundleID,
                        icon: icon, url: nil)
        }
        cache[key] = info
        return info
    }
}
