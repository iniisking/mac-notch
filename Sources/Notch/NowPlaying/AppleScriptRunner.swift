import Foundation

/// Runs AppleScript through /usr/bin/osascript off the main thread.
/// The first call per target app triggers macOS's Automation consent prompt for Notch.
enum AppleScriptRunner {
    private static let queue = DispatchQueue(label: "com.theajstars.notch.osascript", qos: .utility)

    static func run(_ source: String, timeout: TimeInterval = 4, completion: @escaping (String?) -> Void) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
            DispatchQueue.main.async { completion(text?.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}
