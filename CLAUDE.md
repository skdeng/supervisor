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

`notchScreen()` renders on the screen whose `safeAreaInsets.top > 0`, else on the **primary**
display (`NSScreen.screens.first`, which AppKit documents as the one owning the menu bar).
Never `NSScreen.main` — that is whichever display holds keyboard focus when it is read, so the
focused window at launch or at display reconfiguration would decide where the surface lives.

## The pill (screens with no physical cutout)

Only one screen ever hosts the surface, so this applies exactly when **no attached screen has a
notch** — a Mac mini/Studio, an older MacBook, or a notched MacBook in clamshell. An external
monitor beside a notched built-in display does *not* reach it.

At rest the surface is the notch silhouette, flush with the screen's top edge. **Hovering detaches
it into a floating pill**: it drops `pillTopDrop` (a quarter of the notch height), swells by
`NotchTheme.pillHoverScale`, and its concave menu-bar flares curl inward into convex corners. The
open sheet keeps that silhouette, so the pill grows rather than snapping back to the edge.

- **`NotchShape`** morphs on one continuous `pillness` (0…1), animated through
  `AnimatablePair(cornerRadius, pillness)`. Each top corner is a **single** quadratic curve, not
  two: the concave flute and the convex corner share the same control point (the corner) and
  differ only in their endpoints, which slide from `-flare` outside the body to `+rounding` inside
  it. Growing a second curve beside a shrinking first reads as a bump next to a dip. At
  `pillness == 0` the path emits an element sequence byte-identical to the plain notch — verify
  any change to it by rasterizing both and diffing coverage.
- **`pillTopDrop` is 0 on a hardware notch**, which is what makes nearly every downstream branch a
  no-op there rather than an `if`. The explicit `isHardwareNotch` tests are few: the camera cap
  (drawn only over a real cutout — a cap welded to the top edge would strand there once the
  surface detaches), the hover scale, and `NotchEngine.hoverGrowth`.
- The surface **grows from its own top edge**, not the screen's (`scaleAnchor`); scaling about the
  screen edge would multiply the drop and slide the pill further down the more it grew.
- `NotchEngine` sizes the canvas, the hit-test rect, and the hover activation rect from the same
  drop and growth. The hover zone must start at the screen's top edge (where the surface rests) and
  reach down over where the pill lands, or the pill drops out from under the cursor that summoned
  it and chatters. The hit-test rect drops with the pill, so the menu-bar strip it vacates goes
  back to being the menu bar instead of a dead zone.

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
  `mediaremote_adapter.dylib`, shipped in the bundle's `Resources/`. It exports two entry points.
- **Streaming (the live path).** `Modules/Media/NowPlayingStream.swift` spawns **`/usr/bin/perl`**
  (Apple-signed, `com.apple.perl`, which the gate admits) **once**, has it `DynaLoader`-load the
  dylib and enter `run_mediaremote_adapter_stream`, which never returns: it prints one JSON object
  per line (artwork as base64) as the now-playing state changes. Inside that entitled host it both
  observes MediaRemote's change notifications and re-reads on a timer (2 s playing / 4 s paused),
  because the notifications are silent for some players. It emits only when the state actually
  moved — `elapsed`/`timestampEpoch` advance on every daemon re-sample, so they are compared
  against where the previous sample predicted playback would be, which detects a seek and ignores
  drift. It exits on stdin EOF, so it can never outlive the app. The Swift side respawns it with a
  widening backoff and, after 4 failures in 60 s, falls back permanently to the one-shot reader.
- **One-shot.** `Modules/Media/NowPlayingReader.swift` spawns the same helper per read and calls
  `run_mediaremote_adapter`, which prints a single JSON object and exits. Used for user-initiated
  refreshes (right after a transport command) and as the fallback poll. Each call costs a process
  spawn (~10 ms CPU), which is why it is not the steady-state path.
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
Modules that surface a **generic capability** carry a **`<Feature>Visor`** brand name in their
`displayName` (MusicVisor, TaskVisor, ClipVisor) — propose one in that style for any new module.
Name a module literally only when its point is *whose* data it shows rather than *what* it does
(Claude Usage), or when the plain noun already is the feature (Calendar, Battery). The folder
names below are the code paths.

- **Media → "MusicVisor"** (`Modules/Media`) — system now-playing surface. Compact: album-art
  thumbnail + a six-thin-bar equalizer **tinted with the artwork's dominant color**
  (`MediaArtworkColor`, computed once per track). While a track plays, the bars are a **real FFT
  spectrum of the actual system audio** (`SpectrumBarsView`, fed by the system-audio tap in
  `Services/Audio/`); when the tap is off, denied, or rebuilding they fall back to the
  synthesized bounce (`AudioBarsView`) in the same footprint. A **beat aura**
  (`UI/BeatAuraView`, layered behind the morphing surface in `NotchRootView`) glows around the
  notch in the artwork color, following the music's bass envelope. Both are toggleable in
  Settings (`media.trueSpectrum`, `media.beatAura`). Expanded: large artwork, title/artist, a live
  scrubber, transport, and an **audio-output device switcher**. Info streams from one long-lived
  perl adapter (`NowPlayingStream`), which pushes a snapshot only when the state changes; commands
  via `MediaRemoteBridge`.
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
- **Usage → "Claude Usage"** (`Modules/Usage`) — Claude Code plan-quota runway as one ticker row at
  the bottom of the sheet (`5h 62% · 7d 34% ↻ 4:30 PM`, colored by headroom: green < 70 %, amber
  < 90 %, red past it). No compact/pill presence. Data: `QuotaMonitor` **watches**
  `~/.claude/agentpace/last-status.json` (the statusline capture the user's Claude Code
  statusline wrapper rewrites on every refresh) through `FileChangeWatcher` and re-parses only
  when the mtime actually moves; the `rate_limits` object carries `used_percentage`/`resets_at`
  per window. The row exists only while Claude Code is actively in use (file fresh within
  10 min) **and** quota data is recent (30 min TTL) — quota is retained across payloads that
  omit `rate_limits` (desktop-bridge sessions do; terminal sessions carry it). Payload is
  parsed defensively per the untrusted-input convention. Freshness is wall-clock-derived, so
  when Claude Code stops writing, no file event will ever arrive: a **single timer** is armed
  for the soonest deadline that can still hide the row (and none at all once it is hidden),
  rather than a periodic tick that exists only to notice the absence of one.

**`Modules/SystemHUD/`** (volume / brightness / keyboard-backlight HUD — `VolumeController`,
`BrightnessController`, `KeyboardBacklightController`, `MediaKeyMonitor`) is present but **NOT wired
into `ModuleRegistry`** — dead/unreferenced code kept for possible future use; nothing activates it
at runtime.

## Shared Services

- **`Services/FileSystem/FileChangeWatcher.swift`** — calls back when a single file is written,
  created, replaced, or removed. A vnode `DispatchSource` watches an open descriptor — an
  *inode*, not a path — so a writer that updates atomically (write temp, `rename` into place)
  leaves the watch pointing at the old unlinked inode and no later write is ever reported. The
  watcher therefore re-arms on `.rename`/`.delete`/`.revoke`, and watches the parent directory
  while the file is absent (so it may be started before the file exists). Callbacks are
  debounced, and fire on a private serial queue, not the main actor.
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
notch. The surface renders in every state — with no compact content it rests as a bare black
pill exactly over the cutout — so the tint is always visible. The pill is **always symmetric**:
both sides render at the wider side's measured width (`max(leading, trailing)`), so compact
content never shifts the pill off the notch's center.

## Git

- Committing and pushing directly to this repo is fine — no need to ask first.
- **Commit messages must not carry co-authorship or tooling trailers** — no `Co-Authored-By:`
  line and no `Claude-Session:` line. Keep the message to the change itself.
