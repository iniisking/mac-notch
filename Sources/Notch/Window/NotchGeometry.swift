import AppKit

/// Where the hardware notch is (or a virtual pill on screens without one).
struct NotchGeometry: Equatable {
    let hasNotch: Bool
    /// Hardware notch size. On notch-less screens: width 0, height = menu bar height.
    let notchSize: CGSize
    let screenFrame: CGRect

    static func detect(for screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            var width = screen.frame.width - left - right
            if width <= 0 || width > 400 { width = 200 }   // defensive: odd values
            return NotchGeometry(hasNotch: true, notchSize: CGSize(width: width, height: top),
                                 screenFrame: screen.frame)
        }
        var menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        if menuBar < 20 { menuBar = 24 }   // auto-hidden menu bar
        return NotchGeometry(hasNotch: false, notchSize: CGSize(width: 0, height: menuBar),
                             screenFrame: screen.frame)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        guard let id = displayID else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }
}
