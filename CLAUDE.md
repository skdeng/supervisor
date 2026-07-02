# SuperVisor

A native macOS (macOS 26, Apple Silicon) menu-bar app that turns the MacBook notch / top
menu-bar area into an interactive, iPhone-style Dynamic Island. SwiftUI + AppKit, Swift 6.2.
It is a Swift Package Manager **executable** (`Sources/SuperVisor`) — there is no Xcode
project. Any `.swift` file placed anywhere under `Sources/SuperVisor/` is compiled
automatically; `Package.swift` is never edited to add files.

`ARCHITECTURE.md` is the canonical, byte-exact contract for the foundation files. Read it
before touching `Core/NotchModule.swift`, `Core/NotchContext.swift`, or
`App/ModuleRegistry.swift` — modules and the engine depend on those signatures; do not change
them.

## Build & Run

- **`./make-app.sh --release`** — builds, bundles, and ad-hoc-signs `build/SuperVisor.app`.
  (`--run` also launches it; drop `--release` for a debug build.)
- **`open build/SuperVisor.app`** — launch. It is an **`LSUIElement`** menu-bar agent
  (`.accessory` activation policy): no Dock icon, no main window. A status-bar item
  (`visionpro` glyph) hosts the **Settings…** and **Quit** menu.
- **Quit** via the status-bar menu, or `pkill -f SuperVisor.app`.
- **`swift build`** alone compiles the binary but does *not* produce the bundle. The bundle is
  required because TCC permission grants (Location, Calendar, Reminders, Accessibility, Bluetooth) and the
  now-playing read only persist for a **stable, signed bundle identity** — a bare `swift run`
  binary gets a fresh identity each launch and grants never stick. `make-app.sh` also compiles
  the MediaRemote adapter dylib (see below); `swift build` does not.

## High-Level Architecture

A single morphing surface, driven by a small state machine, that modules feed content into.

- **`Core/NotchModule.swift`** — the plugin contract. `@MainActor public protocol NotchModule`:
  `moduleID` / `displayName` / `order` (lower renders earlier in the expanded panel),
  `activate(_:)` / `deactivate()`, and three optional UI surfaces — `compactLeading()`,
  `compactTrailing()`, `expandedSection()` (each returns `AnyView?`, default `nil`). Modules are
  typically `final class … : NotchModule, ObservableObject`; the `AnyView`s they return wrap an
  `@ObservedObject` of themselves, so a module's own `@Published` changes re-render only its
  subtree. Modules never reference each other.
- **`Core/NotchContext.swift`** — services handed to each module in `activate`. Four closures:
  `requestExpand()`, `requestCollapse()`, `requestPeek(seconds:)`, and
  `setNeedsCompactRefresh()`. The last is required *only* when a compact contribution
  **appears or disappears** (which changes pill size/layout) — internal value changes inside an
  already-shown compact view update automatically via `@ObservedObject`.
- **`App/ModuleRegistry.swift`** — THE single place modules are wired in (`allModules()`).
  Array order is irrelevant; modules sort by `order`. Currently lists 5 modules
  (Media, Calendar, Reminders, FileShelf, Battery).
- **`Core/NotchEngine.swift`** — owns the window, geometry, hover detection, the enabled-module
  list, and the state machine: `NotchState` is `.idle` / `.compact` / `.expanded` (peek is a
  transient `.compact`). Builds the `NotchContext`, filters modules by `SettingsStore`, activates
  them sorted by `order`. Enabling or disabling a module in Settings activates/deactivates it live
  (`reconcileModules`, driven by `SettingsStore.$moduleEnabled`) — no relaunch. Note: the sheet
  opens on **click** (`toggleSheet()`), hover only shows a subtle grow affordance. `compactRevision`
  is bumped on `setNeedsCompactRefresh`.
- **`Core/NotchWindow.swift`** — a borderless, non-activating `NSPanel` above the status-bar
  level, on all spaces, floating over fullscreen, transparent. It is a **fixed-size canvas**
  (`canvasFrame`): always large enough for the expanded panel and widest compact content, so it
  **never resizes per state** — only the SwiftUI content morphs, so the Dynamic-Island animation
  is never clipped by a window resize. Events pass through everywhere except the notch/sheet
  region: `NotchContentContainer` hit-tests against an interactive rect (so clicks and file drags
  land only there) and is also a file-drag destination — dragging a file onto the notch opens the
  sheet — while the desktop/menu bar stay usable elsewhere.
- **`UI/NotchRootView.swift`** — the **single morphing surface**. One black `NotchShape` grows
  (width + height spring) from the notch-hugging pill into the expanded sheet; the fill stays
  black and the corner radius interpolates so the open reads as the notch itself expanding, not a
  separate panel dropping down. A solid black "camera cap" always covers the physical cutout. Hosts
  `CompactPillView` (fades out on expand) and `ExpandedPanelView` (fades in after the grow).

## Geometry

`Core/ScreenGeometry.swift` derives the notch rect from `NSScreen.safeAreaInsets.top` (the notch
height) and the gap between `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (the notch width).
On non-notch Macs it synthesizes a 200×32 region centered at the top. All rects are global AppKit
coordinates (bottom-left origin). Recomputed on `didChangeScreenParametersNotification`.

## Private-Framework Access

Private system frameworks (MediaRemote, DisplayServices, etc.) are reached with `dlopen` +
`dlsym` + `unsafeBitCast` to a precise `@convention(c)` Swift type — **never** a bridging header
or custom module map (both break SPM builds). Match the C signature exactly; guard every
`dlopen`/`dlsym` and degrade gracefully when a symbol is missing.

## Now-Playing: the macOS 15.4+ gate (non-obvious)

Since macOS 15.4, `mediaremoted` gates the now-playing **info read**
(`MRMediaRemoteGetNowPlayingInfo`, the only path that inlines artwork bytes) to callers whose
**host process** is Apple-signed (`com.apple.*`). An ad-hoc-signed third-party app gets a `nil`
info dict. Workaround:

- `make-app.sh` compiles **`Sources/MediaRemoteAdapter/mediaremote_adapter.m`** into
  `mediaremote_adapter.dylib`, shipped in the bundle's `Resources/`.
- `Modules/Media/NowPlayingReader.swift` spawns **`/usr/bin/perl`** (Apple-signed,
  `com.apple.perl`, which the gate admits), has it `DynaLoader`-load the dylib and call
  `run_mediaremote_adapter`, which runs the MediaRemote C call inside the entitled host and prints
  JSON (artwork as base64) to stdout.
- **Transport commands** (play/pause/skip) are *not* gated and go direct via
  `Modules/Media/MediaRemoteBridge.swift` (the `dlopen`/`dlsym` bridge). The block-typed callbacks
  there are `@convention(block)`, not `@convention(c)`.

## Untrusted Input

External data reaching the app is attacker-influenced and is validated before it hits a dangerous
sink. Preserve these guards when touching the relevant code:

- **Calendar fields** (event `url` / `location` / `notes`) come from anyone who can send an invite.
  `MeetingLink` only accepts a join URL whose scheme is on an allowlist (`http` / `https` plus known
  meeting-app schemes), and `MeetingProvider.from(host:)` matches the host exactly or as a subdomain,
  never as a substring. `CalendarModule.join` re-checks the scheme before `NSWorkspace.open`.
- **Dropped file names** are arbitrary. `FileActionService` runs `/usr/bin/zip` with `-y` (store
  symlinks rather than following one out of a dragged folder) and a `--` end-of-options marker plus a
  `./` prefix on every input path, so a name beginning with `-` can never be parsed as a zip option
  (which reaches command execution via `-TT`).
- **Now-playing metadata** is set by any other running app. `mediaremote_adapter.m` drops non-finite
  numbers and validates the payload (`isValidJSONObject`) before serializing, so a malicious source
  cannot abort the entitled perl helper with an uncaught exception.

## Module Roster

Each lives self-contained in `Modules/<Name>/` (model + system observers + SwiftUI views).
User-facing modules follow the **`<Feature>Visor`** brand naming (in their `displayName`); the
folder names below are the code paths.

- **Media → "MusicVisor"** (`Modules/Media`) — system now-playing surface. Compact: album-art
  thumbnail + a three-bar equalizer **tinted with the artwork's dominant color**
  (`MediaArtworkColor`, computed once per track). Expanded: large artwork, title/artist, a live
  scrubber, transport, and an **audio-output device switcher**. Info via the perl adapter (with an
  adaptive poll — faster while playing); commands via `MediaRemoteBridge`.
- **Calendar** (`Modules/Calendar`) — next-meeting countdown chip in compact; an agenda with a
  one-tap **Join** button (Zoom / Meet / Teams / Webex link detection) in expanded. EventKit via
  `CalendarService`. **Meeting Mode:** while a meeting with a join link is in progress, the pill
  shows the live mic-mute state and the sheet leads with a call HUD — elapsed timer, a system-wide
  **mic-mute** toggle (`MicController`), an audio-output switcher, and Join; a mute applied via the
  notch is auto-restored when the meeting ends.
- **Reminders → "TaskVisor"** (`Modules/Reminders`) — due-today + overdue Apple Reminders. Compact:
  a checklist count badge (red when any are overdue). Expanded: a **tap-to-complete** checklist
  with list color, live due/overdue text, and a high-priority marker. EventKit via
  `RemindersService`.
- **FileShelf → "ClipVisor"** (`Modules/FileShelf`) — drag-and-drop staging shelf. Dragging a file
  onto the notch opens the sheet with the shelf (it is not shown otherwise); hold files, drag back
  out, Quick Look, AirDrop, zip. (`FileShelfStore`, `ThumbnailService`, `QuickLookController`,
  `FileActionService`.)
- **Battery** (`Modules/Battery`) — power/charging status, time remaining, and connected-device
  (Bluetooth accessory) battery; peeks on plug/unplug and low battery. (`PowerSourceMonitor`,
  `BluetoothMonitor`.)

**`Modules/SystemHUD/`** (volume / brightness / keyboard-backlight HUD — `VolumeController`,
`BrightnessController`, `KeyboardBacklightController`, `MediaKeyMonitor`) is present but **NOT wired
into `ModuleRegistry`** — dead/unreferenced code kept for possible future use; nothing activates it
at runtime.

## Shared Services

- **`Services/Audio/`** — CoreAudio helpers shared by modules (these are plain services, not
  `NotchModule`s, so modules stay decoupled). `AudioOutputController` + `AudioOutputSelector` (the
  default-output device and its inline picker, used by Media and Meeting Mode) and `MicController`
  (default-input hardware mute for Meeting Mode; the mute follows the default input across device
  changes, so switching mics mid-call never orphans a system-wide mute on the old device). Live
  updates come through **`AudioPropertyListener`**, a shared wrapper over CoreAudio's **proc-based**
  listener API (`AudioObjectAddPropertyListener` + a retained weak-box `clientData`, hopping to the
  main actor). The block-based API is avoided: a Swift closure stored as a listener block re-bridges
  to a new block each time it crosses the C boundary, so `AudioObjectRemovePropertyListenerBlock`
  never matches on removal and leaks the registration on every remove.

## Theme & Settings

- **`Theme/LiquidGlass.swift`** (`NotchTheme`) — design tokens + Liquid Glass material wrappers.
  The notch pill is opaque black (blends with the hardware cutout); the expanded panel and floating
  surfaces use the native macOS 26 Liquid Glass material, degrading to `.ultraThinMaterial`.
- **`Settings/SettingsStore.swift`** — `UserDefaults`-backed, `SettingsStore.shared`. Per-module
  enabled flags (default on) and hover sensitivity.

## Debug

`SettingsStore.debugTintEnabled` (a toggle in Settings, persisted as `debug.tintRed`) tints the
whole rendered surface **bright red** so its exact bounds are visible against the black hardware
notch. In debug tint the surface always renders even when idle.
