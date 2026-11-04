import AppKit

/// Last-resort control: posts the hardware play/next/previous media keys, which every
/// player that handles media keys (browsers, YouTube, YouTube Music, Spotify) responds to.
/// Posting events needs Accessibility permission; macOS asks once.
enum MediaKeys {
    // From IOKit/hidsystem/ev_keymap.h
    private static let NX_KEYTYPE_PLAY: Int32 = 16
    private static let NX_KEYTYPE_NEXT: Int32 = 17
    private static let NX_KEYTYPE_PREVIOUS: Int32 = 18

    static func post(_ command: MediaCommand) {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            DebugLog.write("media key: no permission to post events (Accessibility)")
            return
        }
        let key: Int32
        switch command {
        case .play, .pause, .togglePlayPause: key = NX_KEYTYPE_PLAY
        case .next: key = NX_KEYTYPE_NEXT
        case .previous: key = NX_KEYTYPE_PREVIOUS
        }
        DebugLog.write("media key posted: \(command)")
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
