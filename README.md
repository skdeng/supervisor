# SuperVisor

> An interactive Dynamic Island for the MacBook notch.

SuperVisor is a native macOS menu-bar app that turns the area around the MacBook notch (or the
top-center of the menu bar on non-notch displays) into a single morphing surface — an
iPhone-style Dynamic Island for the Mac. It stays out of the way as a quiet pill, grows to show
compact live activities on either side of the cutout, and opens into a full panel on click.

It is a SwiftUI + AppKit app (Swift 6.2), distributed as a Swift Package Manager executable with
no Xcode project.

## Requirements

- **macOS 26** (Tahoe) or later, **Apple Silicon**
- A Swift 6.2 toolchain (Xcode 26 / matching command-line tools)
- An Apple signing identity is recommended so privacy grants persist across rebuilds

## Build & run

```sh
./make-app.sh --release        # build, bundle, and sign build/SuperVisor.app
./make-app.sh --release --run  # …and launch it
open build/SuperVisor.app      # launch manually
```

`make-app.sh` prefers a Developer ID Application identity, then Apple Development. Override the
selection with `SIGNING_IDENTITY="Apple Development: …" ./make-app.sh --release`. If neither is
installed, the script falls back to ad-hoc signing; TCC grants may then require approval after
each rebuild.

SuperVisor runs as an `LSUIElement` menu-bar agent: no Dock icon, no main window. A status-bar
item (a `visionpro` glyph) hosts the **Settings…** and **Quit** menu. Quit from there, or
`pkill -f SuperVisor.app`.

> **Why a bundle, not `swift run`?** The privacy grants (Calendar, Reminders, Bluetooth) and the
> now-playing read only persist for a **stable, signed bundle identity**. A bare `swift build`
> binary gets a fresh code identity each launch, so permission grants never stick.
> `make-app.sh` also compiles the MediaRemote adapter dylib (see below), which `swift build`
> does not.

## What it does

Each feature is a self-contained **module** that contributes compact and/or expanded content.
Modules never reference each other; the engine lays them out.

| Module | Compact | Expanded |
| --- | --- | --- |
| **MusicVisor** (Media) | Album-art thumbnail + an equalizer tinted with the artwork's dominant color | Large artwork, title/artist, a live scrubber, transport, and an audio-output switcher |
| **Calendar** | Countdown chip to your next meeting | Agenda with one-tap **Join** (Zoom / Meet / Teams / Webex), plus a **Meeting Mode** call HUD — elapsed timer, system-wide mic mute, output switcher |
| **TaskVisor** (Reminders) | Checklist count badge (red when anything is overdue) | Tap-to-complete checklist of due-today + overdue reminders |
| **FileShelf** | Count badge for staged items; a newly saved screenshot flies into the pill as a transient thumbnail | One inbox for dropped files **and** screenshots — drag in or drop, drag back out, Quick Look, Copy, Copy Text (OCR), AirDrop, Zip, run an agent action, Remove, or Move to Trash |
| **Battery** | Charge ring when low or charging; connected-accessory battery | Power status, time remaining, and Bluetooth-accessory battery |
| **Claude Usage** | — | Live Claude Code plan-quota ticker with utilization and reset time |
| **GPT Usage** | — | Live Codex plan-quota ticker with the same utilization and reset-time UX |

**Meeting Mode** is the standout: while a meeting with a join link is in progress, the sheet leads
with a call HUD. The mic mute is a true system-wide hardware mute (it silences the mic for every
app), and it follows your default input across device changes so switching mics mid-call never
leaves a stale mute behind. A mute you applied via the notch is auto-restored when the meeting
ends.

### FileShelf

FileShelf is one staging inbox for anything you want to hold at the notch — files you drop and
screenshots you take share the same surface, distinguished by a small source badge on each tile:

- Drag files onto the notch to stage them; a newly saved screenshot animates up into the compact
  pill and peeks for a few seconds, then settles into the shelf.
- Any item can be dragged back out to another app, opened in Quick Look, copied, revealed in
  Finder, AirDropped, or zipped. **Copy Text** runs Apple Vision recognition locally on an image
  or PDF and places the detected text on the clipboard — contents are not uploaded or retained.
- **Agent actions** (Summarize / Explain / Extract Text) run a sandboxed local coding agent on the
  file and stage the result back onto the shelf. The file is copied into an isolated scratch
  directory and the agent is restricted to reading only that copy, so a malicious file cannot read
  anything else on disk.
- **Remove** takes an item off the shelf without touching the original. **Move to Trash** is the
  explicit destructive action — it moves the original to the macOS Trash after verifying the file's
  identity, so a file swapped in at the same path is never trashed.

Screenshot detection follows the destination configured in macOS, including custom folders, and
identifies captures through the system `kMDItemIsScreenCapture` metadata rather than a particular
filename or language. Files already present when SuperVisor starts, or when the destination
changes, are baselined and are not surfaced as new captures. Screenshots past the most recent
eight are evicted; dropped files and agent results are kept until you remove them.

## How it works

A single black shape springs open from the notch-hugging pill into the expanded sheet — the fill
stays black and the corner radius interpolates, so it reads as the notch itself expanding rather
than a panel dropping down. The window is a fixed-size transparent canvas that never resizes per
state; only the SwiftUI content morphs, so the animation is never clipped.

- **State machine** — `.idle` → `.compact` → `.expanded`, owned by `Core/NotchEngine.swift`.
- **Plugin contract** — modules conform to `NotchModule` and are wired in one place,
  `App/ModuleRegistry.swift`. The frozen foundation signatures are documented in
  [`ARCHITECTURE.md`](ARCHITECTURE.md).
- **Geometry** — the notch rect is derived from `NSScreen` safe-area insets; non-notch Macs get a
  synthesized region at the top-center of the menu bar.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture and conventions.
See [`PRODUCT_IDEAS.md`](PRODUCT_IDEAS.md) for the product backlog and recommended roadmap.

### Now-playing without an Apple entitlement

Since macOS 15.4, `mediaremoted` gates the now-playing **info read** (the only path that inlines
artwork bytes) to callers whose host process is Apple-signed. An ad-hoc-signed third-party app
gets a `nil` dict. SuperVisor works around this by having **`/usr/bin/perl`** (an Apple-signed
host the gate admits) load a small bundled adapter dylib and make the MediaRemote call from inside
the entitled host, printing the metadata (artwork as base64) as JSON. Transport commands
(play/pause/skip) are not gated and go directly through the private MediaRemote framework.

## Permissions

TCC prompts appear the first time a feature is used. Apple-issued signing keeps grants stable
across rebuilds, and `SuperVisor.entitlements` supplies the Calendar entitlement required by the
hardened runtime. After changing the signature or entitlements, quit the app and reset Calendar
before relaunching:

```sh
tccutil reset Calendar com.supervisor.SuperVisor
```

| Permission | Needed by | For |
| --- | --- | --- |
| Calendar (Full Access) | Calendar | Reading upcoming events and detecting join links |
| Reminders (Full Access) | TaskVisor | Reading due/overdue reminders and completing them |
| Bluetooth | Battery | Reading accessory battery levels |
| Files and Folders | FileShelf | Watching the configured macOS screenshot folder for newly saved captures |

FileShelf reads only the configured screenshot directory and the files you stage (for preview,
copy, OCR, or an agent action). It does not use Screen Recording permission and does not capture
the screen itself; macOS remains responsible for creating every screenshot.

Controlling the microphone's hardware mute (Meeting Mode) uses CoreAudio to control the *device*,
not capture it, so it needs **no** Microphone permission and does not trip the recording
indicator. The `Info.plist` also declares Location and Accessibility usage strings for planned
modules (weather, notification mirroring) that are not yet wired, so those prompts do not fire at
runtime.

## Project layout

```
Sources/
  SuperVisor/
    App/         AppDelegate, ModuleRegistry, SettingsView
    Core/        NotchEngine, NotchWindow, NotchModule/Context, ScreenGeometry, HoverMonitor
    UI/          NotchRootView, shared surfaces and usage-ticker chrome
    Modules/     Media, Calendar, Reminders, Capture, FileShelf, Battery, Usage, GPTUsage (+ unwired SystemHUD)
    Services/    Shared Audio and FileSystem integrations
    Theme/       LiquidGlass design tokens
    Settings/    SettingsStore
  MediaRemoteAdapter/
    mediaremote_adapter.m   compiled by make-app.sh into the bundled adapter dylib
Info.plist       embedded into the binary and copied into the bundle
make-app.sh      build + bundle + sign
```

Any `.swift` file placed anywhere under `Sources/SuperVisor/` is compiled automatically —
`Package.swift` is never edited to add files. The three foundation files
(`Core/NotchModule.swift`, `Core/NotchContext.swift`, `App/ModuleRegistry.swift`) define contract
signatures the engine and every module depend on; treat them as frozen (see `ARCHITECTURE.md`).

## License

No license has been chosen yet — all rights reserved by the author until one is added.
