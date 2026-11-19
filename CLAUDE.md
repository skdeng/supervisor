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

- **`./make-app.sh --release`** — builds, bundles, and signs `build/SuperVisor.app`.
  (`--run` also launches it; drop `--release` for a debug build.) It prefers Developer ID
  Application, then Apple Development, and falls back to ad-hoc signing. Set
  `SIGNING_IDENTITY` to override selection. **Building over a running app leaves that app on the old code**: the process keeps running
  what it was launched with while the bundle on disk is the new build, and anything that
  checks the process against its bundle refuses it. The bridge helper is started from the
  bundle on disk and makes that check, so every ProVisor pass would lose its site, text, and
  photo-place tools while still finishing normally. **The app therefore relaunches itself**
  (`App/BundleReplacementMonitor.swift`): it watches its bundle and, once the running code
  is no longer the code on disk, waits until nothing is in progress and the bundle is whole
  and signed to its own designated requirement, then quits and reopens. An ad-hoc build is
  never relaunched into (its requirement names one exact build), so after one, quit and
  reopen by hand; `codesign --verify <pid>` answers "the code on disk does not match what is
  running" while an app is out of date.
- **`open build/SuperVisor.app`** — launch. It is an **`LSUIElement`** menu-bar agent
  (`.accessory` activation policy): no Dock icon, no main window. A status-bar item
  (`visionpro` glyph) hosts the **Settings…** and **Quit** menu. **The app still installs a
  main menu** (`App/MainMenu.swift`), which an accessory app never shows: ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z,
  and ⌘W are key equivalents of menu items, and with no main menu they do nothing in any of
  the app's ordinary windows, a web page included, while a right-click's Paste still works.
- **Quit** via the status-bar menu, or `pkill -f SuperVisor.app`.
- **`swift test`** runs the suite in `Tests/SuperVisorTests` (Swift Testing). The test target
  depends on the executable target and reaches internals through `@testable import SuperVisor`,
  so logic can be tested without a second library target. Tests that need a session registry
  write real records to a temp directory using the test process's own pid, which is what makes
  them pass the registry's liveness check. **A test file that compares two `CGFloat` values
  must `import Foundation`.** With only `Testing` and `@testable import SuperVisor` imported,
  `#expect(a == b)` fails on two `CGFloat`s whose bit patterns are identical (the failure prints
  `205.0 == 205.0`); the operator resolves differently inside the macro's expansion without
  CoreGraphics in scope. Comparisons against an integer literal pass either way, so the gap
  shows only once a test holds both sides in `CGFloat` variables. **Tests that start the built
  executable** (the bridge helper's and the disclaimed launcher's process tests) run only when
  `.build/debug/SuperVisor` is newer than every source file, and need `DYLD_FRAMEWORK_PATH` to
  name the `Sparkle.framework` beside it (`BuiltExecutable` in `BridgeTestSupport.swift`): the
  bare executable carries no run-path for it, and only the app bundle's embedded copy resolves
  without help. A binary that predates a launch mode starts the whole app when handed that
  mode's flag, so a stale or missing one skips those tests (`BuiltExecutable.skipReason`) and
  they report as skipped, not failed. The build system relinks only when a source's *content*
  changed, so after a checkout or restore that moved modification times alone, delete
  `.build/debug/SuperVisor` and run `swift build`. A Unix socket path holds 104 bytes and the
  temporary directory already takes about 50, so tests name their sockets with short folder and
  file names (`ScratchFolder`). Site tests run against `SiteBrowser`'s simulated pages (see
  `Services/Sites/` under Shared Services). **`AppLog.install` captures for the whole test
  process**, and suites run in parallel, so a test that asserts the exact lines logged, or that
  nothing was logged, fails whenever another suite logs or installs a capture of its own
  meanwhile; test the decision that leads to the line as a pure function. **Two `async let`
  children start in no fixed order**, so a test may assert what each call returned but not which
  ran last, and a bound that tells two outcomes apart sits far from both (15 s against 60 s, not
  0.5 s against 1 s): the suite runs under load. **A run that ends with status 0 and no
  `Test run with N tests` line stopped early and proved nothing.** The test process's main
  thread sits in one outer `CFRunLoopRun`, and the Swift runtime calls `exit(0)` the moment it
  returns, with every test still waiting on the main actor unreported. **Never enter
  `NSApplication.run()` in the process that runs the suite**: once AppKit's event loop has run
  there, its display cycle wakes the main run loop with `CFRunLoopStop` whenever a window has
  work, and with the event loop gone that stops the outer loop. A check that needs the
  application's own loop runs in a child process, as an exit test
  (`#expect(processExitsWith:)`), and ends the child from inside the loop with a status of
  its own, so a child that stopped early fails the test; expectations recorded in the child
  reach the parent (`ProVisorReviewWindowTests`). A
  run can also die on an uncaught `NSInternalInconsistencyException` thrown by
  `STScreenTimeConfigurationObserver` while a `WKWebView` deallocates, which is the system's
  frameworks and leaves a `swiftpm-testing-helper` crash report. **Run the suite with the
  display awake**: with it off, the tests that load pages in a web view fail by the hundred
  and a run takes about half an hour.
- **`swift build`** alone compiles the binary but does *not* produce the bundle. The bundle is
  required because TCC permission grants (Location, Calendar, Reminders, Photos, Accessibility,
  Bluetooth, Full Disk Access) and the now-playing read only persist for a **stable, signed
  bundle identity** — a bare `swift run`
  binary gets a fresh identity each launch and grants never stick. `make-app.sh` also compiles
  the MediaRemote adapter dylib (see below), embeds Sparkle.framework from the SPM artifact
  into `Contents/Frameworks` (rewriting the binary's rpath to resolve it there), signs every
  nested component individually — **never `--deep`**, which would stamp the app's TCC
  entitlements onto Sparkle's XPC services — applies `SuperVisor.entitlements`, and DER-encodes
  its Calendar entitlement; `swift build` does none of those packaging steps. Release builds
  carry a secure timestamp so signatures outlive the signing certificate. The adapter is
  compiled against the selected toolchain's SDK (`xcrun --sdk macosx --show-sdk-path`), never
  clang's default: the Command Line Tools SDK updates independently of Xcode, and once it is
  newer than the installed Xcode its `.tbd` stubs fail to link under Xcode's clang with
  `unknown architecture`. `swift build` is unaffected, so the package compiles while the bundle
  build fails at the adapter step.
- **`open -n build/SuperVisor.app --args --self-check <name> --report <file>`** runs one check of
  operating-system behaviour no test can reach, writes one JSON object to the report file, and
  exits (`App/SelfCheck.swift`; `SuperVisorMain.main()` dispatches it before the menu-bar app
  starts). A report holds counts, statuses, and timings, never message text, page content, or a
  secret. **Start it through `open`, never as a binary from a shell**: privacy grants and
  Keychain access are decided for the app responsible for a process, and a shell-started binary
  answers for the terminal, so its result says nothing about SuperVisor. It needs the bundle
  `make-app.sh` builds. The checks:
  - `keychain` — an item the app wrote is readable by the next launch with no prompt (run it
    twice; `foundEarlierItem`, `readSeconds`).
  - `messages` — whether the app reads the Messages database, and whether `/bin/cat` started the
    ordinary way and started with responsibility disclaimed can. With Full Disk Access granted
    the first can and the second cannot; without the grant neither can. `disclaimed-exec` asks
    the same of a program started through `--exec-disclaimed`.
  - `history` — the browsing-history files open and carry the tables and columns
    `BrowsingHistory` reads (counts and flags; Chrome's and Safari's need Full Disk Access).
  - `photos` — whether the app may read Photos (`access`: `notAsked`, `allowed`, `denied`; the
    check never asks) and, when it may, how many photos the read looked at, how many carry a
    position, and how the whole library groups into stays (`photosScanned`,
    `photosWithPosition`, `stays`, `groupingMetres`, `readSeconds`). **`allowed` proves
    nothing about the read**: only `photosScanned` above zero shows PhotoKit handed the
    library over.
  - `webkit` — a web view that is never shown loads a page, and its data store keeps a cookie
    across launches (run it twice; `cookieFromEarlierLaunch`). `site-read` — `SiteBrowser` reads
    `https://example.com/` and reports counts, and whether a page in its hidden window is
    told it is visible and given animation frames (`pageVisible`, `animationFrame`; needs a
    network).
  - `agent`, `bridge`, `tools`, `connectors` — start real agent runs, each capped at a $0.05 to
    $0.10 spending limit on the user's plan. `agent`: the CLI answers a one-turn prompt when
    started through `AgentTaskService`, disclaimed. `bridge`: a run reaches a served tool through
    the helper, and `helperDepth` (the parents between the helper and the CLI) must not exceed
    `admittedDepth`. `tools`: a run's `open_site` call reaches `ProVisorTools` and returns its
    unknown-site answer. `connectors`: three runs carrying the hold configuration each find a
    Gmail tool on their first turn (`foundTool` should equal `runs`).
- **`./release.sh <version> [notes…]`** — cuts a Sparkle auto-update release: asserts
  main/clean-tree/Developer ID, stamps `Info.plist`, builds, zips, EdDSA-signs the zip (private
  key in the login Keychain as "Private key for signing Sparkle updates"), prepends the
  `appcast.xml` item, commits and tags, then publishes **asset first, feed last** (tag + GitHub
  release upload before the appcast push) so the feed never points at a missing download. The
  feed is `appcast.xml` on `main` via raw.githubusercontent.com; installed apps check daily
  (`SUFeedURL`/`SUPublicEDKey` in Info.plist) and also offer **Check for Updates…** in the
  status-bar menu. Updates verify against the EdDSA key plus the app's own code signature, so
  a release signed by anything but the Developer ID identity would be refused by installed
  copies — which is why the script hard-fails without that identity. **Testing the update
  channel requires an https feed**: the appcast fetch (in-process) tolerates http://localhost,
  but the zip download runs in Sparkle's Downloader XPC, whose own ATS policy
  (`NSAllowsArbitraryLoads=false`) silently refuses plain http — the check "works" and the
  download never even reaches the server. Test against real https (a temporary GitHub
  prerelease holding both a scratch appcast and the zip works), overriding the feed with
  `defaults write com.supervisor.SuperVisor SUFeedURL <url>` — and **always
  `defaults delete` that key afterward**: Sparkle persists it over the Info.plist value.

## High-Level Architecture

A single morphing surface, driven by a small state machine, that modules feed content into.

- **`Core/NotchModule.swift`** — the plugin contract. `@MainActor public protocol NotchModule`:
  `moduleID` / `displayName` / `order` (lower renders earlier in the expanded panel),
  `activate(_:)` / `deactivate()`, and four optional UI surfaces — `compactLeading()`,
  `compactTrailing()`, `expandedSection()`, and `peekBanner()` (a banner during a peek — below the
  notch over a physical cutout, inside the pill's gap on a screen without one; it must be
  intrinsically sizable on both axes). Each returns `AnyView?` and defaults to `nil`. Modules are
  typically `final class … : NotchModule, ObservableObject`; the `AnyView`s they return wrap an
  `@ObservedObject` of themselves, so a module's own `@Published` changes re-render only its
  subtree. Modules never reference each other.
- **`Core/NotchContext.swift`** — services handed to each module in `activate`. Four closures:
  `requestExpand()`, `requestCollapse()`, `requestPeek(seconds:)`, and
  `setNeedsCompactRefresh()`. The last is required *only* when a compact contribution
  **appears or disappears** (which changes pill size/layout) — internal value changes inside an
  already-shown compact view update automatically via `@ObservedObject`.
- **`App/ModuleRegistry.swift`** — THE single place modules are wired in (`allModules()`).
  Array order is irrelevant; modules sort by `order`. Currently lists 8 modules
  (Media, Calendar, Reminders, FileShelf, SwarmVisor, ProVisor, Battery, AI Usage).
- **`Core/HoverMonitor.swift`** — hover detection through a global mouse-moved monitor, which
  wakes the process on every cursor movement anywhere on screen; its handler reads the position
  the event already carries, per the file's doc comment.
- **`Core/NotchEngine.swift`** — owns the window, geometry, hover detection, the enabled-module
  list, and the state machine: `NotchState` is `.idle` / `.compact` / `.expanded` (peek is a
  transient `.compact`). Builds the `NotchContext`, filters modules by `SettingsStore`, activates
  them sorted by `order`. Enabling or disabling a module in Settings activates/deactivates it live
  (`reconcileModules`, driven by `SettingsStore.$moduleEnabled`) — no relaunch. Note: the sheet
  opens on **click** (`toggleSheet()`), hover only shows a subtle grow affordance. `compactRevision`
  is bumped on `setNeedsCompactRefresh`. **A hold requested while the sheet is open is not
  taken** (`requestPeek` ignores it), so when the surface leaves `.expanded` by any path the
  engine peeks again if some module still supplies a banner (`resumesPeek`); a banner raised
  under an open sheet would otherwise have a glow and never show.
- **`Core/NotchWindow.swift`** — a borderless, non-activating `NSPanel` above the status-bar
  level, on all spaces, floating over fullscreen, transparent. It is a **fixed-size canvas**
  (`canvasFrame`): always large enough for the expanded panel, the widest compact content, and
  the FileShelf side card with its shadow slack (budgeted on both sides, since the canvas stays
  centered on the notch), so it **never resizes per state** — only the SwiftUI content morphs,
  so the Dynamic-Island animation is never clipped by a window resize. Events pass through everywhere except the notch/sheet
  region: `NotchContentContainer` hit-tests against an interactive rect (so clicks and file drags
  land only there) and is also a file-drag destination — dragging a file onto the notch opens the
  sheet — while the desktop/menu bar stay usable elsewhere. The canvas sits *on* the screen's top
  edge, inside the camera housing's safe area, so two things keep it there: `constrainFrameRect`
  is overridden to return the frame untouched, and `NotchRootView` applies `.ignoresSafeArea()`
  — otherwise the hosting view insets the content by the notch height and the whole surface
  renders below the hardware notch instead of over it.
- **`UI/NotchRootView.swift`** — the **single morphing surface**. One black `NotchShape` grows
  (width + height spring) from the notch-hugging pill into the expanded sheet; the fill stays
  black and the corner radius interpolates so the open reads as the notch itself expanding, not a
  separate panel dropping down. A solid black "camera cap" always covers the physical cutout. Hosts
  `CompactPillView` (fades out on expand) and `ExpandedPanelView` (fades in after the grow). **The
  material is the stack's `.background`, sized by the surface's frame** — a ZStack proposes its
  union size to a flexible member, and the sheet pre-built during hover overflows the frame, so a
  member `Color.clear` would hand the glass a sheet-sized shape whose refraction rims sit outside
  the visible pill; every hover morph would then pop as the rims slide back onto it. The panel's
  exit transition mirrors its hidden-state modifiers (fade + shrink), so a hover-exit close fades
  the content the same way a click close does instead of dropping it in one frame.
- **`UI/ExpandedPanelView.swift`** — the sheet's section stack, and where the sheet's finite height
  is rationed. **The media section anchors the top and is never displaced** — it is a tall,
  distinctive shape the eye expects there, and moving it costs more legibility than any reordering
  below it wins back. Beneath it, sections whose module has raised `SectionUrgencyCenter` lead;
  module `order` sorts within the urgent group and within the quiet one, and `moduleID` breaks a
  remaining tie so a rebuild never reshuffles the sheet. The panel measures its natural height and reports it to the
  engine, which grows the surface to fit up to `maxExpandedSheetHeight`; content past that is
  clipped by the surface shape, so the panel masks its bottom `SheetOverflowFade.bandHeight` into a
  dissolve at the cut — a full sheet reads as continuing rather than as a rendering fault. The mask
  is applied unconditionally (fully opaque while the content fits) so crossing the ceiling never
  swaps view identity and tears down the live section views and their timers. **Sections curate
  themselves**: each keeps its own list short by default and folds the remainder behind a count
  (SwarmVisor's **N idle**, the agenda's **N later** and **N dismissed**), because a fixed budget
  spent by whoever renders first is what overflows in the first place.
  A takeover raised through `SheetTakeoverCenter` (see Shared Services) replaces the section stack
  while it is presented.

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
it into a floating pill**: it drops `pillTopDrop` (a quarter of the notch height), swells —
proportionally in height (`NotchTheme.pillHoverScale`) and by the fixed `hoverWidthPad` per side
in width — and its concave menu-bar flares curl inward into convex corners. The
open sheet keeps that silhouette, so the pill grows rather than snapping back to the edge. The
hover swell is **layout growth, not a render transform**: the surface's frame widens by the
fixed pad and the content row re-lays-out to the grown width, so nothing rasterizes — content
keeps its natural size while the flexible gap (the pill's cutout) absorbs the growth. The edge
margin is derived, not a fixed token (`NotchRootView.surfaceEdgePad`): the visible side margin
equals the vertical margin standard-height compact content holds in the bare notch strip —
`(grownNotchH − NotchTheme.compactContentHeight) / 2`, plus the flare inset the body sides tuck
behind while attached — so the pill's side and top/bottom margins match through the hover swell
and the detach morph alike. An inline peek swells the strip past that floor; flanking content
then gains extra top/bottom clearance while its side margin holds.

**A peek banner rides inside the pill here** (`NotchRootView.inlinePeek`), rather than as a second
row below it: the module's `peekBanner()` renders centered in the cutout gap between the compact
columns, and the pill grows around it on both axes. `stripH` swells so the banner clears the strip
by `surfaceEdgePad` above and below; the gap widens by `surfaceEdgePad` per side in a bare pill —
matching that vertical margin — or by `NotchTheme.compactSidePadding` per side when flanked, which
with the columns' own padding leaves 16pt between the banner and each neighbouring live activity.
Hover growth reaches the inline pill only through `surfaceEdgePad` and the columns' padding, never
an added `hoverWidthPad`. Width is clamped to `NotchEngine.collapsedWidthLimit` (the fixed canvas
minus 8pt), and `NotchRootView` reports the laid-out width and strip height to the engine
(`reportCollapsedSurface`), which sizes the hit-test and hover rects from them and re-runs
`HoverMonitor.refresh()` — a banner can arrive with the cursor stationary, so absent
that refresh no mouse event would re-evaluate hover once the pill retracts and it would stay
detached.

- **`NotchShape`** morphs on one continuous `pillness` (0…1), animated through
  `AnimatablePair(cornerRadius, pillness)`. Each top corner is a **single** quadratic curve, not
  two: the concave flute and the convex corner share the same control point (the corner) and
  differ only in their endpoints, which slide from `-flare` outside the body to `+rounding` inside
  it. Growing a second curve beside a shrinking first reads as a bump next to a dip. The flare
  doubles as the body's side inset: attached, the sides tuck `topRadius` behind the flares; as
  the surface detaches they slide out so the floating pill fills its frame edge to edge. The
  derived edge padding sheds that same flare inset as `pillness` rises, so the visible side
  margin holds steady through the morph instead of widening as the body reaches the frame. At
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

## Now-Playing: the macOS 15.4+ gate and per-app sessions (non-obvious)

Since macOS 15.4, `mediaremoted` gates now-playing **info reads** to callers whose **host
process** is Apple-signed (`com.apple.*`). An ad-hoc-signed third-party app gets a `nil` dict from
`MRMediaRemoteGetNowPlayingInfo` and "Operation not permitted" from `MRNowPlayingRequest`.
Workaround:

- `make-app.sh` compiles **`Sources/MediaRemoteAdapter/mediaremote_adapter.m`** into
  `mediaremote_adapter.dylib`, shipped in the bundle's `Resources/`. It exports two entry points.
- **It reads every app's session, never just the elected one.** macOS elects ONE app as "the"
  now-playing app, and that election lags behind what is audible: a video started in a browser
  can play for minutes while a paused music app stays elected. The helper therefore lists every
  now-playing client (`MRMediaRemoteGetNowPlayingClients`, the list Control Center renders) and
  asks each for its playback state, info dict, and artwork through `MRNowPlayingRequest`,
  printing `{"capturedAt":…,"sessions":[…]}`. It caches each session's artwork per track, so a
  steady-state re-read moves no image bytes, and stops asking a track for artwork after five
  empty answers. A capture missing any client's state or info reply by its deadline is
  **incomplete and not reported** (the one-shot prints `{}`; the stream skips it, reporting a
  partial one only after two in a row) — otherwise a slow reply would make a session vanish for
  one read. The Swift side keeps its state on an unanswered read and ignores a capture older
  than the one it last applied, since the stream and a one-shot read are separate helpers. When
  the per-app surface cannot be resolved, or yields no session, the helper reads the elected app
  alone (`MRMediaRemoteGetNowPlayingInfo`), reported as a session with no app identity. `MRMediaRemoteGetActivePlayerPathsForOrigin` is **not** a substitute for the client
  list: it returns only the elected app's path.
- **Which session the notch presents** is `NowPlayingSelection` (pure, in `Modules/Media`): a
  session that starts playing takes over; the presented one stays while it plays, yields to one
  still playing once it stops, and stays put when nothing plays; a session picked from the
  session list is pinned until it ends or a different session starts playing. The election is
  only the cold-start tie-break.
- **Streaming (the live path).** `Modules/Media/NowPlayingStream.swift` spawns **`/usr/bin/perl`**
  (Apple-signed, `com.apple.perl`, which the gate admits) **once**, has it `DynaLoader`-load the
  dylib and enter `run_mediaremote_adapter_stream`, which never returns: it prints one JSON object
  per line (artwork as base64) as any session changes. Inside that entitled host it both
  observes MediaRemote's change notifications (the elected app's and the per-player ones) and
  re-reads on a timer (2 s while any session plays / 4 s otherwise), because the notifications
  are silent for some players. It emits only when the state actually moved —
  `elapsed`/`timestampEpoch` advance on every daemon re-sample, so they are compared against
  where the previous sample predicted playback would be, which detects a seek and ignores drift.
  It exits on stdin EOF, so it can never outlive the app. The Swift side respawns it with a
  widening backoff and, after 4 failures in 60 s, falls back permanently to the one-shot reader.
- **One-shot.** `Modules/Media/NowPlayingReader.swift` spawns the same helper per read and calls
  `run_mediaremote_adapter`, which prints a single JSON object and exits. Used for user-initiated
  refreshes (right after a transport command) and as the fallback poll. Each call costs a process
  spawn (~10 ms CPU), which is why it is not the steady-state path.
- **Transport commands** (play/pause/skip) are *not* gated and go direct via
  `Modules/Media/MediaRemoteBridge.swift`, addressed to the presented session's app: the bridge
  builds an `MRPlayerPath` for that app (a nil player addresses the app's own now-playing player)
  and sends through `MRNowPlayingRequest`. The untargeted `MRMediaRemoteSendCommand` reaches only
  the elected app, so it serves only a session that carries no app identity. The per-app surface
  is Objective-C classes, called through each method's implementation pointer cast to its exact
  C signature; the block-typed callbacks are `@convention(block)`, not `@convention(c)`.
- **Playback state read from this app's own process is wrong, not refused.**
  `MRNowPlayingRequest.requestPlaybackState…` returns "paused" with no error for a session the
  entitled helper reports as playing. Every read — state included — goes through the helper.

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
  cannot abort the entitled perl helper with an uncaught exception. It reads at most 8 sessions
  (of at most 32 listed clients), drops artwork over 3 MiB, and cuts each text field to 300
  UTF-16 units, which bounds a line to what `NowPlayingStream` buffers; the Swift parser applies
  the same session and text caps and drops a session whose app identity is malformed, since that
  identity addresses transport commands. `MediaArtworkDecoder` reads an image's pixel
  dimensions from its header, refuses one over 64 million pixels, and decodes the rest straight
  to a thumbnail, so a small file declaring a huge canvas is never decoded at full size.
- **Agent hook socket payloads** are arbitrary local input. Each connection is size-capped and
  defensively parsed, and a tty must match `\A/dev/ttys[0-9]+\z` before it is stored or reaches
  AppleScript interpolation. The text fields (`message`, `last_assistant_message`,
  `error_details`) carry model-generated prose that reaches a view: the hook truncates at the
  source, `FleetHookEvent.isValid` rejects a payload whose fields exceed the cap rather than
  trimming it, and `AgentFleetCenter.displayMessage` collapses whitespace and strips control
  characters — an ANSI escape or a newline in a summary would otherwise redraw a notch row.
  Registry `waitingFor` is bounded the same way in `ClaudeSessionMonitor`. None of this text is
  ever logged; `AppLog` records the reason's name only. A registry `hostSessionId` must match
  `\Alocal_[A-Za-z0-9-]{1,64}\z` and sit beside `entrypoint: "claude-desktop"` before
  `SessionLink` builds a URL from it, and `JumpTarget` drops a link whose app differs from the
  host that process ancestry resolved. **Anchor a validating pattern with `\A` and `\z`, never
  `^` and `$`**: they are the absolute ends of the input in every engine, whereas ICU's `$`
  (`NSString`, `NSRegularExpression`) also matches before a trailing line terminator. Swift's
  `String.range(of:options: .regularExpression)` rejects `"/dev/ttys004\n"` against
  `^/dev/ttys[0-9]+$` on the Swift 6.2 toolchain, so a test of that input passes with either
  anchoring there and proves nothing about the ICU path.
- **Screenshot-directory contents** are arbitrary local files. `ScreenshotMonitor` accepts only
  direct, regular, non-symlink image/PDF children that macOS marked as a capture — either
  macOS's `com.apple.metadata:kMDItemIsScreenCapture` attribute or, for images, the Exif
  `UserComment` of `Screenshot` that `screencapture` embeds in the file (read by ImageIO from
  the header, never decoding pixels) — requires a non-zero size, and rejects files over 512 MiB. It baselines existing paths before emitting anything. Vision OCR separately caps
  decoded dimensions at 120 million pixels before creating a recognition request. Before Move to
  Trash moves a staged file's original to Trash, `FileShelfStore` compares the current volume/file
  numbers with the identity recorded when the item entered the shelf; a replacement at the same
  path is refused.
- **Dropped-file agent dispatch** feeds untrusted file content to a model. `FileShelfStore` copies
  the file (via an `O_NOFOLLOW` descriptor whose volume/inode must match the staging identity) into
  a per-run scratch directory under Application Support, then runs the headless CLI with cwd = that
  scratch dir and `--tools Read --allowedTools Read(<copy path>) --strict-mcp-config
  --setting-sources project`. The toolset is Read-only (no exfiltration tool), the auto-allow is
  scoped to the single copied file, MCP is disabled, and the user's own hooks/settings do not load,
  so a prompt-injection payload in the file cannot read anything but the copy. The CLI starts as
  every agent process does (disclaimed, with a fixed environment; see the child-process bullet
  below). A natural-language preamble marks the content as data, not instructions, as
  defense-in-depth. The on-device path has no tools, so injected instructions in file content
  cannot act; the same preamble still marks the content as data.
- **The Claude sign-in and the usage endpoint** (`ClaudeUsageClient`). The credential JSON comes
  from the Keychain item Claude Code writes, or from `~/.claude/.credentials.json`, which anything
  running as the user can edit: it is size-capped, only `accessToken`/`expiresAt`/`scopes` are
  read, and the token must be printable ASCII with no whitespace before it reaches a header. The
  request goes through an ephemeral `URLSession` with no cache (the shared session's disk cache
  stores the request, `Authorization` header included, because the response carries no cache
  directive) and a delegate that refuses redirects, so the header can never follow one to
  another host. The response body is size-capped and parsed defensively; failure reasons are
  fixed strings and never carry the token.
- **ProVisor's agent reads mail from anyone, unattended**, so what it can do is bounded by the
  CLI's flags and never by its prompt (`ProVisorCommand`). Every run carries `--restricted` (no
  shell or web tools, file tools confined to the working directory, the user's settings and hooks
  ignored) and `--permission-prompts none` (anything not allowed is denied, not prompted), with
  `--tools Read,Write,Edit,Glob,Grep,ToolSearch`. **`ToolSearch` is load-bearing, not a
  convenience**: it is what makes the CLI defer connector tools and load a schema only when the
  agent looks one up. With it absent, every tool of every connector on the account rides in the
  first request (248,000 tokens for seven connectors, measured), the run ends on its spending
  limit after one turn, and the only symptom is "The agent reached its spending limit before
  finishing". It grants nothing: looking a tool up does not allow calling it. The **scout** is
  allowed writes only under `proposals/`, `memory/`, `followups/`, and `returned/`, where it
  marks a note read (`Edit(/proposals/**)` —
  a leading slash on a command-line rule anchors at the working directory, and `Edit` rules
  cover every file-writing tool) plus the **read** connector tools in `access.json`, so no
  connector tool it holds can send, change, or delete. **Tools that change mail go only to an
  acting run**, which exists only after the user approved one proposal or typed an instruction,
  or under a standing approval with its shorter list (next bullet). **The site, text, and photo-place tools**
  (`open_site`, `follow_link`, `read_more`,
  `read_texts`, `read_photo_places`; the bridge's rules join the connector rules in `--allowedTools` as
  `mcp__supervisor__<tool>`) **go only to passes that can change nothing outside the
  workspace**: the scout and the follow-up pass, never an acting or standing-approval run,
  which can write drafts the user may later send, into which a page or a text could steer
  account data or a position. A pass that holds them can cause a sign-in attempt on a granted site and
  whatever following a link on a signed-in site does, as bounded under "Signed-in sites"
  below. The bridge is attached only while all of these hold (`ProVisorBridge`): a site is
  granted, texts are on, or photo places are on; the scout's connector list is sealed; responsibility for the agent
  process can be disclaimed; and the installed CLI is the signed build (judged on the file
  before the run, remembered while its size, inode, and times hold, and judged again on the
  running process when the server accepts it as the run's root). A list is sealed when every
  rule is on `ProVisorAccess.sealedReadRules`, the tools known to read and nothing else.
  **Sealing is what keeps site, text, and photo-place reading from becoming a way to leak**: a
  connector tool that could send, invite, post, or fetch an address would carry what a page or
  a text says, or where the user has been, out of the Mac. That is why Notion's `notion-fetch`, which loads any address it is
  given, public pages anyone can publish included, is off the list. The list covers Gmail and
  Google Calendar by read pattern (`search_*`, `get_*`, `list_*`), and Microsoft 365, Slack,
  and Notion by exact tool name, because those connectors mix reading and writing under one
  prefix and a pattern would admit a tool added later. A pass that fails a condition runs
  without the tools, and Settings says which one failed (`ProVisorBridge.Unavailable`). A
  reviewed acting run may write under `followups/` and `raised/`
  (`ProVisorCommand.reviewedRunDirectories`): a note for a later pass, and an item to put to
  the user when something it checked is wrong or beyond its tools. **It is given no way to
  write in `proposals/`**: it holds acting tools and has been reading mail, and a rule
  covering that folder would let it overwrite any proposal, its own included, or write one
  claiming a standing approval. `RaisedItems.admit` copies what it left in `raised/` into the
  queue under an id the app makes up, keeping only the fields a proposal is written with
  (never `under`, `standing`, or anything the app writes) and never over an existing file, at
  most three per sweep. A follow-up is the agent's own note about a read-only check. Memory
  stays the scout's, and a run under a standing approval writes no files at all. The brief,
  `access.json`, `standing.json`, `sites.json`, and every run's tool-channel configuration (it
  holds the run's token) sit *outside* the working directory, where the agent's file tools
  cannot reach them. `access.json` accepts only connector rules
  under a literal server (`\Amcp__<server>__<tool or tool*>\z`), and one malformed rule rejects
  the file: it can never name a built-in tool, so it cannot grant a shell. **A proposal file is
  model output shaped by that mail**: `Proposal.parse` validates the id against
  `\A[a-z0-9][a-z0-9-]{0,63}\z`, caps the file at 32 KiB, strips control and format characters
  (a bidirectional override would let an action display as something other than what it says),
  and **rejects — never truncates — an action over 600 characters**, because the action is what
  an approval runs and text the user could not read in full is text they did not approve. A
  proposal offers one action or up to three named `options`; one unusable option, two options
  with one name, an option name over 24 characters, or a file carrying both `action` and
  `options` rejects the whole proposal. Approval is possible only in the review window, where
  the selected option's action is shown whole, and the acting run is instructed from the parsed
  copy captured at the tap, never re-read from the file the scout can rewrite. **That window
  stays open while scouting passes run, so the text under review is pinned when it opens**
  (`ProVisorReviewView`): a rewrite shows as a notice, the approving buttons go dead, and the
  new text appears only when the user asks for it. A view that followed the file would swap
  the words under a cursor already moving to **Do It**. A tap carries the proposal on file,
  and `ProposalReview.refusal` rejects it unless that copy still equals the one displayed, is
  still open, and has not expired. **The choice is written into the file before the run is
  queued, and an approval whose write fails runs nothing**: a run whose proposal could not be
  marked would leave it open in the queue to be approved and carried out again. For the same
  reason `Proposal.parse` re-encodes a file that can still be decided the way a decision
  rewrites it and refuses one that would leave no room for the decision
  (`decisionHeadroomBytes`); pretty-printing can more than double a compact file, so the
  size on disk says nothing about that. **A typed instruction runs the user's words in place
  of the options**, with the tool list an approved option gets; the run is given the title,
  the reasons, and the one suggestion that was on screen beside the text box as background
  marked as data, and never the options the user did not have in front of them. Typed text is
  cleaned by `Proposal.typedText`, which removes control characters and bidirectional
  overrides and keeps everything else as typed. The choice is written back (`chose`,
  `instructed`) for the scout to learn from and is read back **for display only**: a retry
  starts from the recommended option and an empty box, because a box pre-filled from a file
  the scout can rewrite would run the scout's words as the user's. The ideas banner carries a count only, a sign-in banner names only a site the rule under "A site the agent asks for" allows, and `AppLog` records names and counts —
  never proposal text or a failure's message, which can quote the agent's output, and never
  page text, message text, browsing history, a position or the date of a photo, or an address
  with a query string (a site is named by its host). Verify a change to the flags by running the CLI in a scratch directory and
  asking it to write outside the folders that run is allowed, read outside the directory, run a
  command, and call a connector tool that is not allowed: each must come back denied. For a
  pass that carries the bridge, the `bridge` and `tools` self-checks confirm a real run reaches
  a served tool.
- **A standing approval lets a ProVisor action run that nobody looked at first**, so a claim to
  be under one is worth only what the code grants it (`StandingApprovals`). A rule exists only
  because the user tapped **Always** beside its condition and action in full — an offer with
  either part missing or over 200 characters is dropped, never truncated — and the agent, which
  is told the rules in its prompt, cannot write the file they live in. A proposal's `under` counts only when it names a rule in force on
  a proposal still `proposed` and unexpired. The run gets its own tool list, `auto` in
  `access.json` (by default label, trash, and mark: a subset of the approved list, with nothing
  that sends or drafts and nothing that cannot be undone); an absent or empty `auto` switches
  standing approvals off. At most five run per scouting pass, and the rest wait for a tap. The
  run is also told the rule and the current weekday and local time, and to do nothing unless
  the condition holds and the action falls inside the rule, but that is the model's judgment
  and the tool list is the guarantee: the worst a hostile message can do through a
  standing approval is get some mail wrongly labelled or trashed, a handful at a time.
  **Whether the result is then shown is the run's own word** (`ActionReport`, under "A
  finished proposal" in ProVisor), which the same message can shape, so a row is no record of
  what a rule did: that is in the proposal files (`automatic`, `under`, `result`), and
  Settings lists every rule in force with a way to revoke it.
- **Signed-in sites: a secret goes only where the user watched it go** (`Services/Sites/`). One
  Keychain item per site (`SiteGrant`, in the login keychain addressed by path, since the
  default keychain is a user setting) holds the secrets and everything that decides where they
  may be used: the sign-in address, the hosts the password may be filled on, the hosts pages may
  load from, and the fills recorded while the user watched the app sign in (`SignInStep`: the
  kind, the origin and path, and the field's name, id, autocomplete token, and type).
  **`sites.json` is display and bookkeeping only** (name, last sign-in, attempt counters, a
  needs-you flag), because anything running as the user can edit a file, and an edited sign-in
  address would send the password there. A stored grant is used only when it is at most 16 KiB
  and valid for its site id (`SiteGrant.isValid`: `https` addresses with no credentials or
  port; hosts matched exactly, never as suffixes, since a suffix match on `co.uk` would cover
  every site under it; the sign-in host as the id; fill hosts within the browse hosts); an item
  that fails reads as absent. A write deletes the item and adds a fresh one, never updating in
  place, because an item planted under the same name keeps its own access list and would let
  its planter read the password; a failed add puts the earlier item back. Every type that holds
  a secret (`SiteGrant`, `TOTPKey`, the sign-in request, form, and session types) renders as a
  fixed placeholder in every textual form, `dump` included.
  **The broker replays the recorded fills and does nothing else** (`SignInBroker`). A value
  goes only into the recorded field on the recorded origin and path, and the check that the
  page is still that page, in a secure top frame, runs inside the same script call that fills,
  so a redirect between check and fill cannot slip through. Values reach the page only as
  arguments to a script in an isolated content world (the page's own scripts can still read a
  field once it is filled, as with any password manager). A form whose action is not an `https`
  fill host is not submitted, and one that would send by GET is submitted only if the page's own
  script takes the submission over, since sending it would put the password in the address.
  **A password field anywhere else is left alone**: a page that shows one no recorded step
  matches stops the sign-in with nothing filled. So do a visible challenge widget, a page whose
  fields differ from the recorded ones, a sign-in still showing after its fills, and one that
  needs more than six fills. How an attempt ended decides what follows. A person-needed stop
  (those, and a grant with no recorded steps) parks the site until the user signs in again; a
  transient one (a code that did not arrive, a page that moved or would not load) uses up an
  attempt and nothing more; an interrupted one (the task cancelled, or the browser closed under
  it) is taken back uncounted. A site gets three unattended attempts a local day, counted in
  `sites.json` *before* the sign-in starts so that one that cannot be recorded is never made,
  and one sign-in at a time across runs.
- **The Add Site form saves only a sign-in the app filled itself** (`SiteEnrollment`,
  `SiteFormModel`). The grant is built from the password handed to the sign-in, and `finish` refuses unless the app
  filled that password (`passwordNotFilled`) and the sign-in then left the password form with no
  later page asking for it again and no typing by the person into a password field in the page
  (`passwordNotConfirmed`; an isolated-world listener reports each trusted input event, never
  one the app dispatched, as the kind of field it hit, password or other, and never what was
  typed, in every window but the sign-in window described next). Either way it saves
  nothing, since it has no sign-in to replay or cannot tell which password worked, and the form
  asks for the working password. Save is open only while the form still shows exactly what the last Open Page or Sign
  In started with. The start page, browse hosts, and fill hosts are what the sign-in observed,
  never what the form says. **A sign-in started with a site's saved secrets fills the user name, the password, and the
  authenticator key only on the hosts recorded for that site**, into a form that sends to one
  of them; on any other host it stops (`unvettedHost`) and asks for it to be typed. The user
  name is held to those hosts too, since a fill on a page the sign-in was sent through would
  otherwise add that page's host to the refreshed grant's fill hosts. A texted or emailed code the
  site never asked for is saved as no code, and the window says so.
- **A password the person typed is kept only on their say, and only for the page it was typed
  on** (`TypedCredential`, `CredentialCapture`, `PasswordOffer`). The sign-in window can offer
  to keep the password typed into a site's own page, so the app can sign in again by itself.
  This is the one place a secret travels from a page into the app, and the one stored sign-in
  the app did not fill, so each step is bounded:
  - **Recording is on only in the sign-in window, only for an address something vouched for**
    (a granted site's saved address, or a host the browsing-history check recognised), and
    only while `provisor.offerPasswords` is on (`SiteBrowser.Observation.typingAndCredentials`,
    reached only through `SiteAccessCenter.makeRecordingEnrollment`). The Add Site form, a
    window that asks for a typed address, a window opened on a requested host the history
    does not know, and every hidden browser never record.
    The window says so before anything is typed.
  - **The script** runs in the app's isolated world, in the main frame only, and reports a
    trusted `input` event into a password field or a user-name field: the value, the field's
    name, id, autocomplete token, and type, and the page's own origin and path (the path a
    later fill is checked against; a frame's request address is stale after a `pushState`).
    A field that asks for a code, a PIN, a card code, or an answer is never reported, masked
    or not; an emptied field is reported as a clear, which drops what was held for it.
    **A trusted event is not proof a person typed**: a page's own script can produce one with
    an editing command. So a report is bound to the page's own origin and to nothing more,
    and the worst a page can do is spoil or prevent its own offer.
  - **`TypedCredential` exists only if the frame the app sees agrees**: main frame, `https`,
    no port, a valid host, the reported origin equal to that frame's security origin, bounded
    sizes. It, the capture, and the offer print as fixed placeholders, and only the code that
    builds the grant can read the password.
  - **No offer is made** (`OfferRefusal`, each with one fixed sentence) when the site asked
    for the password again; when password-like values were typed into more than one field or
    page without the form being left between them; on a change-password or sign-up form;
    when a sign-in code was asked for; when a field has no name, id, or autocomplete token to
    find it by; when anything was typed on a sign-in service whose password opens more than
    one site (`SignInServices`: Google, Microsoft, Apple, AWS, Okta-style tenants, and the
    like), whatever the site's family; or when anything was typed, or a form would send,
    outside the site's family or the hosts this sign-in traversed (`SiteFamily.sameSite`:
    equal hosts, a subdomain, or a shared registrable parent, judged without a public-suffix
    list, where a false "different" only loses the offer and shared-hosting parents never
    make two hosts one site). "Worked" means the person pressed Done on a page past the
    sign-in after typing it; a wrong offer costs one failed submission, after which the site
    waits for the person.
  - **Done saves the session first; keeping the password is a second save the person asks
    for** (`SiteEnrollment.passwordGrant`, built only on the session grant that was just
    saved). The kept grant's steps are the fields the person typed into, its fill hosts those
    pages and where their forms send, and its user name may be empty only when it has a
    password step and no user-name step (a site that remembers the user name). The offer is
    forgotten when the window closes, when Session Only is pressed, or after five minutes
    unanswered.
- **Signed-in sites: a run reads pages and follows offered links, and does nothing else**
  (`SiteAccess`, `ProVisorTools`). No tool types, presses a button, or takes an address:
  `open_site` names a granted site, `follow_link` a link by its number on the page the visit
  last read, `read_more` a part of that page. Links come from nowhere else, a visit follows at
  most `SiteAccess.linksPerVisit` (12), and following one is a `load` of its address, never a
  click on the page. Signing in happens only inside `open_site`, before the first page is
  returned; a page reached by a link never gets a fill. The navigation policy
  (`SiteNavigationPolicy`) loads a main frame only over `https` from a host in the site's
  browse list, matched exactly, with no port or credentials; a frame inside a page may load from
  any `https` host. A link is offered only if it passes that test and neither its text nor its
  address (path, query, and fragment, read as written and percent-decoded) holds a refused word
  whole — sign-out, delete, remove, cancel, deactivate, enroll, confirm, pay, transfer, send,
  unsubscribe, submit, redeem, apply, terminate, revoke, close account — so `payment-methods` is
  offered and `/pay` is not. The policy reads a link's text whole before it is cut for display,
  so a refused word past the cut still refuses the link. The list guards against
  state-changing links and guarantees nothing: a GET to the site's own hosts is still a GET,
  and a link another user posted on a granted site is offered like any other. New windows are
  refused, downloads and unrenderable responses cancelled, credential prompts declined, and a
  page's dialogs answered at once. Page text is cleaned and capped before a model sees it
  (`PageText`: control and format characters removed, so an ANSI escape or a bidirectional
  override cannot redraw a line; 400,000 characters kept and served in parts of 40,000; at most
  200 links, each text cut at 120). **A reply puts what the app wrote first and the page's own
  text last** (`ProVisorTools.pageReply`: the data-not-instruction line, site and title,
  address, the numbered links, then the text, which runs to the end of the message), so a page
  cannot imitate the list of links. Addresses are shown without their query or fragment, which
  can carry session data. A call from a run that has ended is refused before it touches a
  site, and a run that ends mid-call has its visit closed when the call returns.
- **A keep-signed-in grant holds a browser session and no secret.** The user signs in on the
  page themselves; the grant (`remembersPassword == false`) carries an empty user name and
  password, no key, no code source, no recorded steps, and only the sign-in host to fill on,
  and `SiteGrant.isValid` rejects one that carries more. **Save needs evidence of a
  sign-in, or the person's word** (`SiteEnrollment.finishKeepingSession`): a page with no
  password field reads as signed in to the probe, and a public home page has none, so the
  enrollment refuses (`signInNotSeen`) unless some page of it asked for a sign-in
  (`SignInRules.asksForSignIn`: a password field, a code field, a row of four or more
  single-character boxes, or a sign-in frame), the person typed into a password field, the
  page it saves shows a sign-out control, or a visitor with no cookies is shown to be signed
  out there (below). **The page is probed when a load finishes, at once each time
  the person types into it, and every 2 s while a session is being kept**, because a sign-in
  that moves from step to step inside one page finishes no load, a code field that submits on
  its last digit is gone before a page would settle, and a sign-in can end on a button press
  with no typing at all. A sign-in can still leave no evidence (a session an earlier window left in
  the data store, a passkey, a link opened from an email), so after that refusal the form
  offers **Save Anyway**, which saves on the person's confirmation
  (`SiteSaveProblem.confirmation`; the confirmation answers the one refusal on screen, so a
  save that would refuse for another reason shows that reason, and it is logged by the
  refusal's name). Such a grant holds no secret, and a mistaken one reads only what the site
  shows a visitor. **A lapsed session is noticed when the start page then asks for a
  sign-in, has moved, lacks a sign-out control the grant recorded, or shows a sign-in control
  the grant recorded as absent** (`SignInRules.isSignedIn`, `SiteGrant.signInControlAbsent`).
  A start page that is public to a visitor would give none of those, so **when the grant
  will record no sign-out control the save looks at the page as a visitor** (`VisitorCheck`:
  one load of the start page, without its query, on a fresh non-persistent store, held to the
  site's hosts, never shown, typed into, or filled, closed when its bound of 10 s passes;
  only a verdict leaves it). The visitor is signed out, which is evidence of a sign-in, when
  the same page asks them to sign in or shows a sign-in control the person's page lacks, or
  when the site sends them to a page that asks for a sign-in or a user name. **A challenge, a
  load taken off the site's hosts, and a redirect to any other page prove nothing**: a
  visitor with no cookies meets consent walls, locale redirects, and bot checks that have
  nothing to do with a session. A page the visitor sees identically is refused
  (`pageLooksPublic`) even after a sign-in was seen, since saved as a start page it could
  never show a lapse; the message asks for a page only the person can see, and Save Anyway
  stands. **The two controls are recorded only when a hidden read of the start page on the
  person's own store shows the same thing** (`HiddenRead`, `SiteEnrollment.markers`): later
  reads are fresh loads at the browser's default size, and a control a page tucks into a
  menu at one width would otherwise flag a healthy site on every visit. When the session
  ends the site needs the person: `SiteAccess` never signs in to such a grant and counts no
  attempt, and the sites window shows **Needs you** until the user signs in again.
- **A site the agent asks for is an offer, never a grant** (`Proposal.site`,
  `SiteSignInModel.Start.decide`). A `confirm` proposal may name the site that stands between
  the agent and a check in a `site` field, which `Proposal.parsedSite` accepts only as a plain
  ASCII host name, lowercased as ASCII alone (Unicode case mapping would turn a look-alike
  letter into a real one); a bad value drops the field and keeps the proposal. The text is
  model output shaped by mail from anyone, and a look-alike address placed in the app's own
  sign-in window would arrive with the app's authority. A request for a site (the review
  window's **Sign In to <host>…** button, which shows the host before the click, or a notch
  prompt) opens the sign-in window on `https://<host>`, and **the app vouches for that host
  only when the exact host is in the user's own browsing history on two different local
  days**, checked again as the window opens
  (`BrowsingHistory`: `https` pages on that host alone, across Chromium-family profiles and
  Safari; a parent, a subdomain, a port, or an `http` page counts for nothing, and days are
  counted, not visits, since one click can count twice). **A host the history does not know
  still opens, as unrecognised** (`Start.opensUnrecognisedPage`): the window's sentence turns
  to an orange caution that names the host for the user to check, nothing typed there is
  recorded, and no offer to keep a password is made. What stands between a look-alike host
  and the user's password in that window is the user reading the host, on the button, in the
  caution, and in the bar above the page. A value that is not a plain host name opens no
  page: the address field starts empty and a sentence names what was asked for. **Only a
  Keychain grant or that history check vouches for an address**: a granted site kept by its
  session opens its grant's saved sign-in address, one with a saved password opens there with
  the app filling it, and one whose
  grant cannot be read opens the Add Site form with an empty address, because the record's
  id and name come from `sites.json`, which anything running as the user can edit
  (`ProVisorSiteWindow.opening`). Saving settles the proposal as a **compare-and-set against the file on
  disk** (`ProposalStore.settleSiteRequest`): it is recorded done, with no run started, only
  while the file is still open and still names the site the window was opened for, and only
  that site settles it. The queue shows, and the banner announces, one open request per site,
  the earliest (`ProposalQueue.repeatedSiteRequests`). **A sign-in prompt in the notch, banner
  or sheet row, names only a granted site (by the user's own name for it) or a requested host
  that same history check recognises** (`SignInDemand.Item.isAnnounceable`). A requested host
  the history does not know is never a prompt: it stays an ordinary queue item counted among
  the new ideas, opened from its review window. A request is held out of both the prompts
  and the count until its lookup answers (`HostRecognition`, off the main actor, kept per
  local day), so it is announced once, as one or the other. Saving a site from any window
  settles the earliest open request that names it (`SignInDemand.effectOfSaving`).
- **Texts are read-only, bounded, and masked for a model** (`MessagesStore`). The database
  opens `SQLITE_OPEN_READONLY`, each call on a connection of its own that closes before the call
  returns (an open read transaction would pin the write-ahead log, and a fresh connection sees
  rows Messages has written there but not yet merged), with every value bound as a parameter and
  at most 2,000 rows scanned. A message's text is its `text` column, else the string in its
  `attributedBody` archive, read by a bounded extractor (`MessageBody`: an archive over 512 KiB
  or text over 20,000 bytes reads as absent, and every offset and length is checked against the
  buffer, never taken on trust). **A sign-in code is taken only from the sender recorded when
  the user granted the site, and only from rows after a baseline** taken before the code was
  requested (`latestCode(afterRowID:sender:)`; row ids order messages by arrival, so no clock
  decides). Enrollment alone takes the first code from any sender (`firstCode`), while the user
  watches, to learn whom the site texts from, and the window shows that handle for the user to
  confirm. **What a model sees has digit groups masked** (`messagesForModel`, the only read for
  showing texts to a model): in any message that may carry a code, meaning one from a short-code
  sender or holding a code-related word, every run of 3 to 8 digits becomes `••••`, and a
  `containing` filter matches the masked text, so a search for a guessed code finds nothing.
  **The `provisor.readTexts` setting, off by default, gates every read**: the tool, the code
  sources, and the baseline all consult it (`TextsSwitch` carries it to the code sources, which
  run off the main actor), and the bridge offers `read_texts` only while it is on. Reading needs
  Full Disk Access, and any failure to read is reported as that missing grant, the cause the user
  can fix.
- **Photo places are dates and coordinates, and nothing else from a photo** (`PhotoPlaces`,
  `PhotoTrail`). The library is read through PhotoKit, which needs the user's grant to Photos,
  the `com.apple.security.personal-information.photos-library` entitlement (the hardened
  runtime refuses PhotoKit without it, whatever the user answered), and
  `NSPhotoLibraryUsageDescription`. A read takes each photo's creation date and position from
  the user's own library — shared albums and hidden photos are left out, while what other
  people added to a shared library counts as the user's own — and never an image,
  file name, caption, album, or face, so **a reply holds no text anyone else wrote** and has
  nothing to clean; a position that is not finite, is off the globe, or is (0, 0) is dropped.
  The coordinates are the ones the photo recorded, unrounded, so a reply shows the user's home
  and every place they photograph to the metre. **That is why the tool is a third opt-in**
  (`provisor.readPhotoPlaces`, default off), consulted by the handler on every call as well as
  when the tools are offered, and why it goes only to the passes the site and text tools go
  to, behind the same sealed connector list. A reply is bounded by grouping, never by
  rounding: `PhotoTrail` joins photos taken one after another within a distance of the first
  into one line and picks the finest distance (50 m to 500 km) that fits the range into 400
  lines, dropping the oldest lines past that; one read looks at the newest 500,000 photos. **A
  line can run over days with no photo**, so it says how many of its days have one, and the
  reply and the protocol both say the days between prove nothing. The
  days a call names must parse as real `yyyy-MM-dd` days. The log gets the tool's name and
  outcome, and the `photos` self-check reports counts: neither carries a date or a position.
  The agent process is started disclaimed, so the app's grant to Photos never reaches it.
- **The bridge serves a run's tools only to that run's own helper** (`Services/AgentBridge/`).
  The CLI starts `SuperVisor --agent-bridge` as an MCP server over stdio from a per-run
  configuration file, and the helper relays each call over `agent-bridge.sock`. The server
  examines a caller in this order, and every refusal is a fixed sentence plus a log line naming
  the reason alone: (1) **the caller's process runs this app's own code** (its audit token,
  which names one process even if its pid is reused, satisfies the app's designated
  requirement), judged before anything the caller sends is read, so a program that is not the
  app learns nothing about tokens, versions, or runs; (2) the request is one well-formed line of
  at most 64 KiB, read within a second; (3) its token names a live run, compared against every
  registered token in constant time; (4) the helper's bundle version equals the app's, so a
  helper from a bundle Sparkle replaced mid-run is told to start a fresh run; (5) **the run's
  root process is the signed CLI** (`AgentExecutableTrust`: the CLI's bundle identifier, an
  Apple-anchored chain, and the vendor's team, judged on the running process once the app has
  started it and recorded with its start time; the CLI's path is writable by anything running
  as the user, so a replaced binary is never trusted), the server waiting up to 2 s for the app
  to record the pid, since the helper can connect first; (6) **the caller is a direct child of
  that root** (`maximumPeerDepth` 1), the root matched by start time as well as pid so a reused
  pid is not the root; (7) the caller's signature is judged again, because the parent walk went
  by pid and the second judgement shows the pid still belongs to the caller verified; (8) the
  tool is on the run's list. At most eight connections are served at once. **The helper
  verifies the app before it sends its token**, which it is handed in its environment and
  holds as its only secret. The helper runs before AppKit and the app's log exist, and **its
  standard output carries protocol lines and nothing else**. A helper started with no token
  (the shared `connector-hold.json`) offers no tools and never contacts the app; it only holds
  its first `initialize` answer back (see ProVisor). A debug build (`make-app.sh` without
  `--release`) honours `SUPERVISOR_BRIDGE_TRUST_ANY_SERVER=1`, which skips the helper's
  check on the server so a test runner can serve it; a release build has no such switch. After
  a CLI update re-run the `bridge` self-check: should the CLI ever start MCP servers through an
  intermediary, `helperDepth` exceeds `admittedDepth` and every call is refused with "SuperVisor
  refused this connection."
- **Child processes inherit nothing the app holds** (`Services/Process/`). macOS attributes a
  child's access to protected data to the app that started it, so **with Full Disk Access
  granted to the app, a child started the ordinary way reads the Messages database and one
  started with responsibility disclaimed cannot** (the `messages` self-check reports both
  cases, and `disclaimed-exec` the same for the `--exec-disclaimed` launcher). An agent reads
  mail from anyone, so every agent process, ProVisor's and FileShelf's alike, is started with
  responsibility disclaimed (`ProcessResponsibility`,
  the private `responsibility_spawnattrs_setdisclaim` reached by `dlsym`) and **is not started
  at all when that fails**: `AgentTaskService` throws `launchFailed` rather than run an agent
  that would answer for the app's grants. It inherits no descriptor beyond its three standard
  streams (`POSIX_SPAWN_CLOEXEC_DEFAULT`; the disclaim is applied after the spawn flags, at
  every spawn site). Every child the app starts, agent or helper, gets `ChildEnvironment`'s
  fixed short environment (a fixed `PATH`, and the account's name, home, and temporary folder
  from the system's record of the user), so a variable planted in the app's own environment,
  through `launchctl setenv` say, cannot steer what a child loads or runs. A third-party helper
  whose binary sits where anything running as the user can replace it (the Codex app-server) is
  started through `SuperVisor --exec-disclaimed <absolute path> args…` (`DisclaimedExec`),
  which replaces the app's executable with that program, disclaimed, with only the standard
  streams open; any failure ends it with status 127 and one fixed line on stderr.
- **A proposal handed to a Claude session leaves confinement, and only bounded text comes
  back** (`Handoff`, `HandoffFindings`). **Continue in Claude** in the review window opens the
  draft of a new session in the Claude desktop app, which the person directs with a real
  browser and which nothing in this app confines. **What keeps that session out of ProVisor's
  files is the desktop app's permission prompts alone**: it runs as the user.
  - **Outward.** Each handoff gets a folder made new under
    `~/Library/Application Support/SuperVisor/Handoffs/`, beside `ProVisor/` and never inside
    it, named by the local day and eight hex digits the app draws (`mkdir`, which fails on a
    name that exists). **A folder shared between handoffs would let a page that steered one
    session leave project instructions or hooks for every later one**, since the desktop app
    loads those from a session's folder and every folder above it. For the same reason a
    handoff is refused (`handoffFolder`) while `Handoffs/` holds anything but handoff folders,
    `.DS_Store` apart, or `SuperVisor/` above it holds `CLAUDE.md`, `CLAUDE.local.md`, or
    `.claude`. The folders further up (`Application Support`, `Library`, the home folder) are
    shared with every session the person runs and are not checked. The folder holds the app's
    fixed guide as `CLAUDE.md`, and `brief.md`: the title, the reasons, and the one action
    that was on screen, from the copy the tap carried, all under a heading the brief's
    opening marks as an assistant's account of mail. **The link's prompt holds no text a
    model wrote**, the proposal's id included, because it is sent in the person's name: it is
    the app's words, plus what the person typed in the review window's text box
    (`Proposal.typedText`). The link is `claude://code/new?q=…&folder=…`
    (`SessionLink.claudeDesktopNewSession`), opened only in the app with that bundle
    identifier, with every character outside the unreserved set percent-encoded: the app
    decodes the query as a form, where a bare `+` reads as a space. The app shows the prompt
    unsent and asks the person to trust the folder. The tap passes an approval's refusal
    first, and the folder, the ledger entry, and the proposal's `handedOff` stamp are written
    before the link opens; a link that fails to open takes the stamp off again. A failed open
    is logged by the error's domain and code, since its description can quote the link.
  - **Back.** `findings.md` is read only from a folder in the app's own ledger
    (`ProVisor/handoffs.json`, `HandoffLedger`, which neither the workspace nor a session's
    folder holds, read at start and held in memory by the center). **The ledger, never the
    proposal's `handedOff` stamp, says what was handed off**: the scout can rewrite a
    proposal's file, so the stamp serves only the agent and the review window's caption. A
    folder is read within 14 days of its handoff, once the file has gone 60 s unchanged.
    **The app may hold Full Disk Access, so the read follows no link**: the folder and the
    file are each opened by name relative to the folder above with `O_NOFOLLOW`, and a file
    with a second hard link is refused. At most 32 KiB is read and 8,000 characters kept, cut with a
    line the app writes; control and format characters are removed and line breaks kept. The
    note lands in `workspace/returned/` as a new file each time (`<proposal id>.md`, then
    `<proposal id>-2.md`), never over one a pass has marked read, with the app's lines first
    (`Status: new`, `Returned:`, `Item:`, and a sentence ranking it with mail from a stranger)
    and the session's text last. The fingerprint of a findings file is recorded only once its
    note is written, so a write that fails is tried again a minute later. A proposal's notes
    take at most 50 names.
  - **What comes back ranks with mail.** The protocol has a pass keep what matters in
    `memory/` under a `(returned <id>, <day>)` mark, never count it as one of the person's
    decisions when weighing a standing approval, never take a `site` from it, and then set
    the note's first line to `Status: read`. That is the model's judgment. The guarantee is
    that a returned note buys what hostile mail already could: a proposal the person reviews,
    or a sign-in request the browsing-history check judges. A proposal the ledger names is
    never admitted under a standing approval (`admitStandingActions`), and a reviewed acting
    run can read `returned/` as it can read mail.
- **An emailed sign-in code is read by a run that can read mail and nothing else**
  (`EmailedCodeLookup`, `ProVisorCommand.emailedCodeArguments`). The run holds the CLI's
  small-model alias, `--tools ToolSearch` (no file tools), only the Gmail read rules found on
  the sealed list, and no bridge; it works in an empty folder of its own, within six turns and
  $0.15, and answers with digits or `NONE`. **Only a whole answer of 4 to 8 digits is a
  code**, so whatever an email tells the run, the most it can do is choose which digits are
  typed into the code field recorded for that site, where a wrong code fails the sign-in and
  parks the site until the user signs in again; nothing else it says is used. An answer of
  `NONE` waits 20 s and asks once more. The sender in the prompt is the one recorded at grant
  time and must match `\A[A-Za-z0-9+@._-]{2,80}\z` before it is interpolated. The lookup sits
  outside the acting queue, so a pass waiting on a sign-in cannot deadlock behind it, and it
  is the center's own: **while ProVisor is disabled a sign-in that asks for an emailed code
  gets none**.

## Module Roster

Each lives self-contained in `Modules/<Name>/` (model + system observers + SwiftUI views).
Modules that surface a **generic capability** carry a **`<Feature>Visor`** brand name in their
`displayName` (MusicVisor, TaskVisor) — propose one in that style for any new module.
Name a module literally only when its point is *whose* data it shows rather than *what* it does
(AI Usage), or when the plain noun already is the feature (Calendar, Battery, FileShelf). The folder
names below are the code paths.

- **Media → "MusicVisor"** (`Modules/Media`) — system now-playing surface. Compact: album-art
  thumbnail + a six-thin-bar equalizer **tinted with the artwork's dominant color**
  (`MediaArtworkColor`, computed once per track). While a track plays, the bars are a **real FFT
  spectrum of the actual system audio** (`SpectrumBarsView`, fed by the system-audio tap in
  `Services/Audio/`); when the tap is off, denied, or rebuilding they fall back to the
  synthesized bounce (`AudioBarsView`) in the same footprint. The tap runs only while the
  session is playing **and** `LocalAudioOutputMonitor` reports some other process running
  audio output (a player casting to another device reports playing while the tap would hear
  only silence); an unknown answer falls back to the playing flag. `SpectrumTapIntent` and
  `SpectrumTapAction` are the pure decisions behind `MediaModule.reconcileSpectrumTap`, and
  inside the tap `SilentRebuildBackoff` paces the rebuilds a silent stream can still trigger.
  A **beat aura**
  (`UI/BeatAuraView`, layered behind the morphing surface in `NotchRootView`) glows around the
  notch in the artwork color, following the music's bass envelope. Both are toggleable in
  Settings (`media.trueSpectrum`, `media.beatAura`). Expanded: large artwork, title/artist, a live
  scrubber, and a transport row flanked by a **sessions button** (leading, shown only while more
  than one app holds a session) and the **audio-output device switcher** (trailing). Each hands
  the whole sheet to its list as a takeover (`SheetTakeoverCenter`): the session list
  (`MediaSessionList`) shows every app's session with its own play/pause, and tapping a row pins
  that session as the presented one. Every app's session streams from one long-lived perl
  adapter (`NowPlayingStream`), which pushes only when something changes; the module presents the
  one `NowPlayingSelection` picks and sends commands to that session's app via
  `MediaRemoteBridge`. While `calls.autoPauseMusic` is on, a detected call pauses the presented
  session and resumes it only when the automatic pause claim still owns that same paused session
  — the claim follows the session it paused, whichever one is presented by then.
- **Calendar** (`Modules/Calendar`) — next-meeting countdown chip in compact; an agenda with a
  one-tap **Join** button (Zoom / Meet / Teams / Webex link detection) in expanded. EventKit via
  `CalendarService`. **Meeting Mode:** while a meeting with a join link is in progress, Calendar
  contributes no compact mic indicator because macOS already shows microphone activity in the
  menu bar; the sheet leads with a call HUD — the meeting rendered in the agenda's row style
  (calendar-accent dot, green elapsed/ends-in line) above a system-wide **mic-mute** toggle
  (`MicController`), an audio-output switcher (a sheet takeover, as in the media section), and Join. The agenda carries no header, so the
  in-progress row and upcoming meetings read as one list. A mute applied via the notch is
  auto-restored when the meeting ends. CallSense also raises Meeting Mode for ad-hoc calls from
  the public CoreMediaIO/CoreAudio "running somewhere" camera and microphone properties, with a
  3-second start debounce, a 5-second end debounce, and the spectrum tap's aggregate/virtual
  devices excluded. The ad-hoc HUD says **On a call** and omits the event title, Join, and dismiss;
  a scheduled meeting wins when both signals apply, and mic auto-restore covers either call type.
  Any surfaced meeting can be dismissed from its agenda row or Meeting HUD; the occurrence is
  excluded everywhere. Dismissals live in memory in
  `MeetingDismissalStore` (`Services/Meetings/`), keyed by event ID plus start time and pruned when
  the meeting ends; an **N dismissed** agenda footer lists them for one-tap restore and keeps the
  section visible when every meeting is dismissed. The agenda shows three upcoming meetings and
  folds the rest behind an **N later** footer that opens them in the same row style. A call in
  progress — scheduled or ad-hoc — raises `SectionUrgencyCenter`, floating the HUD above the other
  sections, since the mic toggle and Join are what the sheet is being opened for. It still sits
  below the pinned media section.
- **Reminders → "TaskVisor"** (`Modules/Reminders`) — due-today + overdue Apple Reminders. Compact:
  a checklist count badge (red when any are overdue). Expanded: a **tap-to-complete** checklist
  with list color, live due/overdue text, and a high-priority marker. EventKit via
  `RemindersService`.
- **FileShelf** (`Modules/FileShelf`) — one unified staging inbox for both dropped files and
  screenshots (named literally, not a `<Feature>Visor` brand). Each `StagedFile` carries a
  `source` (`.dropped` / `.screenshot` / `.generated`) that drives a corner badge on its tile.
  Dropping a file onto the notch opens the sheet and stages it; `ScreenshotMonitor` (moved into
  this module) recognizes new macOS screenshots through the system
  `com.apple.metadata:kMDItemIsScreenCapture` extended attribute or the Exif `UserComment`
  `screencapture` embeds in the image (never by localized/user-defined filenames), watching
  both the destination directory and
  `~/Library/Preferences/com.apple.screencapture.plist` — a destination change reconfigures the
  watcher live, and existing files are baselined on activation/reconfiguration. A new screenshot
  animates into the pill with a 3.2-second peek, then its arrival flourish collapses into the
  persistent count badge. Screenshots evict oldest-first past eight; dropped and generated items
  are never auto-evicted. Expanded: a **detached side card** floating `sideCardGap` off the
  sheet's trailing edge at the sheet's height (floored at `sideCardMinHeight` so a short sheet
  cannot crush the drop zone), in the sheet's material. The card fades in with a short drift
  from the sheet's edge, only after the open spring settles; a close is **two-phase**
  (`NotchEngine.isSideCardRetracting`): the card fades back out, then the engine completes the
  collapse. The card holds a vertical rail of tiles and an
  icon action panel whose rows each split the card's full width — Copy, Copy Text (Vision OCR,
  images/PDF; runs detached, only the resulting `String` returns to the main actor), and
  AirDrop — plus, separated, **Remove** (off-shelf, non-destructive; a generated artifact's
  backing file is deleted) and **Move to Trash** (moves the original to the macOS Trash after
  verifying the file's recorded volume/inode identity, refusing a file swapped at the path).
  Quick Look, Reveal, Zip, and the **agent verbs** (Summarize / Explain / Extract Text) are on
  each tile's context menu only; double-clicking a tile also opens Quick Look. The shelf contributes no `expandedSection()`; the engine
  reads the card through a concrete `FileShelfModule.sideCard()`, and the expanded hit-test and
  hover rects extend over the card while it shows.
  Agent verbs route to the on-device system language model when a file has a small plain-text or OCR
  representation; verbatim OCR satisfies Extract Text directly. The sandboxed headless CLI remains
  the path for large or binary content, an unavailable system model, and on-device failures (see
  Untrusted Input). Drag-out, Quick Look, and thumbnails via `FileShelfStore`, `ThumbnailService`,
  `QuickLookController`, `FileActionService`; agent runner + live-operation model in
  `Services/AgentDispatch` and `Services/Operations`.
- **Swarm → "SwarmVisor"** (`Modules/Swarm`) — quiet-until-blocked triage for concurrent Claude
  Code sessions. The recursive session-registry watcher is the sole truth for live
  busy/idle/waiting state; hook-socket events provide only low-latency refreshes, validated tty
  metadata, and the text of a finished or failed turn, so delayed or out-of-order hook delivery
  can never roll session state backward.
  **Why a session is blocked** comes from `AttentionReason`, ranked so a specific reason is never
  replaced by a vaguer one for the same session: `.failed` (a `StopFailure` error — `rate_limit`,
  `billing_error`, `authentication_failed`) › `.waiting` (the registry's own `waitingFor` phrase:
  `approve <Tool>`, `worker request`, `sandbox request`, `dialog open`, `input needed`) ›
  `.asked` (the final assistant message ends in `?`) › `.finished` (turn length plus that
  message) › `.needsInput`. That ranking is load-bearing: the `idle_prompt` notification fires a
  minute after a turn ends carrying a *fixed* sentence, so without it the generic reason would
  overwrite what the session actually said — and reset the row's age with it. `.needsInput`
  carries no text for the same reason. A busy → idle transition enters triage only after a ≥45 s
  turn; `idle_prompt` enters regardless of turn length, and a session blocked on a prompt
  (`waiting`) enters immediately however short the turn, because it cannot proceed at all.
  **A `dialog open` wait is the one reason that never interrupts** (`AttentionReason.interrupts`):
  the user opened that dialog in that terminal, so it is already on their screen. It joins the
  sheet queue silently — no glow, no toast — counts as calm rather than blocking (so it neither
  floats the section nor outranks a real block, and folds into **N idle** like any quiet entry),
  and ⌘⇧⎋ skips it. Becoming a genuine block later announces then, since by that point it is news.
  Attention stays quiet: a newly added entry raises a rotating brand-gradient glow around the
  notch, joins the flat sheet queue, and announces itself through the peek banner (Claude mark,
  session name, reason, one-tap Jump) — below the notch on a cutout screen, inline in the pill on
  a flat one. The toast lives exactly as long as SwarmVisor's claim on the glow: it holds until the
  user opens the sheet (which ends every module's claim) or jumps to the terminal (which ends
  SwarmVisor's alone) or the session leaves the queue, and that claim ending is the module's
  only signal that the user looked. There is no other pill
  presence and no attention count. Only a genuinely new session PID announces — an entry
  rewritten in place (a late tty, refreshed metadata) updates the toast where it stands.
  SwarmVisor's `order` of 15 puts its toast ahead of ProVisor's banner when both want the
  banner. Opening the sheet or emptying the queue clears the glow, and an
  already-seen nonempty queue stays quiet until another entry is added. Queue rows (Claude-mark
  led) put blocked sessions first, then most-recent (session PID settling a tie so a retick never
  reshuffles them), and live until the session resumes or the user dismisses them. A session that
  merely stopped folds into an **N idle** disclosure once it is an hour old
  (`SwarmQueuePresentation.idleFoldAge`) — inside that hour its closing summary is still what the
  user stepped away from, past it the row is history competing for sheet height. A blocked session
  never folds however long it has waited, and any blocked session raises `SectionUrgencyCenter`, so
  the queue leads every section but the pinned media one. Sessions mid-turn fold behind an
  **N working** disclosure (`AgentFleetCenter.workingSessions`, most recently started first);
  opened, each row shows the session, its folder, how long the turn has run, and Jump — no
  dismiss, since the row leaves on its own when the turn ends. Its badge is the brand gradient
  and pulses (a ring swelling out and fading, still under Reduce Motion), the marker's one live
  state; a badge is orange for every state that is the user's move (approve, asked, needs
  input), green for a finished turn, red for a failed one. A validated tty teleports directly to the matching iTerm2 tab through
  AppleScript, from the row, the banner, or **⌘⇧⎋** without the sheet open (`swarm.jumpHotKey`,
  default on). A session hosted anywhere else — the Claude desktop app (which runs the CLI under
  a pty of its own, so a tty alone does not mean iTerm2), an editor's terminal, Terminal.app — is
  reached through `SessionHost`: the session PID's parents are walked (`ProcessAncestry`, over
  `sysctl`) to the first regular app, resolved once per session, and Jump brings that app forward through
  `NSWorkspace.openApplication` (an accessory app cannot satisfy `activate`'s cooperative
  activation). That focuses the app, not the specific conversation inside it — except in the
  Claude desktop app, which Jump opens on the session itself: a desktop session's registry record
  carries `entrypoint: "claude-desktop"` and a `hostSessionId` (`local_…`), and the app's URL
  handler navigates to that session for `claude://code/continue?session=<id>` (`SessionLink`).
  The link is opened only in the app with the link's bundle identifier — the running host, else
  another running or installed copy — never through the scheme's registered handler, and a link
  whose app differs from the resolved host is dropped. The desktop app ignores the link when its
  deep links are disabled. The shortcut goes to the session the banner is announcing, else the queue's first;
  entries with no tty, host app, or session link, or on their own dialog, are skipped, and it is claimed only while some
  session is reachable, so the
  rest of the time ⌘⇧⎋ belongs to the frontmost app. `swarm.showMessages` (**default off**) gates session *content* — the question, the
  closing summary, an error's detail text, each truncated to one line with the whole of it on
  hover; labels, tool names, and error codes are fixed vocabulary and always show. The sheet
  floats above every window, so content is opt-in rather than on by default.
  **The hooks are the app's own** (`Services/AgentFleet/AgentHookInstaller.swift`,
  `Resources/supervisor-agent-hook.py`, installed from Settings › SwarmVisor). The installer
  copies the script to `~/.claude/hooks/` and merges entries into `~/.claude/settings.json`,
  preserving every unrelated key and every other tool's hooks, backing the file up once to
  `settings.json.pre-supervisor.bak`, and evicting any entry left by ClaudeIsland (a separate
  app this signal was once borrowed from). Six events are wired —
  `UserPromptSubmit`, `Notification`, `Stop`, `StopFailure`, `SessionStart`, `SessionEnd`.
  Per-tool events are deliberately absent (they would spawn a process per tool call to report
  what the registry already publishes), and so is `PermissionRequest`: its only possible answer
  is the pass-through that not wiring it produces, at no latency and with no risk of stalling a
  prompt. The socket still replies `{"decision":"ask"}` to any `waiting_for_approval` message,
  since it is reachable by any local client. Without hooks the module still lists sessions and
  tracks state from the registry; it loses iTerm2 tab selection, turn text, and failure reasons.
- **Battery** (`Modules/Battery`) — power/charging status, time remaining, and connected-device
  (Bluetooth accessory) battery; peeks on plug/unplug and low battery. (`PowerSourceMonitor`,
  `BluetoothMonitor`.)
- **Usage → "AI Usage"** (`Modules/Usage`) — Claude Code and Codex plan-quota runway as two
  tightly-stacked ticker rows at the bottom of the sheet (`CLAUDE 5h 62% · 7d 34% ↻ 4:30 PM`,
  colored by headroom: green < 70 %, amber < 90 %, red past it; chrome shared in
  `UI/UsageTickerRowView`). No compact/pill presence. One module (`AIUsageModule`) owns both
  monitors; each row gates on its own product's activity, and the section exists only while at
  least one row does.
  - **Claude row:** `QuotaMonitor` takes **activity from Claude Code's session registry**
    (`~/.claude/sessions`, through its own `ClaudeSessionMonitor`), which every host writes —
    a terminal, the desktop app, an editor's terminal. Claude Code counts as in use while any
    live session is mid-turn or changed status within 10 min. **Quota comes from
    `ClaudeUsageClient`**, which reads the account's windows from the same
    `/api/oauth/usage` endpoint Claude Code's `/usage` command reads, authenticated with the
    OAuth token Claude Code keeps in the login Keychain (`Claude Code-credentials`, read via
    `/usr/bin/security`, the tool Claude Code stores it with, so the item's access list admits
    the read without a prompt; `~/.claude/.credentials.json` is the fallback store). Only the
    access token, its expiry, and its scopes are read — the refresh token is never touched,
    since using it would rotate the tokens out from under Claude Code — and the token is never
    logged. Reads happen while active: on becoming active, after each registry change no more
    than once a minute, and 5 min after each successful read through a long turn; a failed read
    retries with exponential backoff (1 min doubling to 15 min, which registry-change reads
    honor too), logged once per distinct reason. **The statusline capture file**
    (`~/.claude/agentpace/last-status.json`, which the user's statusline wrapper rewrites with
    the statusline's stdin JSON on every refresh; its `rate_limits` object carries
    `used_percentage`/`resets_at` per window) is watched and **applies only while the endpoint
    is not producing** — its last read failed (a sign-in without the `user:profile` scope, an
    expired token, no network) or it has no snapshot within the quota TTL — and then only when
    newer than what is shown. While the endpoint answers the capture is ignored: a statusline
    re-render carries the numbers of that session's last API response, so a newer file can hold
    older numbers. **Only an interactive terminal session renders a statusline**: the desktop
    app runs the CLI headless (`--output-format stream-json`), so the capture alone never sees
    desktop use. Limits: the registry monitor admits only `kind: interactive` records (which
    desktop sessions are; background `bg` jobs are not activity), and a non-default
    `CLAUDE_CONFIG_DIR` (which moves the registry and suffixes the Keychain service name) is
    not followed. The row exists only while active **and** quota data is recent (30 min TTL).
    Freshness is wall-clock-derived, so when Claude Code stops, no registry or file event will
    ever arrive: a **single timer** is armed for the soonest deadline that can still hide the
    row (and none at all once it is hidden), rather than a periodic tick that exists only to
    notice the absence of one.
  - **GPT row:** `CodexQuotaMonitor` uses a recursive FSEvents watcher over
    `~/.codex/sessions/` and reads only JSONL mtimes to determine whether Codex is active; it
    never opens transcript contents or auth files, and sessions crossing midnight or resumed
    from older date folders remain visible. While active, `CodexRateLimitClient` launches the
    installed `codex app-server`, performs its initialize handshake, and reads the supported
    `account/rateLimits/read` snapshot. Codex itself owns authentication and network access.
    The helper is reused across activity updates, throttled to one request per 5 seconds, and
    stopped when the same 10-minute activity window expires. Quota freshness uses the same
    30-minute TTL.

- **ProVisor** (`Modules/ProVisor`) — a background agent that reads the user's own data and
  proposes things they would want done but have not thought to ask for (an unused subscription
  still billing, a question nobody answered, senders never opened). **Off until enabled**
  (`SettingsStore.optInModules`): it reads mail and spends Claude quota. Reading texts is a
  second, separate opt-in (`provisor.readTexts`, default off), and reading where photos were
  taken a third (`provisor.readPhotoPlaces`, default off). **The app's part is
  deliberately thin; the judgment lives with the agent.** `ProVisorCenter` (a singleton, because
  Settings needs the live state and the registry builds a second, never-activated module set
  just to list names) starts a headless Claude Code run through
  `AgentTaskService.run(arguments:workingDirectory:timeout:)`, shows the proposal files that
  run writes, and on the user's tap starts a second run to carry one out. There are no
  collectors, no typed action catalog, and no domain logic in Swift. **Keep things flexible
  and let the agent manage things in markdown files.** New state ProVisor needs (a tally, a
  list, a schedule, a preference) is a note the agent keeps under `memory/` or `followups/`,
  described in the protocol or the charter. Swift is for what the agent cannot do itself or
  must not be trusted with: confinement, secrets and sign-in, validating what it writes, and
  telling it about things outside its view.
  - **The agent's home** is `~/Library/Application Support/SuperVisor/ProVisor/`: `CHARTER.md`
    (its standing brief, seeded once from `Resources/provisor-charter.md` and then the user's to
    edit), `access.json` (which connector tools each kind of run may call), `standing.json`
    (the standing approvals), `sites.json` (the granted sites as the sites window lists them; their
    secrets and the hosts those may go to are in the Keychain), `runs/` (one tool-channel
    configuration per run that carries the bridge, holding that run's token, deleted when the
    run ends and swept at launch if a crash left one, beside the shared token-free
    `connector-hold.json`), `handoffs.json` (the handoffs the app made, below), and
    `workspace/` — the run's working directory — holding
    `proposals/` (one JSON file each), `memory/` (the agent's own notes: what it has learned
    about the user, what it has already examined), `followups/` (checks owed after a decision,
    one short note each), `raised/` (items a reviewed run wants put to the user, which the
    app admits into `proposals/` itself), and `returned/` (what a handed-off session found,
    which the app admits). Each run starts with no recollection, so those notes
    and the statuses on past proposals are all it knows. Handed-off sessions work in
    `SuperVisor/Handoffs/`, beside this folder.
  - **The agent does the checking, and the user hears only when a check goes wrong.** A run
    never hands the user something it could look up (`ProVisorCommand.closingInstructions`,
    and "Do the checking yourself" in the protocol). What a reviewed run cannot confirm yet —
    a receipt that has not arrived — it writes to `followups/<proposal id>.md`; a follow-up
    pass (below) and each scouting pass re-check the open ones and settle them silently when
    they pass. One that turns out wrong, or that the agent's tools cannot reach at all, is
    raised at once as a new proposal of kind `confirm`, whose `why` names the access that would
    let the agent check it itself: a connector tool to allow in `access.json`, or a site that
    needs the user's sign-in, named in the proposal's `site` field (see Untrusted Input). The
    scout writes that proposal itself; a reviewed run leaves it in `raised/` for
    `RaisedItems.admit`. **The fact a possible proposal turns on is a check too**: a scout
    whose lead stops at a site it has not been given (a balance a statement mail only links
    to) asks for that site and keeps a follow-up note waiting on it, and treats a lead its
    watchlist set aside at a site the same way. A follow-up note is free text the agent writes for itself; the app
    reads only its first two lines (below) and acts on nothing in it.
  - **The brief is two documents with two owners**, joined and passed as
    `--append-system-prompt`. `CHARTER.md` is the user's: what to look for and what is worth
    proposing. `Resources/provisor-protocol.md` is the app's, read from the bundle on every run
    and never seeded: the proposal file format, how standing approvals work, the agent's
    limits. **How a pass spends itself is charter text**: checking what is new since
    the last pass is the small part, and then it explores one area from the map it keeps in
    `memory/coverage.md` (a source cut into a slice, with a look-again date), so passes neither
    stop at the latest mail nor re-read what an earlier pass read. The user's direction goes
    under the charter's "Notes from me", which outranks its defaults. **A field the app parses is described in the protocol, never the charter** — a
    seeded charter is not updated when the app is, so a format described there would go stale
    against the parser in every existing install. **An edit to either document reaches a pass's
    plan only because the pass is told of it** (`BriefRevision`): the agent plans from its own
    notes, and a note holds a conclusion ("recheck Dec 1") without the rule that produced it,
    so a pass given a changed brief and nothing else repeats what its notes scheduled. A
    scouting pass whose brief differs from the one its last finished pass ran with
    (`provisor.briefDigest`) is told to re-read it and reopen what its notes set aside. To see
    what a wording change does before shipping it, run the CLI with `--tools ""`, the brief as
    `--append-system-prompt`, and the three memory files pasted into the prompt, and ask for
    the steps it would take.
  - **Data comes from the claude.ai connectors** Claude Code exposes locally
    (`mcp__claude_ai_<Server>__<tool>`); the default `access.json` reads Gmail and Google
    Calendar. Connectors load only for a Claude-account sign-in, not an API key. The connector
    names in the defaults follow the documented naming but vary by account — the agent's notes
    under `memory/` say when a data tool it expected was missing.
  - **Sites, texts, and photo places are three more sources, read through the bridge** by a
    scouting pass and a follow-up pass (Untrusted Input says what bounds them). `open_site`,
    `follow_link`, and `read_more` read pages of a granted site signed in as the user;
    `read_texts` reads recent texts; `read_photo_places` reads when and where the photos in
    their Photos library were taken, for any range of days. **It knows only the moments a
    photo was taken**: a day with no photo has no line, and a photo someone else took and the
    user saved shows where that person was; the reply and the protocol both say so. A pass is
    told which sites it can read and whether texts and photo places are on, and the protocol's
    "Sites, texts, and photo places" section says how to use them. The tools are offered only while every
    condition under Untrusted Input holds; otherwise the pass runs without them. **A headless
    run's first turn starts before the account's connectors have connected**, so a quick run
    has no mail tool on it. Measured with the real CLI, the first turn had no Gmail tool in 4
    of 4 runs with no tool server, and in 2 of 3 with one that answered `initialize` at once,
    and had it in 3 of 3 with one that answered after 4 seconds. **Every ProVisor run therefore
    carries the bridge helper, which holds its first answer for
    `ProVisorBridge.connectorSettle` (6 s)**, as its own server or, for a run with no tools,
    as the shared token-free configuration; the `connectors` self-check re-measures it. Without
    the hold a pass reports a mail tool missing that was seconds from connecting.
  - **A follow-up pass** works through the notes in `followups/`. A note's first line is
    `Status: open`, its second `Check from: yyyy-MM-dd`, the first local day the check can
    be made, and its third, when the check waits on a site, `Waits on: <host>`; the app reads
    only those lines, from a regular, non-symlink `*.md` file of at most 64 KiB, and a missing
    or unreadable date leaves the note due (`FollowUpNotes`). **A note that waits on a site is
    due only while that site can be read** (granted, not flagged, not turned away): a pass
    started for it would be turned away at once, up to six times a day, with nothing changed
    until the person signs in. A pass is owed when a note is open and due, while a note in
    `returned/` is new (`ReturnedNotes`, under "Continue in Claude" below), or once after the
    user signed in to a site that was in demand (below), so the check that waited on it is
    made with it (`FollowUpDemand`). A note-driven pass starts a minute after it is owed, at
    least ten minutes after the last start, and at most six a local day; **a pass owed by a
    sign-in starts 5 s after the save, skips that gap, has its own allowance of six a day, and
    is told which sites the person just signed in to** (`FollowUpSchedule.chargeToStart`; the
    ledgers are in `UserDefaults`). The told sites and the charge are consumed only once the
    pass has launched, so one that fails to start stays owed. It waits while a scouting pass or another follow-up pass runs, is dropped
    on sleep and re-armed on wake like the scouting timer, carries the scout's confinement and
    bridge with a smaller allowance (30 turns, $0.75, 10 minutes), looks for nothing beyond the
    owed checks, and leaves the scouting status in Settings alone. Proposals it writes are
    admitted and announced like a scout's, and **a standing approval admitted from one draws on
    the scouting pass's allowance of five**: only a scouting pass resets that count
    (`automaticRunsThisPass`).
  - **A scouting pass** runs every `provisor.scoutHours` (0 = only when asked, 1, 3, 6 default,
    24) or from **Look Now** in Settings. One sleeping task waits for the next pass; it is dropped
    on system sleep and re-armed on wake, never fires sooner than 45 s after launch or wake, and
    backs off 15 min after a failed pass (`ProVisorSchedule`). A pass is capped at 80 turns, $5,
    and 20 minutes; one cut off by a limit keeps the proposals it had already written.
  - **A proposal** is `title` / `why` / `action` / `kind` / `created` / optional `expires`,
    written by the agent; in place of `action` it may carry `options`, one to three
    `{label, action}` pairs with the recommended one first. The app writes `status`
    (`proposed` → `done` / `failed` / `dismissed`; the agent may set `withdrawn`), `decided`,
    `result`, `cleared`, and the choice (`chose`, an option counted from one, or `instructed`,
    the text the user typed) back into the same file, which is how the agent learns what the
    user wants. Expanded: rows for proposals awaiting a decision, then those carried out whose
    result the person still needs to see (next bullet), three unprompted and the rest behind
    **N more**. A row opens the **review
    window** (`ProVisorReviewWindow`) or dismisses; it cannot approve. The review is an
    ordinary window because deciding can involve typing and the notch panel never takes
    keyboard focus; opening it closes the sheet. **The window sizes itself to its content
    (`FittedWindow`) and its hosting controller carries no sizing options**: with
    `.standardBounds`, AppKit resizes the window from inside its layout pass, the hosting view
    asks for another constraints pass, and the excess is an uncaught `NSGenericException` that
    kills the app when the content changes height. No test reproduces it, so after touching
    the window's sizing, open a proposal in the running app and switch between an option and
    **Something else…** several times. It shows the options as
    chips with the recommended one selected and that option's action in full, plus **Something
    else…**, which swaps the action for a text box. **Do It** queues the acting run for the
    selected option or the typed instruction (one at a time; it may overlap a scouting pass).
    No button is the default, so Return never approves anything. By default an acting run can
    label, trash, and mark mail and write drafts, and cannot send.
  - **A finished proposal has a row only when the run that carried it out asked for one.**
    Whether the person still needs to see a result is the agent's judgment, so every acting
    run, reviewed or under a standing approval, is told to end on a last line
    `Notify: yes` or `Notify: no` (`ProVisorCommand.noticeInstruction`): yes when something
    is now theirs to do or decide (a draft to send) or the outcome is not what they would
    expect, no when it went as described and nothing is left for them. `ActionReport` reads
    the line (searching only the end of the text), takes it off the result, and records the
    proposal `done` with `cleared` set to the run's answer (`ProposalStore.recordCarriedOut`),
    so on no the row leaves when the run ends. A run that does not end on the
    line keeps its row, and a failed one stays in the queue. **A request settled by
    the person's own sign-in is recorded cleared too** (`ProposalStore.settleSiteRequest`):
    no run decides, and "Signed in to <site>" tells them nothing new. To see what a wording
    change to the instruction does, give the CLI a reviewed run's prompt with `--tools ""`,
    say what to assume the tools did, and ask for the closing message alone.
  - **Continue in Claude** sits at the leading edge of the review window's footer while the
    Claude desktop app is installed (`ProVisorCenter.canHandOff`, read as the window opens).
    It hands the proposal to a session the person directs, for work that needs a real browser
    or their judgment at each step; Untrusted Input says what bounds it. Whatever is in the
    **Something else…** box goes along as their direction. **It decides nothing and starts no
    run**: the proposal stays open under a caption saying when it was continued, and can
    still be approved, dismissed, or handed off again. **Every handoff draws the desktop
    app's "Trust this workspace?" dialog**, because every handoff's folder is new. When the
    session's `findings.md` comes back, the proposal is recorded `done` with the fixed result
    "Continued in Claude." and cleared (`ProposalStore.recordReturn`, decided by the status on
    disk, which leaves alone a proposal already decided or one a run is carrying out), and a
    follow-up pass is owed while a note in `returned/` says `Status: new` and came back
    within three days (`ReturnedNotes`), on the note-driven schedule. The three-day bound is
    what stops a note no pass marks read from starting passes for good. The session's guide
    asks for findings when the person says the work is done or pauses it, so a pause settles
    the proposal and hands what is still owed back to ProVisor; a session that writes no
    findings leaves the proposal open.
  - **Standing approvals** are how "ask me" becomes "just do it", and **both the rule and its
    condition are the agent's to work out from the decision history** — there is no per-kind
    switch and no condition grammar in Swift. A rule is two sentences, a condition and an
    action ("when mail arrives from Maya Chen" / "label it 'Reply today'"; "when it is Tuesday"
    / "trash unopened promotional mail"). The protocol tells the agent to compare what was
    approved with what was dismissed and offer the narrowest condition that separates them —
    who, when, or what — and never to reach past that evidence. It offers by adding
    `"standing": {"when", "do", "because"}` to a proposal; the review window shows all three
    (`because` is the pattern it found, with counts, so the user can judge where the line was
    drawn) and **Always** beside **Just Once**. An offer goes with the recommended option and
    shows only while that option is selected. **Always** appends the rule to `standing.json`
    (`s-<8 hex>` id); either answer is written back as `standingDecision`, so "just once"
    teaches the agent to keep asking, while approving another option or typing an instruction
    leaves the offer unanswered. A proposal claiming `under` a rule is admitted only when it
    has a single action — nobody is there to choose among options. **Time is spelled out for the agent, never left to
    derive**: each decision is stamped `decidedLocal` ("Tuesday 2026-11-17 09:12") and each run
    is told today's weekday and local time (`ProVisorClock`), because a rule can turn on the
    weekday and working one out from a UTC timestamp is where a model slips. A rule with a
    time condition is acted on once per occurrence, and only on a pass that happens to run
    then — the schedule is not driven by the rules. From then on the scout is told the rules in
    force and may mark a proposal `"under": "<id>"`; `ProVisorCenter` admits it without a tap,
    carries it out with the `auto` tool list, and records `automatic: true`. When the run asks
    for its result to be shown, it is a **Done automatically** row that leaves by itself after
    a day; its review window names the rule and offers **Stop Doing This**. Settings lists
    every rule in force with **Remove**. A
    revoked rule stays on file, and the scout is told never to offer it again. Something
    admitted under a rule is not announced: only what needs a decision raises the banner.
  - **Asking for a sign-in.** `SignInDemand` is the list of sites that need the person: a
    granted site that is flagged in `sites.json` or that a run was turned away from since the
    person last signed in (`SiteAccessCenter.awaitingSignIn`, in memory, fed by
    `SiteAccess.onPersonNeeded` and emptied by a save, a removal, or a later visit that opens
    the site), and a host an open request names. `SiteAccess` tells its hooks only about an
    answer that still describes the current record, so a visit that began before the person
    saved the site again says nothing. A site turned away because its start page left the
    site's hosts or its day's attempts are used up is awaited, never flagged: flagging stops
    the app's own attempts until the person signs in. **For a granted site the app asks the
    person itself**, so `open_site`'s reply tells the agent that it has, to keep a follow-up
    note with `Waits on: <host>`, and to leave the site alone for the run; the agent raises an
    item only for a site it has not been given. The prompts shown are the announceable items
    (see Untrusted Input) less the granted sites the user put off with **Not now**, which
    stay hidden until a run is next turned away from them (`SignInPostponements`).
  - **Attention:** ProVisor holds one announcement (`ProVisorAnnouncement`, a pure reducer
    with the effects of each transition in `Effects.between`). A sign-in prompt raises the
    glow and a banner, **Sign in to <name>** with a Sign In button, held until the user opens
    the sheet or taps it; it outranks the ideas count, and a second site grows "and N more"
    under the name already shown, so the button never changes under a cursor. A finished run
    that adds proposals needing a decision — a scouting pass, a follow-up pass, or a reviewed
    run raising something it could not settle — raises the glow and an 8-second banner
    carrying a count only (`ProposalAnnouncer`; each proposal is announced once, since passes
    and a reviewed run can overlap, and a repeated request for a site already asked for is not
    news). A count that a sign-in covered returns if the sign-in leaves the demand unseen. A
    proposal behind a visible sign-in prompt is folded into that prompt's sheet row and left
    out of the count. In the sheet, sign-in rows lead the section, three unprompted and the
    rest behind **N more**. No compact presence.
  - **Settings › ProVisor never shows the agent's account of a pass.** The agent's words
    are drawn from mail anyone can send, so they appear only where a proposal is reviewed
    and, on this pane, in a standing rule the user read in full and accepted. The pane shows
    when the last pass ran and, for one that failed, why in the app's words
    (`ProVisorCenter.failureSentence`, built on `AgentTaskError.fixedDescription`, which
    leaves out the agent's result text and its process's output; a pass that could not be
    set up reads from `setupFailureSentence`). **A failure's detail is therefore on record
    nowhere**: the pane and the log both carry a fixed name, so finding which flag an old
    CLI refused means running the CLI by hand. What the agent says when a scouting or
    follow-up pass ends is kept nowhere: the protocol tells it, over whatever a seeded
    charter still says about a closing summary, that its notes under `memory/` are the
    record of a run, and **Open Folder** is how the user reads them. What ProVisor may read sits under one
    collapsible **Access** row, closed when Settings opens. **The row itself says what a
    closed group would hide**: what is granted ("1 site, texts, photo places",
    `accessSummary`), or **Needs attention** while a site waits for a sign-in, a source is
    switched on that macOS will not let the app read, or reading is paused
    (`accessNeedsAttention`). The refreshes of those statuses hang on that row, which is
    mounted open or closed; the rows under it are unmounted while it is closed. Under it are a
    **Sites** row with a count ("2 sites, 1 needs you",
    `ProVisorSettingsView.sitesSummary`) and **Manage Sites…**, the **Read my texts** toggle
    with a Full Disk Access row that opens System Settings while a read fails, the **Read
    where my photos were taken** toggle, a line naming the condition that pauses reading
    sites, texts, and photo places when one fails, and the **Offer to keep passwords** toggle
    (`provisor.offerPasswords`, on by default). Turning the photo toggle on asks for access
    to Photos when the user has never been asked (the system shows that prompt once); a row
    under it offers **Allow…** while they have not answered and **Open System Settings** once
    they refused (`SiteAccessCenter.PhotoPlacesStatus`).
  - **The sites window** (`ProVisorSitesWindow`, opened by **Manage Sites…**) lists the
    granted sites, each with its name, host, and one of **Needs you** (flagged, or a run was
    turned away since the last sign-in), **Signed in** *(when)* (with "asks you when it signs
    you out" for a kept session), or **Not signed in yet**, and with **Sign In Again** and
    **Remove**; **Add Site…** is at its foot. Remove deletes the Keychain item, the registry
    entry, and the cookies and site data the site's browse hosts left, except what another
    granted site shares (data is kept per registrable domain). Its size is the user's: the
    hosting controller carries no sizing options (the hazard `FittedWindow` describes).
  - **The site window** (`ProVisorSiteWindow`) is one reused window, the form on the left and
    the live page on the right. **Keep me signed in**, the default, asks for the address only:
    the user signs in on the page and the grant keeps the session and no secret; when the app
    saw no sign-in, Save Site says so and offers **Save Anyway**. The address is the one the
    user normally starts from: one that carries a query or sits on a sign-in service's host
    draws a note (`SiteFormModel.addressAdvice`), because a page from the middle of a sign-in
    another browser started is answered with an error. **Sign in for
    me** also takes the user name, password, and a code source (none, authenticator key,
    texted, or emailed); the app fills what it recognises while the user watches, and the user
    can finish in the page. The bar above the page shows the host and padlock of the page
    *displayed* (`committedURL`, since `webView.url` names a page the moment its load starts)
    and says **Not secure** when any of its content came over an unencrypted connection.
    **The window's size is the user's**: its hosting controller carries no sizing options (the
    hazard `FittedWindow` describes), so nothing the form shows or hides resizes it from inside
    a layout pass. Closing it by any route ends the enrollment, which forgets the typed secrets
    and closes the browser. A proposal that names a site gives the review window a **Sign In
    to <host>…** button (**Sign In Again to <site>…** for a granted one) that opens this window
    for that request.
  - **The sign-in window** (`SiteSignInModel`, `ProVisorSignInView`) is what every request to
    sign in opens: a notch prompt, the review window's button, and the sites window's
    Sign In Again,
    for any site whose stored sign-in can be read. It shares the site window and its live page
    (`SiteWindowParts.swift`) and shows a title, one sentence, **Done**, and Cancel, with an
    address field only when it has no address to open (see Untrusted Input). The user signs in
    on the page and presses Done once. **Done is always pressable and never presses itself**:
    it turns to the brand style while the app believes the user is signed in
    (`SiteEnrollment.appearsSignedIn`, advice only), and nothing closes the window but Done
    succeeding, Cancel, or the close button, since a sign-in can pass through a page that
    looks finished. Done saves a kept session through the same check and the same Save Anyway
    as the form. **It never replaces a saved password**: before saving it reads the site the
    save would land on and refuses when that site's grant remembers a password
    (`SiteSignInModel.Destination`), which a typed address can otherwise reach; an existing
    kept-session site keeps its name and the date it was added. A page that fails to load
    offers **Try Again**. After
    Done, when a typed password can be kept (see Untrusted Input), the window stays open on
    **Keep Password** / **Session Only**, showing the user name and the host it was typed on;
    when one was typed but cannot be kept it shows why and a Close button. **Follow-up passes
    are held while that offer is up** (`FollowUpHolds`): keeping the password saves the site a
    second time, which closes the visits open on it and would cut off the pass the sign-in
    just set off. The pass starts when the window closes.
  - **A site with a saved password** opens the same window with the app filling its saved
    secrets while the person watches and finishes what it cannot (a challenge, a new-device
    check). Done then does the first of these that applies
    (`SiteSignInModel.doneWithSavedPassword`):
    1. the app's fill was accepted: the refreshed grant is saved;
    2. it was not, and the person typed a password that can be kept: **Keep Typed Password** /
       **Leave As Is**. **A replacement is the stored grant with only its password changed**
       (`PasswordOffer.grant(replacingPasswordOf:)`), whenever the password was typed on one
       of the site's recorded fill hosts: the person usually retypes only the password, often
       on an error page, and a grant rebuilt from that typing would have no user name, no
       code source, and a step on the wrong page. A password typed on a host the site did not
       record is judged as a new sign-in is;
    3. otherwise the stored grant is left exactly as it is and the person's sign-in is
       recorded (`SiteAccess.personSignedIn`, after a hidden read confirms the stored grant
       reads as signed in), so the site is read on its session until that ends.
    **A password the site turned away is not submitted again** (`SiteRecord.passwordRejected`,
    set when an unattended sign-in is still signed out after filling it, or when the window
    saw the fill refused): the app makes no unattended attempt and asks the person, and the
    window opens with the password withheld, so the person types the working one and can keep
    it. A site that locks an account after repeated failures would otherwise be sent the same
    wrong password on every lapse. After Done reaches a panel no saved secret is filled into
    any page, and typing that the app's fill then overwrote is not a typed password. No path
    saves a session, or a password, over a stored password without the Keep press. The form
    this window replaced for such sites (`SiteFormModel`'s signing-in-again path) remains in
    the code with nothing routing to it.

**`Modules/SystemHUD/`** (volume / brightness / keyboard-backlight HUD — `VolumeController`,
`BrightnessController`, `KeyboardBacklightController`, `MediaKeyMonitor`) is present but **NOT wired
into `ModuleRegistry`** — dead/unreferenced code kept for possible future use; nothing activates it
at runtime.

## Shared Services

- **`Services/Logging/`** — `AppLog` sends sparse lifecycle, state-transition, helper, and failure
  events to the unified log while `FileLogMirror` keeps a plain rotating file for direct
  inspection. Callers log only names, states, counts, durations, and error descriptions — never
  file, OCR, clipboard, page, or message content, browsing history, or an address with a query
  string — and logging failures never throw or crash the app. **The file is written by the app
  process alone** (`FileLogMirror.writesInThisProcess`): the test runner exercises the same
  code, and its lines would read in the file as things the running app did.
- **`Services/Attention/AttentionGlowCenter.swift`** — a module-agnostic one-shot attention signal
  read by the root view. **Each module holds its own claim** (`raise(for:)`, `clear(for:)`,
  keyed by module id); the glow shows while any claim stands, and opening the sheet ends them
  all (`clear()`). A module retires its banner when its own claim ends
  (`claimPublisher(for:)`), never on the glow going dark: with one shared flag, a module
  acting on its own banner would retire another module's banner that a higher-ranked one was
  covering, before anyone saw it.
- **`Services/Hotkeys/GlobalHotKey.swift`** — a system-wide shortcut over Carbon's
  `RegisterEventHotKey`. It needs no Accessibility grant, fires while another app owns the
  keyboard, and **consumes** the keystroke — `NSEvent.addGlobalMonitorForEvents` (what the dormant
  `MediaKeyMonitor` uses) can only observe, so the key would also reach the frontmost app; and
  `NotchWindow` never becomes key, so no responder-chain mechanism sees a keystroke at all. Carbon
  dispatches every hot key to one process-wide handler carrying only an id, hence the id→action
  map. Registration returns false when the combination is already held; the failure is reported
  once per shortcut, since arming retries whenever the owning state changes. Callers arm it only
  while it would do something — a permanently held combination is one the rest of the system can
  never use.
- **`Services/Attention/SectionUrgencyCenter.swift`** — a module-agnostic flag a module raises while
  its expanded section carries something to act on now (a blocked agent session, a call in
  progress). `ExpandedPanelView` floats every raised section above the quiet ones — below the
  pinned media section, which urgency never displaces — so the sheet's finite height goes to what
  cannot wait. Setting an unchanged flag publishes nothing, so a module
  may raise it from a periodic tick; a module clears its own flag on `deactivate`.
- **`Services/Sheet/SheetTakeoverCenter.swift`** — a module-agnostic way for one view to take
  over the whole expanded sheet (a picker, a list) and hand it back. `ExpandedPanelView` renders
  the current takeover under a back-button header (`UI/SheetTakeoverView`) in place of the
  section stack, and the sheet resizes to the takeover's own height. The sections stay mounted
  underneath at zero claimed height — invisible and untouchable — so an opened disclosure or a
  running timer is as the user left it on return. One takeover shows at a time; a presenter
  dismisses only its own (`dismiss(id:)`), and `NotchEngine` dismisses whatever is presented when
  the sheet closes, so it always reopens on its sections. The dismissal lives in the engine
  because a hover-exit close unmounts the panel in the same transaction, so nothing inside the
  panel can observe it.
- **`Services/FileSystem/FileChangeWatcher.swift`** — calls back when a file or directory is
  written, created, replaced, or removed. A vnode `DispatchSource` watches an open descriptor — an
  *inode*, not a path — so a writer that updates atomically (write temp, `rename` into place)
  leaves the watch pointing at the old unlinked inode and no later write is ever reported. The
  watcher therefore re-arms on `.rename`/`.delete`/`.revoke`, and watches the parent directory
  while the file is absent (so it may be started before the file exists). Callbacks are
  debounced, and fire on a private serial queue, not the main actor.
- **`Services/FileSystem/DirectoryTreeWatcher.swift`** — a recursive, debounced FSEvents watcher
  used for Codex's date-partitioned sessions tree and, through `ClaudeSessionMonitor`, the
  Claude session registry (SwarmVisor and AI Usage each hold their own monitor). It notices
  nested appends and in-place child rewrites with one stream, including an older Codex
  transcript resumed after its original date, without a discovery poll.
- **`Services/FileSystem/ThumbnailService.swift` + `QuickLookController.swift`** — shared local-file
  previews used by FileShelf. Thumbnail generation stays in Quick Look's service;
  the main actor only materializes the resulting `NSImage`.
- **SIGPIPE is ignored process-wide** (`AppDelegate.applicationDidFinishLaunching`). The app writes
  to pipes/sockets whose peer can vanish at any moment (codex app-server, the headless agent CLI,
  the perl now-playing adapter, clients of the swarm and bridge sockets); the default signal
  action kills the process with **no crash report and no stderr**. With it ignored, such writes fail with EPIPE
  and flow into each client's error path — which every helper client must therefore have.
- **`Services/LocalIntelligence/`** — the single FoundationModels touchpoint for on-device text
  generation; routing and UI lifecycle code remain provider-agnostic.
- **`Services/Calls/CallActivityMonitor.swift`** — the shared CallSense camera/microphone activity
  service. Its singleton uses reference-counted start/stop so Calendar and Media share one set of
  CoreMediaIO/CoreAudio registrations. Camera listeners use the same proc/client-data lifecycle as
  `AudioPropertyListener`, avoiding the Swift block-identity removal failure and unregistering
  exactly when the last client releases the monitor.
- **`Services/Audio/`** — CoreAudio helpers shared by modules (these are plain services, not
  `NotchModule`s, so modules stay decoupled). `AudioOutputController` + `AudioOutputSelector` (the
  default-output device and its picker — `OutputRouteButton` presents the device list as a sheet
  takeover on its own, so a consumer only places the button — used by Media and Meeting Mode) and `MicController`
  (default-input hardware mute for Meeting Mode; the mute follows the default input across device
  changes, so switching mics mid-call never orphans a system-wide mute on the old device). Live
  updates come through **`AudioPropertyListener`**, a shared wrapper over CoreAudio's **proc-based**
  listener API (`AudioObjectAddPropertyListener` + a retained weak-box `clientData`, hopping to the
  main actor). The block-based API is avoided: a Swift closure stored as a listener block re-bridges
  to a new block each time it crosses the C boundary, so `AudioObjectRemovePropertyListenerBlock`
  never matches on removal and leaks the registration on every remove. `LocalAudioOutputMonitor`
  answers "is any other process producing sound here?" from CoreAudio's per-process objects,
  event-driven through listeners on the process list and on each process's output state.
- **`Services/IPC/`** — `UnixSocketListener` binds, listens, and accepts on a Unix-domain stream
  socket (the file mode 0600 inside a folder created 0700, a socket file left by an earlier
  process replaced) and hands each connection's descriptor to its owner blocking, close-on-exec,
  and exempt from SIGPIPE; `UnixSocket` holds the address, connect, and option plumbing both
  ends share. `AgentEventSocket` (SwarmVisor's hook socket) and `AgentBridgeServer` are built on
  the listener. **`SO_NOSIGPIPE` is set on the listening socket and inherited**: setting it on an
  accepted connection fails with `EINVAL` once the peer has closed, which a client that writes
  and exits can do before the accept. `start()` and `stop()` run synchronously on the listener's
  queue, so neither may be called from it. `sun_path` holds 104 bytes: a home directory long
  enough to overrun it fails the bind (`pathTooLong`, logged), the bridge helper takes
  `SUPERVISOR_BRIDGE_SOCKET` as an override, and tests keep their socket paths short.
- **`App/BundleReplacementMonitor.swift` and `Services/Process/RelaunchHolds.swift`** — the
  relaunch after the bundle is replaced (see Build & Run). One file-system event stream
  follows the bundle's path, since a build removes the bundle and assembles it again and a
  descriptor watch would be left on the removed file; nothing else runs while the bundle is
  intact. **"Nothing in progress" is an agent run, an ordinary window open or minimized, the
  sheet open, or a module's hold** (`RelaunchHolds`): modules hold while they keep something a
  relaunch would lose or undo, which is what the person put on the shelf or the app made for them
  (in memory, and a generated file is deleted at the next launch; screenshots stage
  themselves and stay in the screenshot folder, so a shelf of only those is no hold, or it
  would seldom be empty), a call in progress (quitting restores a microphone the notch
  muted), and music the app paused for a call. State the app reads back at launch (the
  sessions SwarmVisor lists, the sites ProVisor waits on) is no hold. The bundle is validated
  only once the app is idle, because validating reads every file in it; while it waits the
  `engine` log names what it waits on (`relaunching after: open window, fileshelf hold`). **The relaunch is a
  shell that outlives the app** (`relaunchCommand`): it waits for the process to exit, waits
  for the bundle to verify against the app's requirement again (another build may have begun
  since the check, and a half-built bundle would launch as an unsigned copy), and opens it
  unless a copy is already running.
- **`Services/Process/`** — `ProcessResponsibility` (the disclaim call by symbol, reporting when
  it is absent so a caller can refuse to proceed), `DisclaimedExec` (`--exec-disclaimed`),
  `ChildEnvironment` (the fixed environment), and `ProcessAncestry` (a process's parent and
  start time from the kernel's process table, which `SessionHost` and the bridge share). The
  reasons are under Untrusted Input. **`NSHomeDirectory()`, `NSUserName()`, and
  `NSTemporaryDirectory()` ignore `$HOME`, `$USER`, and `$TMPDIR`**, so setting those for a
  test process or a child moves nothing they report.
- **`Services/AgentBridge/`** — the tool channel between an agent run and the app (rules under
  Untrusted Input). `AgentBridgeServer` is the app's end; `AgentBridgeHelper` is the
  `--agent-bridge` mode, speaking MCP over stdio through `AgentBridgeProtocol` (a tool result is
  cut at 100,000 characters) and newline-delimited JSON over the socket through
  `AgentBridgeWire` (a request line is at most 64 KiB, a reply 2 MiB); `PeerIdentity` holds the
  caller checks (audit token, designated requirement, parent walk) and `AgentExecutableTrust`
  the CLI's signing requirement, the one place the CLI's vendor is named. `--exec-disclaimed` and
  `--agent-bridge` run before `NSApplication` exists, from `SuperVisorMain.main()`, and use
  neither AppKit nor the app's log; **the bridge helper ignores SIGPIPE itself**, since the app's
  process-wide setting does not reach it. ProVisor's side is `ProVisorBridge` (tokens, per-run
  configuration, eligibility) and `ProVisorTools` (the five tools).
- **`Services/Sites/`** — signed-in page reading and the app-side sign-in (rules under
  Untrusted Input): `SiteVault` (Keychain, one item per site), `SiteRegistry` (`sites.json`,
  written atomically at mode 0600, at most 50 sites; a symlink or an oversized file reads as
  empty), `TOTP`, `SiteNavigationPolicy`, `PageSnapshot`, `SiteBrowser`, `SignInBroker`,
  `SiteEnrollment`, `HiddenRead` and `VisitorCheck` (a page read once in a browser of its
  own, on the person's store or as a visitor), and `SiteAccess`, the one writer of
  `sites.json` and what a run's tools call. **Closing a `SiteBrowser` answers every script call
  still waiting on it**, so a read bounded by a timer that closes the browser ends when the
  timer does. **A settle poll sent while a navigation replaces the page can go unanswered**,
  so the two poll scripts wait at most 2 s (a lost poll counts as an empty sample); at the
  full script limit one lost poll stalls a read for 10 s, which is all a hidden read has.
  `SiteBrowser` is a `WKWebView` in a window the person never sees (an enrollment moves the
  view into the site window for the user to watch). **The window is on screen, fully
  transparent, beneath the desktop, and passing clicks through, with WebKit's occlusion test
  switched off for the view** (`keepRendering`, the private
  `_setWindowOcclusionDetectionEnabled:`; where the call is missing the window stays off
  screen and one `sites` error line says so): a web
  view whose window is off screen tells its page it is hidden and gives it no animation
  frames, and a page that reveals streamed content on a frame then stays on its loading
  placeholder for good. The read comes back with no text and no links and nothing fails (a
  site's server-rendered start page reads fine while the pages behind it read empty). The
  `site-read` self-check reports `pageVisible` and `animationFrame` for the real bundle; it
  has been run with the display awake only. A page that believes it is visible also does
  what it does on being seen (marking items read, counting an impression), which a read
  could not cause while pages were told they were hidden. The
  view is on a persistent data store of its
  own (`WKWebsiteDataStore(forIdentifier:)`, under `~/Library/WebKit/<bundle id>/WebsiteDataStore`)
  with a Safari user-agent string, because sites refuse WebKit's bare one. A script's result
  crosses one boundary (`ScriptValue`: types checked, depth and sizes bounded) before anything
  reads it. **`simulatedPages` is the test seam**: it answers each main-frame navigation with
  HTML that `loadSimulatedRequest` serves at the request's own `https` URL, so a page sees a real
  origin, path, and secure context while nothing leaves the machine, and a navigation the
  closure answers with nil fails. **That load re-enters the navigation delegate**, which
  recognises its own serve (`pendingServe`) and lets it through; frames other than `about:` ones
  are cancelled and sub-resources are not intercepted, so simulated pages must be
  self-contained. `TestSite`, in the test target, is an in-memory site built on the seam.
- **`Services/Messages/MessagesStore.swift`** — a read-only view of
  `~/Library/Messages/chat.db`, which needs Full Disk Access. It reads texts since a date (one
  sender, or containing a phrase), the newest row id, and the newest or first code message after
  a row id. `SignInCode` finds and masks codes: a candidate is a standalone run of 4 to 8 digits
  (or two groups of three), not one inside a date, price, or phone number, and not one after an
  account word (`card ending 4821`). `message.date` counts nanoseconds since 2001-01-01 on
  current macOS and seconds on old versions, and the date filter handles both. Two reads exist
  on purpose: `messages` (as sent, for the app's own matching) and `messagesForModel` (masked,
  the only read for anything a model sees).
- **`Services/Photos/PhotoPlaces.swift`** — when and where the photos in the user's Photos
  library were taken (rules under Untrusted Input). `PhotoPlaces` is three closures (the
  permission, the request for it, and the read) so that tests supply a library of their own:
  **the test runner has no bundle, and PhotoKit asked for permission without a usage string
  ends the process**, so no test touches `PhotoPlaces.library`. `PhotoTrail` is the pure part,
  turning a read into stays. The read walks the library and runs off the main actor.
- **`Services/Browsing/BrowsingHistory.swift`** — answers one question and exposes nothing else
  (no address, title, or date leaves it): has the user visited exactly this host over `https` on
  at least two distinct local days? It reads each Chromium-family profile's `History` file,
  opened immutable because the browser keeps it locked while it runs, and Safari's `History.db`.
  **Chrome's folder and Safari's are protected by macOS and are read only with Full Disk
  Access**: touching them without it can put a consent prompt in front of the user, so they are
  skipped unless Safari's file opens (`canReadProtectedData`), while the other browsers' folders
  are read regardless. Anything that keeps a file from being read (missing, no access, another
  schema, busy) reads as no visits, so an unfamiliar browser layout fails into the cautioned,
  unrecorded sign-in window. The `history` self-check confirms both layouts.

## Theme & Settings

- **`Theme/LiquidGlass.swift`** (`NotchTheme`) — design tokens + Liquid Glass material wrappers.
  `LiquidGlassSurface` clips to a rounded rectangle; `LiquidGlassShape` pours the material into an
  arbitrary `Shape` (the morphing `NotchShape` is neither a rectangle nor fixed). Both use the
  native macOS 26 `glassEffect`, degrading to `.ultraThinMaterial`.
- **Brand color: a pink→cyan gradient is the app's primary accent.** Any element that needs a
  primary/accent color uses the brand, never the system `Color.accentColor`. `NotchTheme.brandGradient`
  (`brandPink` → `brandCyan`, top-leading to bottom-trailing) is a `ShapeStyle`, so it goes directly
  into `.fill`, `.strokeBorder`, and `.foregroundStyle` — use it for selection strokes, drop-target
  highlights, the compact badge, checkmarks, prominent buttons (the Meeting Mode dot + Join), etc.
  `NotchTheme.brandColor` is the single-`Color` fallback for the few sites that require a `Color`
  rather than a gradient (a shadow/glow color, a per-list color fallback); `brandPink`/`brandCyan`
  are the endpoints. Leave **semantic status colors** (green = live/ongoing, orange = due soon, red =
  destructive/muted) and **per-list colors** (a calendar's or reminder list's own `event.accent` /
  `item.accent`) as they are — those carry meaning and are not the brand.
- **Tooltips need `.notchTooltip(_:)`, not `.help(_:)`.** `NotchWindow` is a borderless,
  non-activating `NSPanel` (`canBecomeKey == false`), so macOS never gives it tooltip tracking and
  native `.help()` tooltips do not render. `.notchTooltip(_:)` (in `Theme/LiquidGlass.swift`) is a
  custom hover overlay that shows a label above the view after a short delay; its reveal is a
  cancellable hover-scoped `Task`, so nothing runs at idle. Keep `.help()` alongside it for
  accessibility, but the custom modifier is what the user actually sees.
- **The surface's material depends on the screen.** Over a physical cutout it is opaque black in
  every state — it is impersonating milled aluminum, and translucency would give that away. On a
  screen with no cutout, the pill *and* the sheet it grows into are **clear Liquid Glass**
  (`ExpandedPanelView` carries no chrome of its own; the morphing surface is its background).
- **A glass surface needs a fill under it or it cannot be clicked.** `NotchWindow`'s container
  gates on `interactiveRect` and then defers to `NSHostingView.hitTest`, which reports a hit only
  where SwiftUI actually *drew* something. `glassEffect` paints a material but contributes no body,
  and a fully clear fill draws nothing, so clicks fall straight through the window to the desktop —
  the surface would answer only where compact content happens to cover it. `.contentShape` does not
  help: it steers gesture dispatch *after* AppKit has routed the event to the view. Hence the fill
  at `NotchTheme.hitTestableAlpha` (0.001, under one unit of an 8-bit channel). Verify any change
  here by posting synthetic clicks at bare surface *and* at the canvas outside it — the first must
  reach `toggleSheet()`, the second must still pass through.
- **`Settings/SettingsStore.swift`** — `UserDefaults`-backed, `SettingsStore.shared`. Per-module
  enabled flags and hover sensitivity. Modules default on, except those in `optInModules`
  (ProVisor), which stay off until the user enables them.

## Debug

`SettingsStore.debugTintEnabled` (a toggle in Settings, persisted as `debug.tintRed`) tints the
whole rendered surface **bright red** so its exact bounds are visible against the black hardware
notch. The surface renders in every state — with no compact content it rests as a bare black
pill exactly over the cutout — so the tint is always visible. The pill is **always symmetric**:
both sides render at the wider side's measured width (`max(leading, trailing)`), so compact
content never shifts the pill off the notch's center.

**Investigating a dead app.** Start with the structured log, then inspect process and crash
artifacts:

- The app logs lifecycle/state/helper/failure events to unified-log subsystem
  `com.supervisor.SuperVisor` (categories: `engine`, `module`, `swarm`, `calls`, `media`, `usage`,
  `agentDispatch`, `fileShelf`, `provisor`, `sites`) and mirrors notice/error lines to
  `~/Library/Logs/SuperVisor/SuperVisor.log` (1 MiB rotation, two generations kept). Query it with
  `/usr/bin/log show --predicate 'subsystem == "com.supervisor.SuperVisor"'`.
- A crash (`fatalError`, force-unwrap, EXC_BAD_ACCESS) writes
  `~/Library/Logs/DiagnosticReports/SuperVisor-*.ips` with full backtraces. **No `.ips` plus
  empty stderr means a terminating signal** (SIGPIPE/SIGKILL class) or a clean `exit()`.
- Pin down the signal by running the binary under a wait-status wrapper:
  `zsh -c '<binary>; echo $?'` — 128+signal (141 = SIGPIPE, 137 = SIGKILL, 139 = SEGV).
- In zsh, `log` is a **shell builtin**; unified-log queries must call `/usr/bin/log`
  (`/usr/bin/log show --last 30m --predicate 'process == "SuperVisor"'`). Process names in other
  processes' messages are often privacy-redacted, so search by PID as well.
- `pgrep -f SuperVisor.app` and `ps | grep` also match the **perl now-playing helper** (its argv
  contains the bundle path). Match the executable exactly (`ps -o comm | grep "MacOS/SuperVisor$"`)
  before concluding the app is alive. That executable is also the bridge helper (`--agent-bridge`,
  one per ProVisor run in progress) and a self-check instance, so read its arguments too
  (`ps -o pid,args`): a helper alone is no sign the app is up.
- The swarm socket (`~/Library/Application Support/SuperVisor/agent-hooks.sock`) doubles as a
  liveness/timeline record: it exists iff an instance bound it and
  died uncleanly since; its mtime is the moment that instance's SwarmModule activated.

**A handoff's log lines** are in `provisor`: `handoff opened`, `handoff findings admitted <n>`,
and for what went wrong `handoff refused: foreign entry in the handoff folder`, `handoff not
recorded`, `handoff link not opened` (beside `session link open failed: <domain> <code>`),
`handoff ledger not saved`, and `handoff return not recorded`. Findings that never arrive are
a `findings.md` the session did not write, one in a folder the ledger does not name, or one
still inside its 60 s of quiet.

**A pass can run without its site, text, and photo-place tools while nothing fails.** The `provisor` log
carries `bridge tools off: <reason>` (`nothingGranted`, `accessNotSealed`,
`cliNotTrusted`, `disclaimUnavailable`, `appReplaced`, `serverFailed`) when a pass starts
without them (`appReplaced`: the bundle on disk is not the code the app is running, checked
before each pass by `PeerIdentity.runningCodeIsIntact`), and
`tool <name>: <outcome>` for each call; Settings states the reason, `nothingGranted` apart. A
bridge refusal logs `agent bridge refused: <reason>` in `agentDispatch`, written to the file
once per reason per 30 s with the rest at debug level in the unified log (`callerLeft` is a
helper that connected and hung up without a request, which is what a helper does when it
cannot verify the app), and a sign-in logs
`sign-in for <host>: <result>` in `sites`. A pass or an acting run that failed logs
`<kind> failed: <name>`, where a run stopped by its own allowance reads `turn limit` or
`spending limit` (it has still written what it reached) and any other failed result reads
`agent error`. **`tool open_site: ok` with a page of no text and no links can be a page that
did not render**: run the `site-read` self-check and see `keepRendering` under Shared Services.

**A fresh screenshot with no `com.apple.metadata:` attributes is a Spotlight symptom, not a
capture bug.** `screencapture` applies `kMDItemIsScreenCapture` through the metadata framework,
which silently writes nothing while the Data volume's index is unhealthy (`mdutil -s
/System/Volumes/Data` reports "unknown indexing state"; `mdls` answers "could not find" for
files that exist). The shelf keeps working through that because `ScreenshotMonitor` also
accepts the capture comment embedded in the image itself.

## Git

- Committing and pushing directly to this repo is fine — no need to ask first.
- **Don't create PRs for this repo.** When asked to ship changes, push to `main` directly.
- **Always push to `main` directly; don't create worktrees or branches.** Work in the main
  checkout at `/Users/sdeng/code/supervisor`. `.claude/settings.json` sets
  `worktree.bgIsolation: "none"` so a background session edits there rather than isolating
  itself in a worktree first.
- **Commit messages must not carry co-authorship or tooling trailers** — no `Co-Authored-By:`
  line and no `Claude-Session:` line. Keep the message to the change itself.
