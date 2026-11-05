import AppKit

/// Where the hardware notch is (or a virtual pill on screens without one).
struct NotchGeometry: Equatable {
    let hasNotch: Bool
    /// Hardware notch size. On notch-less screens: width 0, height = menu bar height.
    let notchSize: CGSize
    let screenFrame: CGRect
    /// The camera housing in global screen coordinates: from the right edge of
    /// auxiliaryTopLeftArea to the left edge of auxiliaryTopRightArea. Nothing may draw here.
    /// On notch-less screens it's a zero-width rect at the top centre.
    let notchRect: CGRect

    static func detect(for screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        let f = screen.frame
        if top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            // The aux rects may be reported screen-local or global depending on the display's
            // position; normalise to global.
            let toGlobal: (CGFloat) -> CGFloat = { x in
                (abs(l.minX - f.minX) < 1) ? x : x + f.minX
            }
            var minX = toGlobal(l.maxX), maxX = toGlobal(r.minX)
            if maxX - minX <= 0 || maxX - minX > 400 {          // defensive: odd values
                minX = f.midX - 100; maxX = f.midX + 100
            }
            let rect = CGRect(x: minX, y: f.maxY - top, width: maxX - minX, height: top)
            return NotchGeometry(hasNotch: true, notchSize: rect.size, screenFrame: f, notchRect: rect)
        }
        var menuBar = f.maxY - screen.visibleFrame.maxY
        if menuBar < 20 { menuBar = 24 }   // auto-hidden menu bar
        return NotchGeometry(hasNotch: false, notchSize: CGSize(width: 0, height: menuBar), screenFrame: f,
                             notchRect: CGRect(x: f.midX, y: f.maxY - menuBar, width: 0, height: menuBar))
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
