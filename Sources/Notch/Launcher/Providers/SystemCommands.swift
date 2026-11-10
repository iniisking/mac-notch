import AppKit
import Carbon.HIToolbox
import SwiftUI
import Vision

/// Built-in commands: system actions, Notch pages, launcher modes, utilities.
@MainActor
enum SystemCommands {
    struct Command {
        var id: String
        var title: String
        var subtitle: String? = nil
        var symbol: String
        var keywords: [String] = []
        /// Needs a second ↩ (for things that are hard to undo).
        var confirm: String? = nil
        var run: @MainActor (LauncherModel) -> Void
    }

    /// `everything`: include commands that only show in some states (pause/stop timer, caffeinate
    /// on/off), so they can carry a hotkey.
    static func all(_ s: LauncherServices, everything: Bool = false) -> [(Command, color: SwiftUI.Color)] {
        var out: [(Command, SwiftUI.Color)] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ color: SwiftUI.Color, subtitle: String? = nil,
                 keywords: [String] = [], confirm: String? = nil, _ run: @escaping @MainActor (LauncherModel) -> Void) {
            out.append((Command(id: id, title: title, subtitle: subtitle, symbol: symbol,
                                keywords: keywords, confirm: confirm, run: run), color))
        }

        // Launcher modes
        add("mode.clipboard", "Clipboard History", "doc.on.clipboard", LauncherColors.indigo,
            subtitle: s.settings.clipboardHotKey?.display, keywords: ["paste", "copy", "history"]) { $0.push(.clipboard) }
        add("mode.emoji", "Search Emoji & Symbols", "face.smiling", LauncherColors.yellow,
            subtitle: s.settings.emojiHotKey?.display, keywords: ["emoji", "emoticon", "symbol", "character"]) { $0.push(.emoji) }
        add("mode.kaomoji", "Kaomoji", "face.smiling.inverse", LauncherColors.pink, keywords: ["shrug", "table flip", "japanese"]) { $0.push(.kaomoji) }
        add("mode.snippets", "Search Snippets", "text.quote", LauncherColors.indigo, keywords: ["text", "expand", "template"]) { $0.push(.snippets) }
        add("mode.files", "Search Files", "doc.text.magnifyingglass", LauncherColors.blue, keywords: ["find", "spotlight", "document"]) { $0.push(.files) }
        add("mode.running", "Quit Applications", "xmark.app", LauncherColors.red, keywords: ["kill", "force quit", "running", "close app"]) { $0.push(.running) }
        add("mode.shortcuts", "Run Shortcut", "square.2.layers.3d", LauncherColors.pink, keywords: ["shortcuts", "automation", "workflow"]) { $0.push(.shortcuts) }
        add("mode.windows", "Window Management", "macwindow", LauncherColors.teal, keywords: ["resize", "snap", "layout", "tile"]) { $0.push(.windows) }

        // Notch
        add("notch.shelf", "Open Shelf", "tray.full", LauncherColors.brown, keywords: ["files", "drop", "stash"]) { m in
            m.hide(); s.showShelf()
        }
        add("notch.notifications", "Notification History", "bell.badge", LauncherColors.red, keywords: ["notifications"]) { m in
            m.hide(); s.showNotifications()
        }
        add("notch.settings", "Notch Settings", "gearshape", LauncherColors.gray, keywords: ["preferences", "config"]) { m in
            m.hide(); s.openSettings(.general)
        }
        add("notch.clearclipboard", "Clear Clipboard History", "trash", LauncherColors.red, keywords: ["delete history"],
            confirm: "Press ↩ again to delete all unpinned clipboard history") { m in
            s.clipboard.clear(); m.hide(toast: "Clipboard history cleared")
        }

        // Timers
        add("timer.stopwatch", "Start Stopwatch", "stopwatch", LauncherColors.orange, keywords: ["timer", "count up"]) { m in
            s.timers.startStopwatch(); m.hide()
        }
        add("timer.pomodoro", "Start Pomodoro", "brain.head.profile", LauncherColors.orange,
            subtitle: "\(s.settings.pomodoroWork) min focus, \(s.settings.pomodoroBreak) min break", keywords: ["focus", "timer", "work"]) { m in
            s.timers.startPomodoro(); m.hide()
        }
        if s.timers.timer != nil || everything {
            add("timer.pause", s.timers.timer?.isPaused == true ? "Resume Timer" : "Pause Timer", "playpause", LauncherColors.orange) { m in
                s.timers.togglePause(); m.hide()
            }
            add("timer.stop", "Stop Timer", "stop.circle", LauncherColors.orange) { m in s.timers.stop(); m.hide() }
        }

        // Caffeinate
        add("caffeinate.toggle", s.timers.isCaffeinated ? "Turn Off Caffeinate" : "Toggle Caffeinate", "cup.and.saucer.fill", LauncherColors.brown,
            subtitle: s.timers.isCaffeinated ? "The Mac is being kept awake" : "Keep the Mac awake / allow sleep",
            keywords: ["caffeinate", "awake", "sleep"]) { m in
            s.timers.isCaffeinated ? s.timers.decaffeinate() : s.timers.caffeinate(for: nil); m.hide()
        }
        if everything {
            add("caffeinate.off", "Decaffeinate", "cup.and.saucer", LauncherColors.brown, subtitle: "Allow sleep again",
                keywords: ["caffeinate", "sleep", "awake"]) { m in s.timers.decaffeinate(); m.hide() }
            add("caffeinate.on", "Caffeinate", "cup.and.saucer.fill", LauncherColors.brown, subtitle: "Keep the Mac awake until turned off",
                keywords: ["awake", "no sleep", "amphetamine", "keep awake"]) { m in s.timers.caffeinate(for: nil); m.hide() }
            add("caffeinate.1h", "Caffeinate for 1 Hour", "cup.and.saucer.fill", LauncherColors.brown, keywords: ["awake"]) { m in
                s.timers.caffeinate(for: 3600); m.hide()
            }
        } else if s.timers.isCaffeinated {
            add("caffeinate.off", "Decaffeinate", "cup.and.saucer", LauncherColors.brown, subtitle: "Allow sleep again",
                keywords: ["caffeinate", "sleep", "awake"]) { m in s.timers.decaffeinate(); m.hide() }
        } else {
            add("caffeinate.on", "Caffeinate", "cup.and.saucer.fill", LauncherColors.brown, subtitle: "Keep the Mac awake until turned off",
                keywords: ["awake", "no sleep", "amphetamine", "keep awake"]) { m in s.timers.caffeinate(for: nil); m.hide() }
            add("caffeinate.1h", "Caffeinate for 1 Hour", "cup.and.saucer.fill", LauncherColors.brown, keywords: ["awake"]) { m in
                s.timers.caffeinate(for: 3600); m.hide()
            }
        }

        // Utilities
        add("util.colorpicker", "Pick Color", "eyedropper", LauncherColors.purple, subtitle: "Copies the hex value",
            keywords: ["color", "colour", "eyedropper", "hex"]) { m in
            m.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { pickColor(s) }
        }
        add("util.ocr", "Copy Text from Screen", "text.viewfinder", LauncherColors.purple, subtitle: "Select an area; its text is copied (OCR)",
            keywords: ["ocr", "recognize", "screenshot text", "extract text"]) { m in
            m.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { captureText(s) }
        }
        add("util.screenshot", "Screenshot to Clipboard", "camera.viewfinder", LauncherColors.purple, subtitle: "Select an area",
            keywords: ["capture", "screen"]) { m in
            m.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { run("/usr/sbin/screencapture", ["-i", "-c"]) }
        }
        add("util.capture", "Quick Note", "square.and.pencil", LauncherColors.yellow,
            subtitle: "Type “note …” to append to \((s.settings.notesFile as NSString).lastPathComponent)", keywords: ["jot", "write"]) { m in
            m.setQuery("note ")
        }
        add("util.reminder", "Create Reminder", "checklist", LauncherColors.orange, subtitle: "Type “remind …” (e.g. remind call mum tomorrow 6pm)",
            keywords: ["todo", "task", "reminders"]) { m in
            m.setQuery("remind ")
        }
        add("util.mirroring", "iPhone Mirroring", "iphone", LauncherColors.gray, keywords: ["phone", "continuity"]) { m in
            QuickActions.openMirroring(); m.hide()
        }

        // System
        add("sys.lock", "Lock Screen", "lock.fill", LauncherColors.gray, keywords: ["lock"]) { m in
            m.hide(); lockScreen()
        }
        add("sys.sleep", "Sleep", "moon.zzz.fill", LauncherColors.indigo, keywords: ["suspend"]) { m in
            m.hide(); run("/usr/bin/pmset", ["sleepnow"])
        }
        add("sys.displaysleep", "Sleep Displays", "display", LauncherColors.indigo, keywords: ["screen off", "monitor"]) { m in
            m.hide(); run("/usr/bin/pmset", ["displaysleepnow"])
        }
        add("sys.restart", "Restart…", "restart", LauncherColors.red, subtitle: "macOS asks to confirm", keywords: ["reboot"]) { m in
            m.hide(); AppleScriptRunner.run("tell application \"loginwindow\" to «event aevtrrst»") { _ in }
        }
        add("sys.shutdown", "Shut Down…", "power", LauncherColors.red, subtitle: "macOS asks to confirm", keywords: ["power off", "turn off"]) { m in
            m.hide(); AppleScriptRunner.run("tell application \"loginwindow\" to «event aevtrsdn»") { _ in }
        }
        add("sys.logout", "Log Out…", "rectangle.portrait.and.arrow.right", LauncherColors.red, subtitle: "macOS asks to confirm",
            keywords: ["sign out"]) { m in
            m.hide(); AppleScriptRunner.run("tell application \"loginwindow\" to «event aevtlogo»") { _ in }
        }
        add("sys.darkmode", "Toggle Dark Mode", "circle.lefthalf.filled", LauncherColors.gray, keywords: ["appearance", "light mode", "theme"]) { m in
            m.hide()
            AppleScriptRunner.run("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode") { _ in }
        }
        add("sys.emptytrash", "Empty Trash", "trash.fill", LauncherColors.red, keywords: ["bin", "delete"],
            confirm: "Press ↩ again to permanently delete everything in the Trash") { m in
            m.hide(toast: "Emptying Trash")
            AppleScriptRunner.run("tell application \"Finder\" to empty trash", timeout: 60) { _ in }
        }
        add("sys.eject", "Eject All Disks", "eject.fill", LauncherColors.gray, keywords: ["unmount", "usb", "drive"]) { m in
            m.hide(toast: "Ejecting disks")
            AppleScriptRunner.run("tell application \"Finder\" to eject (every disk whose ejectable is true)", timeout: 30) { _ in }
        }
        add("sys.mute", "Toggle Mute", "speaker.slash.fill", LauncherColors.gray, keywords: ["volume", "sound", "audio"]) { m in
            m.hide(); AppleScriptRunner.run("set volume output muted not (output muted of (get volume settings))") { _ in }
        }
        add("sys.hiddenfiles", "Toggle Hidden Files in Finder", "eye", LauncherColors.gray, keywords: ["dotfiles", "show hidden"]) { m in
            m.hide()
            let on = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false
            run("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "false" : "true"]) {
                run("/usr/bin/killall", ["Finder"])
            }
        }
        add("sys.desktopicons", "Toggle Desktop Icons", "menubar.dock.rectangle", LauncherColors.gray, keywords: ["hide desktop", "clean desktop"]) { m in
            m.hide()
            let shown = UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool ?? true
            run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", shown ? "false" : "true"]) {
                run("/usr/bin/killall", ["Finder"])
            }
        }
        add("sys.wifi", "Toggle Wi-Fi", "wifi", LauncherColors.blue, keywords: ["wireless", "internet", "network"]) { m in
            m.hide(); toggleWiFi()
        }
        add("sys.showdesktop", "Show Desktop", "desktopcomputer", LauncherColors.gray, keywords: ["hide windows"]) { m in
            m.hide()
            // F11 / Mission Control "Show Desktop" (fn+F11 equivalent).
            Keystrokes.post(key: kVK_F11)
        }
        add("sys.hideothers", "Hide Other Apps", "eye.slash", LauncherColors.gray, keywords: ["focus", "declutter"]) { m in
            m.hide()
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
                && app.processIdentifier != front && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.hide()
            }
        }

        // System Settings panes
        let panes: [(String, String, String, [String])] = [
            ("Wi-Fi Settings", "wifi", "com.apple.wifi-settings-extension", ["network", "internet"]),
            ("Bluetooth Settings", "dot.radiowaves.left.and.right", "com.apple.BluetoothSettings", ["airpods", "headphones"]),
            ("Displays Settings", "display", "com.apple.Displays-Settings.extension", ["resolution", "monitor", "brightness"]),
            ("Sound Settings", "speaker.wave.2.fill", "com.apple.Sound-Settings.extension", ["volume", "output", "input"]),
            ("Battery Settings", "battery.100percent", "com.apple.Battery-Settings.extension", ["power", "energy"]),
            ("Keyboard Settings", "keyboard", "com.apple.Keyboard-Settings.extension", ["shortcuts", "input"]),
            ("Notifications Settings", "bell.badge", "com.apple.Notifications-Settings.extension", ["alerts"]),
            ("Privacy & Security Settings", "hand.raised.fill", "com.apple.settings.PrivacySecurity.extension", ["permissions", "accessibility"]),
            ("Desktop & Dock Settings", "dock.rectangle", "com.apple.Desktop-Settings.extension", ["dock", "stage manager"]),
            ("Appearance Settings", "paintpalette", "com.apple.Appearance-Settings.extension", ["dark mode", "accent"]),
            ("General Settings", "gearshape", "com.apple.systempreferences.GeneralSettings", ["software update", "about"]),
            ("Login Items Settings", "person.badge.key", "com.apple.LoginItems-Settings.extension", ["startup", "launch at login"]),
            ("Focus Settings", "moon.fill", "com.apple.Focus-Settings.extension", ["do not disturb", "dnd"]),
        ]
        for (title, symbol, pane, kw) in panes {
            add("pane.\(pane)", title, symbol, LauncherColors.gray, subtitle: "System Settings", keywords: kw + ["system settings", "preferences"]) { m in
                m.hide()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(pane)")!)
            }
        }
        return out
    }

    static func items(_ s: LauncherServices, query: String, everything: Bool = false) -> [LauncherItem] {
        all(s, everything: everything).compactMap { cmd, color in
            let score = FuzzyMatch.best(query, title: cmd.title, keywords: cmd.keywords)
            guard score > 0 else { return nil }
            var item = LauncherItem(
                id: "cmd:\(cmd.id)", title: cmd.title, subtitle: cmd.subtitle, icon: .symbol(cmd.symbol, color),
                accessory: cmd.id.hasPrefix("pane.") ? "Settings" : "Command", section: "Commands",
                actions: [LauncherAction(title: "Run", symbol: "return") { m in
                    if let msg = cmd.confirm, !m.confirmPending(cmd.id, message: msg) { return }
                    cmd.run(m)
                }],
                learnKey: "cmd:\(cmd.id)")
            item.score = score * (cmd.id.hasPrefix("pane.") ? 0.8 : 0.95)
            item.needsPanel = cmd.confirm != nil || cmd.id.hasPrefix("mode.") || ["util.capture", "util.reminder"].contains(cmd.id)
            return item
        }
    }

    // MARK: - Implementations

    static func run(_ path: String, _ args: [String], then: (@MainActor () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if let then { DispatchQueue.main.async { MainActor.assumeIsolated { then() } } }
        }
    }

    static func lockScreen() {
        // login.framework's SACLockScreenImmediate locks without needing any permission.
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias Fn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: Fn.self)()
            return
        }
        // Fallback: the system shortcut ⌃⌘Q.
        Keystrokes.post(key: kVK_ANSI_Q, flags: [.maskCommand, .maskControl])
    }

    static func toggleWiFi() {
        DispatchQueue.global(qos: .userInitiated).async {
            func shell(_ args: [String]) -> String {
                let p = Process()
                let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                p.arguments = args
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                try? p.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                return String(decoding: data, as: UTF8.self)
            }
            let ports = shell(["-listallhardwareports"]).components(separatedBy: "\n")
            guard let i = ports.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }), i + 1 < ports.count else { return }
            let device = ports[i + 1].replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespaces)
            let on = shell(["-getairportpower", device]).contains(": On")
            _ = shell(["-setairportpower", device, on ? "off" : "on"])
        }
    }

    static func pickColor(_ s: LauncherServices) {
        NSColorSampler().show { color in
            guard let color else { return }
            MainActor.assumeIsolated {
                let hex = ColorParser.hex(color)
                PasteBack.copy(text: hex)
                s.emit(Moment(kind: .launcher, left: .symbol("circle.fill", Color(nsColor: color)), right: .symbol("eyedropper", .white),
                              title: hex, detail: "Copied · \(ColorParser.rgb(color))", duration: 3))
            }
        }
    }

    /// Select a screen area, recognise its text with Vision, copy it.
    static func captureText(_ s: LauncherServices) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-ocr-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", file.path]
            try? p.run()
            p.waitUntilExit()
            guard let img = NSImage(contentsOf: file), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return   // cancelled, or Screen Recording not granted
            }
            try? FileManager.default.removeItem(at: file)
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if text.isEmpty {
                        s.emit(Moment(kind: .launcher, left: .symbol("text.viewfinder", .white.opacity(0.6)), right: .none,
                                      title: "No text found", detail: "", duration: 2.5))
                    } else {
                        PasteBack.copy(text: text)
                        s.emit(Moment(kind: .launcher, left: .symbol("text.viewfinder", LauncherColors.purple), right: .symbol("checkmark", ContinuityColors.green),
                                      title: "Text copied", detail: NotchNotification.oneLine(text), duration: 3.5))
                    }
                }
            }
        }
    }
}

