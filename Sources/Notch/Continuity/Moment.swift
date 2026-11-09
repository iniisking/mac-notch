import AppKit
import SwiftUI

/// A brief "something happened" moment from another device or a Continuity feature: AirPods
/// connected, copied on the iPhone, AirDrop received, Focus changed, a meeting about to start,
/// an iPhone event from the Shortcuts bridge. Shown like the battery moment: one glyph per wing
/// and a "Title - detail" strip under the notch. Click to run its action.
struct Moment: Identifiable, Equatable {
    enum Kind: String { case audio, clipboard, airdrop, focus, hotspot, calendar, iphone, bridge }

    enum Glyph {
        case symbol(String, Color = .white)
        case image(NSImage)
        case appIcon(String)
        case text(String, Color = .white)
        case battery(Int, charging: Bool)
        case none
    }

    enum Action {
        case open(URL)
        case reveal([URL])
        case run(() -> Void)
    }

    let id = UUID()
    var kind: Kind
    var left: Glyph
    var right: Glyph
    var title: String
    var detail: String = ""
    var duration: TimeInterval = 3.5
    var action: Action?
    /// Hint shown in the strip on hover ("Click to open").
    var actionHint: String?

    static func == (a: Moment, b: Moment) -> Bool { a.id == b.id }

    func perform() {
        switch action {
        case .open(let url): NSWorkspace.shared.open(url)
        case .reveal(let urls): NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .run(let f): f()
        case nil: break
        }
    }
}

enum ContinuityColors {
    static let green = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    static let blue = Color(red: 0.25, green: 0.6, blue: 1)
    static let purple = Color(red: 0.62, green: 0.47, blue: 1)
    static let orange = Color(red: 1, green: 0.62, blue: 0.2)

    static func battery(_ pct: Int, charging: Bool = false) -> Color {
        if charging { return green }
        return pct <= 20 ? red : .white
    }
}
