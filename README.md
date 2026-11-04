# Notch

A personal macOS app that turns the MacBook notch into a notification surface.
It works **while Focus mode silences banners**, because it reads Notification Center's
own database instead of mirroring on-screen banners.

- **Idle**: invisible, matches the hardware notch exactly.
- **Light up**: when a notification arrives, the notch widens and shows the app icon and
  name on the left and a one-line summary on the right, with a soft glow tinted from the
  app icon. It collapses after a few seconds (adjustable), and further arrivals queue up
  with a `+N` badge.
- **Hover (peek)**: drops down into a card with the title, subtitle and 2–3 lines of body text.
- **Click (expanded)**: a larger panel with recent notifications grouped by app and the full
  body (scrollable, selectable), plus **Open app**, **Copy** and **Dismiss** actions.
  It collapses when the mouse leaves or you click elsewhere.
- **Now Playing** (Spotify, YouTube Music, YouTube): while music plays, the notch shows the
  album art fixed on the far left, the source logo fixed on the far right, and the title over
  the artist in between, scrolling as a marquee when too long (on notch screens the text sits
  beside the camera housing). Notifications take priority and then hand the notch back.
  Hover for a card with a progress bar and previous / play-pause / next; the expanded panel
  shows the same player above the notification list. Other players (Apple Music, podcasts,
  random browser video/calls) are **ignored by default**; Settings › "Include other players"
  shows them with a generic music-note icon.
- **Menu-bar bell** (no Dock icon): Show Notifications, Send Test Notification, Settings, Quit.
- **Settings**: per-app mute list, display duration, launch at login, show on external
  displays, test notification, source status, and clear history.

On screens without a notch, Notch uses an invisible pill at the top centre that behaves the same way.

## Build

Requirements: Xcode 15+ (built here with Xcode 27.2) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
scripts/build.sh            # Release build -> build/Notch.app and build/notch-dbcheck
scripts/build.sh --install  # same, then copies to ~/Applications/Notch.app and launches it
```

The Xcode project is generated from `project.yml` and isn't checked in. Run `xcodegen generate` to
open it in Xcode (`open Notch.xcodeproj`).

**Signing:** `build.sh` signs with your **Apple Development** identity, with the Hardened Runtime
on and the App Sandbox off. It prefers an identity containing "theajstars". To choose a different
one, set `NOTCH_SIGN_IDENTITY` to a name or the SHA-1 shown by
`security find-identity -v -p codesigning`. A stable identity matters: macOS ties the Full Disk
Access grant to the code signature, so rebuilds keep the permission. If no identity is found, the
app is signed ad-hoc and you have to re-grant access after every rebuild.

## Grant Full Disk Access (required)

The notification database lives at
`~/Library/Group Containers/group.com.apple.usernoted/db2/db` and is protected by TCC.

1. Install the app with `scripts/build.sh --install`. Granting access to a stable path
   (`~/Applications/Notch.app`) is simplest.
2. Open **System Settings › Privacy & Security › Full Disk Access**. You can also use the
   onboarding window, the menu-bar item, or the button in the notch panel.
3. Turn on **Notch**. If it isn't listed, click **+** and choose `Notch.app`.
4. Relaunch Notch (menu bar › Relaunch Notch, or the onboarding window's button).

Until access is granted, Notch shows an onboarding window, a crossed-out bell in the menu bar,
and a banner in the expanded panel. It retries every 5 seconds.

### Quick DB check

```bash
build/notch-dbcheck      # prints the newest 5 notifications
build/notch-dbcheck 20   # newest 20
```

This is a separate binary, so the app you run it from (e.g. Terminal) needs its own
Full Disk Access grant. It exits with code 2 when access is denied.

### Now Playing: how and what permissions

Since macOS 15.4 the private MediaRemote framework only answers Apple-entitled processes.
Notch therefore runs `/usr/bin/perl` (which is entitled) with `Contents/Resources/notch-media.pl`,
which loads Notch's own helper library `libNotchMedia.dylib` (`Sources/NotchMedia/`) and streams
JSON now-playing updates (title, artist, album, artwork, playing state, elapsed/duration, source
bundle id). Play/pause/next/previous go through the same helper. This is the same technique as the
open-source [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3), written
independently and minimally here; nothing third-party is bundled. Check it any time with:

```bash
/usr/bin/perl build/Notch.app/Contents/Resources/notch-media.pl \
  "$PWD/build/Notch.app/Contents/Resources/libNotchMedia.dylib" get
```

Source detection: Spotify is recognised by bundle id; installed YouTube/YouTube Music web apps by
their app name. When the player is a **browser** (Chrome, Arc, Edge, Brave, Safari, …) Notch asks
it for its tab URLs/titles via AppleScript: `music.youtube.com` → YouTube Music, `youtube.com` →
YouTube. **macOS shows a one-time prompt "Notch wants to control <Browser>"** the first time this
happens for each browser; if you click Don't Allow, browser playback is treated as "other" (hidden
by default). Re-enable in System Settings › Privacy & Security › Automation › Notch.
If the MediaRemote helper ever stops working, Notch falls back to Spotify's AppleScript
dictionary (this triggers a one-time "control Spotify" prompt).

### Testing the UI without real notifications

- Menu bar › **Send Test Notification** (⌘T while the menu is open), or the same button in Settings.
- Launch flags: `open build/Notch.app --args --demo` injects three test notifications;
  `--expand` opens the expanded panel; `--peek` pins the hover card open (for screenshots only);
  `--demo-music[=spotify|youtubemusic|youtube]` shows a fake track (stops the real helper).

## How it works

```
Sources/
  Shared/NCDatabase.swift         read-only libsqlite3 wrapper + binary-plist payload decoder (shared with the CLI)
  Notch/
    App/                          main.swift, AppDelegate (status item, per-screen windows, onboarding)
    Source/                       NotificationSource protocol, DBNotificationSource
    Model/                        NotchNotification, NotificationStore (history), AppInfoProvider (icons/tint)
    Window/                       NotchPanel (NSPanel), NotchWindowController (placement + mouse hit-testing), NotchGeometry
    ViewModel/NotchViewModel      idle / compact / peek / expanded state machine, queue, timers
    Views/                        NotchShape, NotchRootView, CompactView, PeekView, ExpandedView
    Settings/                     SettingsStore, SettingsView, OnboardingWindow
    NowPlaying/                   NowPlayingService (helper process + Spotify fallback), SourceClassifier, models
  NotchMedia/                     libNotchMedia.dylib (MediaRemote via perl) + notch-media.pl
  notch-dbcheck/main.swift        CLI
```

- **Source**: opens the DB read-only and checks the `record` and `app` columns at startup with
  `PRAGMA table_info`. It joins `record.app_id` to `app.identifier` (the bundle id) and decodes
  `record.data` with `PropertyListSerialization` (`req.titl`, `req.subt`, `req.body`, `req.thre`).
  It watches `db` and `db-wal` with `DispatchSource` file watchers, polls every 1.5 s as a
  fallback, and tracks the highest `rec_id` it has seen. The first launch only records the
  current position, so old notifications aren't replayed. On later launches, anything that
  arrived in the last 60 s still lights up.
- **History**: the last 100 notifications are kept in
  `~/Library/Application Support/Notch/history.json`. Rows in the DB disappear when
  notifications are cleared or withdrawn, but Notch's history keeps them.
- **Window**: a borderless, non-activating `NSPanel` at menu-bar level + 3, on all Spaces and
  over full-screen apps. It ignores the mouse except inside the current notch shape, so the rest
  of the menu bar keeps working. The notch is measured from `safeAreaInsets.top` and the
  `auxiliaryTopLeft/RightArea` widths, and the layout is redone when screen parameters change.

## Known limits

- **Latency**: usually under a second, and up to about 2 seconds if the file watcher misses a write and the poll picks it up.
- **Undocumented schema**: the usernoted DB format isn't public and could change in any macOS
  update. Notch checks columns at startup and reports "Unexpected notification database schema"
  in Settings instead of crashing. Some apps put the sender in `subtitle`, and some leave
  `body` empty.
- Only notifications that Notification Center stores are visible. Apps that turned off
  "Show in Notification Center" may never create a row.
- The light-up and now-playing states cover menu-bar items next to the notch.
- Now Playing relies on private MediaRemote behaviour; a future macOS could close the perl route.
  YouTube vs YouTube Music in a browser is a best guess from open tab URLs/titles.
- Hover detection uses global mouse-move monitoring, which needs no extra permission.
  Keyboard shortcuts aren't supported.
- Personal use only. It isn't sandboxed and isn't suitable for the App Store.
