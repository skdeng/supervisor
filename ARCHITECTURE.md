# DynamicLake Architecture

DynamicLake is a native macOS app that turns the MacBook notch / top menu-bar area
into an interactive, iPhone-style Dynamic Island. It is built with SwiftUI + AppKit,
Swift 6.2, targeting macOS 26.5 (Liquid Glass materials), Apple Silicon. Distribution
is via Swift Package Manager with a single path-based executable target at
`Sources/DynamicLake` — any `.swift` file placed anywhere under that directory is
compiled automatically. There are no target-membership concerns and `Package.swift`
is never edited to add files.

This document is the contract every other builder works against. The three foundation
files (`Core/NotchModule.swift`, `Core/NotchContext.swift`, `App/ModuleRegistry.swift`)
define byte-exact signatures that modules and the engine depend on; do not change them.

---

## 1. The Notch Interaction Model

The notch surface moves through a small set of well-defined states. The engine owns
the window, geometry, and hover detection; modules only contribute content.

### Idle pill
When nothing is happening, the notch renders as a minimal rounded-rectangle "pill"
that hugs the physical notch (or, on non-notched displays, a synthesized notch region
at the top-center of the menu bar). It is visually quiet and matches the black of the
physical notch so it reads as part of the hardware.

### Compact live-activities
When one or more modules have live state to show (music playing, a timer counting down,
a battery event, a file being dragged), the pill grows just enough to host **compact
contributions** on either side of the physical notch cutout:
- `compactLeading()` renders to the **left** of the notch.
- `compactTrailing()` renders to the **right** of the notch.

Multiple modules can contribute simultaneously; the engine lays them out and sizes the
pill to fit. Compact views are deliberately tiny: a glyph, a waveform, a short label.

### Expanded panel
On **hover-to-expand** (pointer enters the notch region) or on an explicit
`requestExpand()`, the pill animates open into a full **expanded panel** that drops
below the menu bar. The panel stacks every module's `expandedSection()` vertically,
sorted by each module's `order` (lower first). This is the rich, interactive surface:
media transport controls, the file shelf, system HUD detail, glance widgets, timer
lists, the notification feed, and the unit converter.

The panel collapses back to the pill when the pointer leaves, after a short grace
delay, or on `requestCollapse()`.

### Peek-on-event
Modules can call `requestPeek(seconds)` to briefly surface a transient compact update
without a full expansion — e.g. "AirPods connected", "Now charging", "Volume". The
engine shows the relevant compact content for the requested duration, then auto-collapses
back toward idle. Peek never steals the expanded panel; it is a lightweight compact nudge.

### miniLake compact mode
**miniLake** is a reduced-footprint presentation of the compact pill for users who want
a smaller, less assertive island. In miniLake the pill keeps tighter padding, prefers
single-side compact content, and suppresses lower-priority compact contributions so the
surface stays close to the size of the bare notch. It is a presentation mode of the
same compact state, not a separate window or state machine.

### Liquid Glass theming
All chrome — the pill body, the expanded panel, separators, and module surfaces — is
rendered through Liquid Glass material wrappers (in `Theme/`) so the app adopts the
native macOS 26 material, blur, and lighting. Modules render their content inside these
materials rather than drawing their own backgrounds, keeping the whole surface visually
coherent and adaptive to wallpaper and light/dark appearance.

---

## 2. The NotchModule Plugin Contract

Every feature is a **module** conforming to the `@MainActor public protocol NotchModule`
(`Core/NotchModule.swift`). A module is the unit of behavior and UI; the engine knows
nothing about any specific feature.

### Identity & ordering
- `moduleID: String` — stable unique id, e.g. `"media"`.
- `displayName: String` — human-readable name shown in settings UI.
- `order: Int` — sort order in the expanded panel; lower renders earlier
  (default `100` via protocol extension).

### Lifecycle
- `activate(_ context: NotchContext)` — called once at engine launch. The module begins
  observing system state here and **captures the `NotchContext`** for later use.
- `deactivate()` — called on shutdown; tear down observers, cancel timers, release
  resources.

### UI contributions
- `compactLeading() -> AnyView?` — content left of the notch in the collapsed pill.
- `compactTrailing() -> AnyView?` — content right of the notch in the collapsed pill.
- `expandedSection() -> AnyView?` — the module's section in the expanded panel.

All three default to `nil` (contribute nothing) via the protocol extension, so a module
implements only the surfaces it needs.

### Reacting via ObservableObject
The idiomatic module is:

```swift
@MainActor
final class MediaModule: NotchModule, ObservableObject {
    let moduleID = "media"
    let displayName = "Media"
    @Published private var nowPlaying: NowPlaying?
    ...
}
```

Each `AnyView` a module returns wraps an `@ObservedObject` of the module itself. When
the module mutates its `@Published` state, **only that view subtree re-renders** — the
engine is not involved. This keeps per-module updates cheap and isolated.

### When to tell the engine to re-lay-out
Internal value changes inside an **already-shown** compact view (e.g. the track title
changes) update automatically through `@ObservedObject`. The engine only needs to be
told when a compact contribution **appears or disappears**, because that changes the
pill's size and layout. For that, call `context.setNeedsCompactRefresh()`.

### NotchContext services
`NotchContext` (`Core/NotchContext.swift`) is what the engine hands each module in
`activate`. It exposes four closures:
- `requestExpand()` — force the notch open.
- `requestCollapse()` — force it closed.
- `requestPeek(seconds:)` — briefly present a transient compact update, then auto-collapse.
- `setNeedsCompactRefresh()` — tell the pill to re-lay-out because a compact contribution
  appeared/disappeared.

### Registration — the single integration point
`App/ModuleRegistry.allModules()` is **THE** one place modules are wired in. Foundation
ships it returning `[]`; the integration phase inserts `ModuleName()` lines at the
`<INTEGRATION:MODULES>` marker. Array order is irrelevant — modules sort themselves via
`order`. Modules never reference each other and never touch the registry except by being
listed here.

---

## 3. File Layout

```
Sources/DynamicLake/
  App/        app entry, AppDelegate, ModuleRegistry (the ONE integration point)
  Core/       NotchModule.swift, NotchContext.swift, engine, window, geometry, hover
  UI/         root view, compact pill, expanded panel
  Theme/      Liquid Glass material wrappers
  Settings/   settings store
  Modules/<Name>/   one folder per feature module, self-contained
```

- **App/** — `@main` entry point, `AppDelegate`, and `ModuleRegistry`.
- **Core/** — the protocol/context contract plus the engine that owns the notch window,
  computes geometry (notch detection, pill/panel frames), and runs hover detection and
  the state machine (idle / compact / peek / expanded).
- **UI/** — the SwiftUI root view and the two presentation shells: the compact pill and
  the expanded panel that compose module contributions.
- **Theme/** — Liquid Glass material wrappers shared by all chrome and modules.
- **Settings/** — the settings store (enabled modules, miniLake mode, per-module prefs).
- **Modules/<Name>/** — each feature lives in its own self-contained folder; a module
  folder owns its model, system observers, and SwiftUI views.

---

## 4. Private-Framework Access (dlopen / dlsym)

Several modules need private system frameworks (MediaRemote for now-playing, DisplayServices
for brightness, etc.). To stay SPM-friendly, **never** add a bridging header or a custom
module map — both break Swift Package Manager builds.

Instead, resolve symbols at runtime with `dlopen()` + `dlsym()` and `unsafeBitCast` the
raw pointer to a typed Swift closure or C-function type:

```swift
// Open the private framework by path.
guard let handle = dlopen(
    "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
    RTLD_NOW
) else { return }

// Resolve a symbol and bind it to a precise Swift function type.
typealias GetNowPlayingInfo = @convention(c) (
    DispatchQueue, @escaping ([String: Any]) -> Void
) -> Void

guard let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return }
let MRMediaRemoteGetNowPlayingInfo = unsafeBitCast(sym, to: GetNowPlayingInfo.self)

MRMediaRemoteGetNowPlayingInfo(.main) { info in
    // use info
}
```

Guidelines:
- Match the `@convention(c)` signature **exactly** (calling convention, ownership,
  block vs. C function). A wrong type is undefined behavior.
- `dlopen` the framework once and cache the handle; resolve each symbol once.
- Guard every `dlopen`/`dlsym` and degrade gracefully if a symbol is missing on a given
  OS — these are unsupported APIs and can change between releases.

---

## 5. Module Roster

The following modules make up the full build. Each lives in `Modules/<Name>/` and is
self-contained.

### media
Now-playing surface. Observes the system media session (via MediaRemote, accessed through
the dlopen/dlsym pattern) for the active app's track, artist, artwork, and playback state.
Compact: a small artwork/waveform on one side and a play state glyph. Expanded: full
transport controls (play/pause, skip), scrubber, artwork, and source app.

### systemhud
System heads-up display. Replaces/augments the OS overlays for **volume**, **brightness**,
and related toggles. Observes the relevant system state and peeks on change
(`requestPeek`) to show a compact level indicator. Expanded: sliders and current values.

### fileshelf
A drag-and-drop staging shelf living in the notch. Dragging files over the notch expands
a drop zone; dropped items are held in a temporary shelf the user can drag back out to
any target (Finder, Mail, chat). Compact: a count/affordance when items are held.
Expanded: thumbnails of staged files with remove/clear.

### glance
At-a-glance widgets — small informational tiles (e.g. clock/date, calendar next-event,
weather, simple status). Primarily an expanded-panel contributor that surfaces quick
context without leaving the current app. May peek for time-sensitive items.

### battery
Power and charging status. Observes battery level, charging/charged state, time-remaining,
and power-source changes. Peeks on plug/unplug and low-battery events with a compact
indicator; expanded shows percentage, charging state, and time estimate. Also surfaces
connected-device battery (e.g. AirPods, mouse) where available.

### timers
Countdown timers and stopwatches created and controlled from the notch. Compact: a live
countdown next to the notch while a timer runs. Expanded: list of active/paused timers
with create, pause/resume, and cancel; fires a peek/expand when a timer completes.

### notifications
A notification feed surfaced in the island. Captures incoming notifications and presents
them as a compact peek on arrival and a scrollable feed in the expanded panel, with
quick actions where supported. Lets recent notifications be re-reviewed without opening
Notification Center.

### conversion
Inline unit / currency converter. A small utility surface in the expanded panel for quick
conversions (length, weight, temperature, currency, etc.). Primarily expanded-only;
takes input and shows converted results without leaving the current app.
