import AppKit

/// Resolves a bundle id to an app name, icon and a tint colour (cached).
@MainActor
final class AppInfoProvider {
    struct Info {
        let name: String
        let icon: NSImage
        let url: URL?
        let tint: NSColor
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
            info = Info(name: name, icon: icon, url: url, tint: Self.tint(of: icon))
        } else {
            let icon = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) ?? NSImage()
            info = Info(name: bundleID.split(separator: ".").last.map(String.init) ?? bundleID,
                        icon: icon, url: nil, tint: .systemBlue)
        }
        cache[key] = info
        return info
    }

    /// Average colour of the icon, pushed towards a vivid, bright tone for the glow.
    private static func tint(of image: NSImage) -> NSColor {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)
        else { return .systemBlue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let c = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return .systemBlue }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.15 { return NSColor(white: 0.95, alpha: 1) }
        return NSColor(hue: h, saturation: max(s, 0.55), brightness: max(b, 0.9), alpha: 1)
    }
}
