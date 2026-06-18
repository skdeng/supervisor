# DynamicLake

A native macOS (macOS 26, Apple Silicon) menu-bar app that turns the MacBook notch / top
menu-bar area into an interactive, iPhone-style Dynamic Island. SwiftUI + AppKit, Swift 6.2.
It is a Swift Package Manager **executable** (`Sources/DynamicLake`) — there is no Xcode
project. Any `.swift` file placed anywhere under `Sources/DynamicLake/` is compiled
automatically; `Package.swift` is never edited to add files.

`ARCHITECTURE.md` is the canonical, byte-exact contract for the foundation files. Read it
before touching `Core/NotchModule.swift`, `Core/NotchContext.swift`, or
`App/ModuleRegistry.swift` — modules and the engine depend on those signatures; do not change
them.

## Build & Run

- **`./make-app.sh --release`** — builds, bundles, and ad-hoc-signs `build/DynamicLake.app`.
  (`--run` also launches it; drop `--release` for a debug build.)
- **`open build/DynamicLake.app`** — launch. It is an **`LSUIElement`** menu-bar agent
  (`.accessory` activation policy): no Dock icon, no main window. A status-bar item
  (`water.waves` glyph) hosts the **Settings…** and **Quit** menu.
- **Quit** via the status-bar menu, or `pkill -f DynamicLake.app`.
- **`swift build`** alone compiles the binary but does *not* produce the bundle. The bundle is
  required because TCC permission grants (Location, Calendar, Accessibility, Bluetooth) and the
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
  Array order is irrelevant; modules sort by `order`. Currently lists all 8 modules.
- **`Core/NotchEngine.swift`** — owns the window, geometry, hover detection, the enabled-module
  list, and the state machine: `NotchState` is `.idle` / `.compact` / `.expanded` (peek is a
  transient `.compact`). Builds the `NotchContext`, filters modules by `SettingsStore`, activates
  them sorted by `order`. Note: the sheet opens on **click** (`toggleSheet()`), hover only shows
  a subtle grow affordance. `compactRevision` is bumped on `setNeedsCompactRefresh`.
- **`Core/NotchWindow.swift`** — a borderless, non-activating `NSPanel` above the status-bar
  level, on all spaces, floating over fullscreen, transparent. It is a **fixed-size canvas**
  (`canvasFrame`): always large enough for the expanded panel and widest compact content, so it
  **never resizes per state** — only the SwiftUI content morphs, so the Dynamic-Island animation
  is never clipped by a window resize. Click-through (`ignoresMouseEvents`) except when hovered or
  expanded, so the desktop/menu bar underneath stay usable.
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

## Module Roster

Each lives self-contained in `Modules/<Name>/` (model + system observers + SwiftUI views).

- **Media** — system now-playing surface; artwork/state in compact, full transport + scrubber in
  expanded. (Info via the perl adapter; commands via `MediaRemoteBridge`.)
- **SystemHUD** — replaces OS overlays for volume / brightness / keyboard backlight; peeks a level
  indicator on change, sliders in expanded. (`VolumeController`, `BrightnessController`,
  `KeyboardBacklightController`, `MediaKeyMonitor`.)
- **FileShelf** — drag-and-drop staging shelf; drop files onto the notch, hold them, drag back out.
  Thumbnails, Quick Look, count affordance. (`FileShelfStore`, `ThumbnailService`,
  `QuickLookController`, `FileActionService`.)
- **Glance** — at-a-glance tiles (clock/date, calendar next-event, weather). Mostly expanded-only.
  (`CalendarService`, `WeatherService`.)
- **Battery** — power/charging status, time remaining, and connected-device (Bluetooth accessory)
  battery; peeks on plug/unplug and low battery. (`PowerSourceMonitor`, `BluetoothMonitor`.)
- **Timers** — countdown timers/stopwatches created from the notch; live countdown in compact,
  list + create/pause/cancel in expanded; peeks/expands on completion.
- **Notifications** — mirrors incoming notification banners; compact peek on arrival, scrollable
  feed in expanded. (`NotificationCenterObserver`, `NotificationAppIconResolver`.)
- **Conversion** — inline unit/currency converter (and media conversion via ffmpeg —
  `FFmpegLocator`, `ConversionRunner`); expanded utility surface.

## Theme & Settings

- **`Theme/LiquidGlass.swift`** (`NotchTheme`) — design tokens + Liquid Glass material wrappers.
  The notch pill is opaque black (blends with the hardware cutout); the expanded panel and floating
  surfaces use the native macOS 26 Liquid Glass material, degrading to `.ultraThinMaterial`.
- **`Settings/SettingsStore.swift`** — `UserDefaults`-backed, `SettingsStore.shared`. Per-module
  enabled flags (default on), **miniLake** (reduced-footprint compact mode), and hover sensitivity.

## Debug

`SettingsStore.debugTintEnabled` (a toggle in Settings, persisted as `debug.tintRed`) tints the
whole rendered surface **bright red** so its exact bounds are visible against the black hardware
notch. In debug tint the surface always renders even when idle.
