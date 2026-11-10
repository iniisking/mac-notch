import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Moves and resizes the frontmost window with the Accessibility API (halves, thirds, quarters,
/// maximize, center, other display, restore).
@MainActor
enum WindowManager {
    enum Layout: String, CaseIterable {
        case leftHalf, rightHalf, topHalf, bottomHalf
        case topLeft, topRight, bottomLeft, bottomRight
        case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
        case maximize, almostMaximize, maximizeHeight, center, reasonableSize
        case nextDisplay, previousDisplay, restore

        var title: String {
            switch self {
            case .leftHalf: return "Left Half"
            case .rightHalf: return "Right Half"
            case .topHalf: return "Top Half"
            case .bottomHalf: return "Bottom Half"
            case .topLeft: return "Top Left Quarter"
            case .topRight: return "Top Right Quarter"
            case .bottomLeft: return "Bottom Left Quarter"
            case .bottomRight: return "Bottom Right Quarter"
            case .firstThird: return "First Third"
            case .centerThird: return "Center Third"
            case .lastThird: return "Last Third"
            case .firstTwoThirds: return "First Two Thirds"
            case .lastTwoThirds: return "Last Two Thirds"
            case .maximize: return "Maximize"
            case .almostMaximize: return "Almost Maximize"
            case .maximizeHeight: return "Maximize Height"
            case .center: return "Center"
            case .reasonableSize: return "Reasonable Size"
            case .nextDisplay: return "Next Display"
            case .previousDisplay: return "Previous Display"
            case .restore: return "Restore"
            }
        }

        var symbol: String {
            switch self {
            case .leftHalf: return "rectangle.lefthalf.filled"
            case .rightHalf: return "rectangle.righthalf.filled"
            case .topHalf: return "rectangle.tophalf.filled"
            case .bottomHalf: return "rectangle.bottomhalf.filled"
            case .topLeft: return "rectangle.inset.topleft.filled"
            case .topRight: return "rectangle.inset.topright.filled"
            case .bottomLeft: return "rectangle.inset.bottomleft.filled"
            case .bottomRight: return "rectangle.inset.bottomright.filled"
            case .firstThird, .firstTwoThirds: return "rectangle.leadingthird.inset.filled"
            case .centerThird: return "rectangle.center.inset.filled"
            case .lastThird, .lastTwoThirds: return "rectangle.trailingthird.inset.filled"
            case .maximize, .almostMaximize: return "rectangle.inset.filled"
            case .maximizeHeight: return "arrow.up.and.down.square"
            case .center, .reasonableSize: return "rectangle.center.inset.filled"
            case .nextDisplay: return "arrow.right.to.line.square"
            case .previousDisplay: return "arrow.left.to.line.square"
            case .restore: return "arrow.uturn.backward.square"
            }
        }

        /// Rectangle-style defaults (⌃⌥ + key), used when "Window shortcuts" is on.
        var defaultHotKey: KeyCombo? {
            let co: NSEvent.ModifierFlags = [.control, .option]
            switch self {
            case .leftHalf: return KeyCombo(keyCode: kVK_LeftArrow, modifiers: co)
            case .rightHalf: return KeyCombo(keyCode: kVK_RightArrow, modifiers: co)
            case .topHalf: return KeyCombo(keyCode: kVK_UpArrow, modifiers: co)
            case .bottomHalf: return KeyCombo(keyCode: kVK_DownArrow, modifiers: co)
            case .topLeft: return KeyCombo(keyCode: kVK_ANSI_U, modifiers: co)
            case .topRight: return KeyCombo(keyCode: kVK_ANSI_I, modifiers: co)
            case .bottomLeft: return KeyCombo(keyCode: kVK_ANSI_J, modifiers: co)
            case .bottomRight: return KeyCombo(keyCode: kVK_ANSI_K, modifiers: co)
            case .firstThird: return KeyCombo(keyCode: kVK_ANSI_D, modifiers: co)
            case .centerThird: return KeyCombo(keyCode: kVK_ANSI_F, modifiers: co)
            case .lastThird: return KeyCombo(keyCode: kVK_ANSI_G, modifiers: co)
            case .firstTwoThirds: return KeyCombo(keyCode: kVK_ANSI_E, modifiers: co)
            case .lastTwoThirds: return KeyCombo(keyCode: kVK_ANSI_T, modifiers: co)
            case .maximize: return KeyCombo(keyCode: kVK_Return, modifiers: co)
            case .center: return KeyCombo(keyCode: kVK_ANSI_C, modifiers: co)
            case .maximizeHeight: return KeyCombo(keyCode: kVK_UpArrow, modifiers: [.control, .option, .shift])
            case .nextDisplay: return KeyCombo(keyCode: kVK_RightArrow, modifiers: [.control, .option, .command])
            case .previousDisplay: return KeyCombo(keyCode: kVK_LeftArrow, modifiers: [.control, .option, .command])
            case .restore: return KeyCombo(keyCode: kVK_Delete, modifiers: co)
            case .almostMaximize, .reasonableSize: return nil
            }
        }
    }

    /// Frames before the last move, for Restore.
    private static var history: [(window: AXUIElement, frame: CGRect)] = []

    static func apply(_ layout: Layout) {
        guard Keystrokes.isTrusted else {
            Keystrokes.requestTrust()
            return
        }
        guard let win = focusedWindow(), let current = frame(of: win) else {
            NSSound.beep()
            return
        }
        if layout == .restore {
            guard let i = history.lastIndex(where: { CFEqual($0.window, win) }) else { return }
            setFrame(history[i].frame, of: win)
            history.remove(at: i)
            return
        }
        let screens = NSScreen.screens
        guard let screen = screen(containing: current) else { return }
        var target: NSScreen = screen
        if layout == .nextDisplay || layout == .previousDisplay {
            guard screens.count > 1, let i = screens.firstIndex(of: screen) else { return }
            target = screens[(i + (layout == .nextDisplay ? 1 : screens.count - 1)) % screens.count]
        }
        let v = axRect(target.visibleFrame)   // top-left origin
        var r = current
        let w = v.width, h = v.height
        switch layout {
        case .leftHalf: r = CGRect(x: v.minX, y: v.minY, width: w / 2, height: h)
        case .rightHalf: r = CGRect(x: v.minX + w / 2, y: v.minY, width: w / 2, height: h)
        case .topHalf: r = CGRect(x: v.minX, y: v.minY, width: w, height: h / 2)
        case .bottomHalf: r = CGRect(x: v.minX, y: v.minY + h / 2, width: w, height: h / 2)
        case .topLeft: r = CGRect(x: v.minX, y: v.minY, width: w / 2, height: h / 2)
        case .topRight: r = CGRect(x: v.minX + w / 2, y: v.minY, width: w / 2, height: h / 2)
        case .bottomLeft: r = CGRect(x: v.minX, y: v.minY + h / 2, width: w / 2, height: h / 2)
        case .bottomRight: r = CGRect(x: v.minX + w / 2, y: v.minY + h / 2, width: w / 2, height: h / 2)
        case .firstThird: r = CGRect(x: v.minX, y: v.minY, width: w / 3, height: h)
        case .centerThird: r = CGRect(x: v.minX + w / 3, y: v.minY, width: w / 3, height: h)
        case .lastThird: r = CGRect(x: v.minX + 2 * w / 3, y: v.minY, width: w / 3, height: h)
        case .firstTwoThirds: r = CGRect(x: v.minX, y: v.minY, width: 2 * w / 3, height: h)
        case .lastTwoThirds: r = CGRect(x: v.minX + w / 3, y: v.minY, width: 2 * w / 3, height: h)
        case .maximize: r = v
        case .almostMaximize: r = v.insetBy(dx: w * 0.05, dy: h * 0.05)
        case .maximizeHeight: r = CGRect(x: current.minX, y: v.minY, width: current.width, height: h)
        case .center:
            r = CGRect(x: v.midX - current.width / 2, y: v.midY - current.height / 2, width: current.width, height: current.height)
        case .reasonableSize:
            let size = CGSize(width: min(w * 0.6, 1280), height: min(h * 0.75, 900))
            r = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        case .nextDisplay, .previousDisplay:
            // Keep the relative position and size on the other display.
            let from = axRect(screen.visibleFrame)
            let fx = (current.minX - from.minX) / from.width, fy = (current.minY - from.minY) / from.height
            let fw = min(1, current.width / from.width), fh = min(1, current.height / from.height)
            r = CGRect(x: v.minX + fx * w, y: v.minY + fy * h, width: fw * w, height: fh * h)
        case .restore: break
        }
        history.removeAll { CFEqual($0.window, win) }
        history.append((win, current))
        if history.count > 40 { history.removeFirst() }
        setFrame(r.integral, of: win)
    }

    private static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &value) == .success, let v = value {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(el, kAXMainWindowAttribute as CFString, &value) == .success, let v = value {
            return (v as! AXUIElement)
        }
        return nil
    }

    private static func frame(of w: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func setFrame(_ r: CGRect, of w: AXUIElement) {
        var p = r.origin, s = r.size
        // Size, position, size again: apps that clamp size relative to the current screen settle correctly.
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv) }
    }

    /// Cocoa (bottom-left origin) → AX (top-left of the primary display).
    private static func axRect(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func screen(containing axFrame: CGRect) -> NSScreen? {
        let center = CGPoint(x: axFrame.midX, y: axFrame.midY)
        return NSScreen.screens.first { axRect($0.frame).contains(center) }
            ?? NSScreen.screens.max { axRect($0.frame).intersection(axFrame).area < axRect($1.frame).intersection(axFrame).area }
    }

    static func items(query: String) -> [LauncherItem] {
        Layout.allCases.compactMap { layout in
            let s = FuzzyMatch.best(query, title: layout.title, keywords: ["window " + layout.title, "resize", "snap", "move window"])
            guard s > 0 else { return nil }
            var item = LauncherItem(
                id: "window:\(layout.rawValue)", title: layout.title, subtitle: "Window",
                icon: .symbol(layout.symbol, LauncherColors.teal), accessory: "Window",
                section: "Window Management",
                actions: [LauncherAction(title: "Apply", symbol: layout.symbol) { m in
                    m.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { apply(layout) }
                }],
                learnKey: "window:\(layout.rawValue)")
            // Window layouts only show up when asked for (they'd crowd generic searches otherwise).
            item.score = query.isEmpty ? 0 : s * 0.9
            return item
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
