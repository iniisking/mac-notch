# Notch

A personal macOS app that turns the MacBook notch into a notification surface.
It works **while Focus mode silences banners**, because it reads Notification Center's
own database instead of mirroring on-screen banners.

- **Idle**: invisible, matches the hardware notch exactly.
- **Light up**: Dynamic-Island sized, at exactly the notch height with one small wing per
  side. The app icon sits in the left wing; right of the camera is a short label (never the
  app name): the sender for Messages/WhatsApp/Telegram/Slack/Mail, the event for Calendar, and
  otherwise the title or the first words of the body. The right wing grows to fit the label up
  to ~92 pt and scrolls longer labels. It is plain black, with no glow or outline, and collapses
  after a few seconds (adjustable). Further arrivals queue up and shorten the dwell to 2 s.
- **Hover (peek)**: drops down into a card with the title, subtitle and 2–3 lines of body text.
- **Click (expanded)**: a larger panel with recent notifications grouped by app and the full
  body (scrollable, selectable), plus **Open app**, **Copy** and **Dismiss** actions.
  It collapses when the mouse leaves or you click elsewhere.
- **Now Playing** (Spotify, YouTube Music, YouTube): while music plays, the notch stays
  notch-sized with album art in the left wing and the source logo in the right wing. Title and artist, scrolling if too long, are in the hover
  card, which also drops down by itself for ~3 s whenever the track changes. Notifications take
  priority and then hand the notch back.
  Hover for a card with a progress bar and previous / play-pause / next; the expanded panel
  shows the same player above the notification list. Other players (Apple Music, podcasts,
  random browser video/calls) are **ignored by default**; Settings › "Include other players"
  shows them with a generic music-note icon.
- **Synced lyrics**: the line being sung appears in a slim strip directly under the compact
  notch, at the same width. Lines change with a vertical slide, long lines scroll so they finish
  before the next line starts, and the strip hides during instrumental gaps or when there are no
  lyrics. Notifications still take priority. The hover card shows the previous, current (bold) and
  next lines; click a line to jump there. Lyrics come from [LRCLIB](https://lrclib.net) (free, no key)
  and are cached, misses included, in `~/Library/Application Support/Notch/lyrics`. YouTube-style
  titles are cleaned before searching ("(Official Video)", "[Lyrics]", "ft. …", "VEVO",
  "- Topic", "Artist - Song" splitting). Timing uses MediaRemote's position
  (elapsed + time since its timestamp × rate), resynced on every play, pause or seek, plus an
  adjustable offset (Settings › Lyrics, ±0.1 s steps).
- **Karaoke, romanization, translation**: the sung part of the line sweeps bright over a dim line,
  in the strip and the hover card, and long lines scroll to keep the sweep in view. When LRCLIB has
  enhanced LRC (`<mm:ss.xx>` word tags) the sweep follows real word timings; otherwise it is
  estimated from the line length and the gap to the next line. Settings › Lyrics › *Second line*
  adds a romanization (offline: Japanese via the system tokenizer's readings, so kanji read as
  Japanese, and other scripts via ICU Any-Latin, with pinyin tones, Hangul and Cyrillic) or an
  on-device translation into the Mac's language (Apple Translation, macOS 26+; download the language
  pair in System Settings › General › Language & Region › Translation Languages). Translations are
  cached in `lyrics/translations`. Songs already in your language get no second line. *Use the
  second line in the strip* shows it under the notch instead of the original.
- **Per-song lyric timing**: the hover card header has − / Sync / + (0.2 s steps) for the playing
  song only, on top of the global offset. It is saved per track; click the value to reset.
- **Scrubbing**: drag or click the progress bar in the hover card or expanded player to seek.
- **Calls**: while a call app records from the microphone, the notch rests as a call instead of
  music. The app icon is in the left wing and a green timer in the right wing; both wings widen past an
  hour, and a red mic-slash badge shows when the mic is muted. Hover for a card with mic and camera
  state, **Mute** (mutes the Mac's default input device, and is undone automatically when the call ends
  or Notch quits) and **Show** (brings the app, or the meeting's browser tab, to the front).
  Detection uses CoreAudio's per-process objects (macOS 14.2+, no permission): FaceTime and iPhone
  calls show up as `avconferenced`; Zoom, Teams, Slack, Discord, WhatsApp, Telegram, Signal, Webex,
  Skype and browsers are recognised. For browsers, Notch reads tab URLs (same Automation permission as
  the music classifier) to name Google Meet, Teams, Zoom, Slack, Discord, Whereby and Jitsi.
  A call starts after 2 s of mic use (skips dictation blips) and ends after 4 s without it.
  Settings › *Count any app using the microphone* widens this to any regular app.
- **Charging & battery**: plugging in shows a brief "67% · battery" moment with "Charging · full in
  48m" (or "Fully charged" / "charging paused") in the strip. On battery, 20% and 10% show a red
  "Low battery · 34m left" moment. It uses IOKit power-source notifications (no permission). If a
  notification is on screen it waits, and it is dropped if it's more than 20 s old.
- **Menu-bar bell** (no Dock icon): Show Notifications, Send Test Notification, Settings, Quit.
- **Settings**: per-app mute list, display duration, launch at login, show on external
  displays, test notification, source status, clear history, lyrics (karaoke, second line), and
  Calls & Battery toggles.

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
bundle id).

Play/pause/next/previous go through the same helper (`send`). Each command is checked: if the
player's state doesn't change within ~2 s, Notch falls back to Spotify's AppleScript (for Spotify)
or to the system media keys (play/next/previous). Posting media keys needs **Accessibility**
permission, and macOS asks the first time that fallback is used. (The original bug was that the helper
exited before MediaRemote delivered the command; it now waits for delivery.) This is the same technique as the
open-source [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) (BSD-3), written
independently and minimally here; nothing third-party is bundled. Check it any time with:

```bash
/usr/bin/perl build/Notch.app/Contents/Resources/notch-media.pl \
  "$PWD/build/Notch.app/Contents/Resources/libNotchMedia.dylib" get
```

Source detection: Spotify is recognised by bundle id; installed YouTube/YouTube Music web apps by
their app name. When the player is a **browser** (Chrome, Arc, Edge, Brave, Safari, …) Notch asks
it for its tab URLs/titles via AppleScript: `music.youtube.com` → YouTube Music, `youtube.com` →
YouTube. Until the browser answers, a metadata guess is shown (an album means YouTube Music, a
channel/artist means YouTube). **macOS shows a one-time prompt "Notch wants to control <Browser>"** the first time this
happens for each browser; if you click Don't Allow, browser playback is treated as "other" (hidden
by default). Re-enable in System Settings › Privacy & Security › Automation › Notch.
If the MediaRemote helper ever stops working, Notch falls back to Spotify's AppleScript
dictionary (this triggers a one-time "control Spotify" prompt).

### Settings › Test notifications

- **Presets**: WhatsApp message, Messages with a long body (for the expanded view), Mail (sender,
  subject and long body), Calendar event, and a very long sender (for the strip marquee). They use real
  installed app icons.
- **Burst of 3**: tests the queue and the `+N` badge.
- **Custom notification**: pick an installed app (or type any bundle id), enter title, subtitle and
  body, then press Send.
- **Send real system notification**: Notch posts an actual macOS notification and lets it come back
  through Notification Center's database, the same path real notifications take (works with Focus on).
  It usually appears within a few seconds; macOS occasionally delays or drops one. The first time,
  macOS asks to allow notifications from Notch. It isn't injected locally, so it never appears twice.

Test items behave like real ones (compact, strip, hover, expanded, open/copy/dismiss) but are never
saved to history.

The strip under the notch reads **"Sender - preview"**: chats show sender and message, Mail shows
sender and subject, Calendar shows event and time/place, and other apps show title and body. The
sender is semibold and the preview dimmer; long text scrolls.

### Testing the UI without real notifications

- Menu bar › **Send Test Notification** (⌘T while the menu is open), or the same button in Settings.
- Launch flags: `open build/Notch.app --args --demo` injects three test notifications;
  `--expand` opens the expanded panel; `--peek` pins the hover card open (for screenshots only);
  `--demo-music[=spotify|youtubemusic|youtube]` shows a fake track (stops the real helper);
  `--media-selftest` sends play/pause, pause, next, previous and pause to whatever is playing and
  logs the results to `~/Library/Application Support/Notch/debug.log`.
- `--demo-call[=zoom|facetime|meet]` fakes a call (`meet` started over an hour ago, for the wide
  timer); `--demo-charge` / `--demo-lowbattery` fake the battery moments. `--peek-delay=<s>` delays
  `--peek` (e.g. `--demo-call --peek --peek-delay=6` for the call card).
- `--snapshot` renders the notch to `~/Library/Application Support/Notch/snapshots/<state>.png`
  1.2 s after every state change. It needs no Screen Recording permission, so it works from scripts and
  agents.
- If you launch Notch from a terminal or another tool, macOS attributes its Automation prompt to
  that parent app (e.g. "Terminal wants to control Google Chrome"). Launch it from Finder,
  Spotlight or login items so the prompt names Notch.

## How it works

```
Sources/
  Shared/NCDatabase.swift         read-only libsqlite3 wrapper + binary-plist payload decoder (shared with the CLI)
  Notch/
    App/                          main.swift, AppDelegate (status item, per-screen windows, onboarding)
    Source/                       NotificationSource protocol, DBNotificationSource
    Model/                        NotchNotification, NotificationStore (history), AppInfoProvider (names/icons)
    Window/                       NotchPanel (NSPanel), NotchWindowController (placement + mouse hit-testing), NotchGeometry
    ViewModel/NotchViewModel      idle / compact / peek / expanded state machine, queue, timers
    Views/                        NotchShape, NotchRootView, CompactView, PeekView, ExpandedView
    Settings/                     SettingsStore, SettingsView, OnboardingWindow
    NowPlaying/                   NowPlayingService (helper process + Spotify fallback), SourceClassifier, models
    Lyrics/                       LyricsService (LRCLIB, sync clock, karaoke), LyricsExtras (romanize / translate)
    Activities/                   CallMonitor (CoreAudio mic users, camera, input mute), PowerMonitor (IOKit)
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
- Lyrics depend on LRCLIB having the song. Live versions, remixes and obscure uploads are often
  missing, and some synced files are slightly off (use the offset). Lookups need internet; a network
  failure isn't cached, so it retries on the next play.
- Now Playing relies on private MediaRemote behaviour; a future macOS could close the perl route.
  YouTube vs YouTube Music in a browser is a best guess from open tab URLs/titles.
- Karaoke timing is estimated for most songs, because LRCLIB rarely has word-level tags. It reads
  well for steady lines but can run ahead on slow, drawn-out ones.
- Call detection sees *who* holds the mic, not the call itself: a voice memo in WhatsApp or a
  browser tab recording audio also counts. The mute button mutes the input device, so the call
  app's own mute icon won't change. Some devices (certain USB interfaces) have no mute control,
  and then the button is hidden.
- Hover detection uses global mouse-move monitoring, which needs no extra permission.
  Keyboard shortcuts aren't supported.
- Personal use only. It isn't sandboxed and isn't suitable for the App Store.
