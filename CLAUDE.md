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
  `SIGNING_IDENTITY` to override selection.
- **`open build/SuperVisor.app`** — launch. It is an **`LSUIElement`** menu-bar agent
  (`.accessory` activation policy): no Dock icon, no main window. A status-bar item
  (`visionpro` glyph) hosts the **Settings…** and **Quit** menu.
- **Quit** via the status-bar menu, or `pkill -f SuperVisor.app`.
- **`swift test`** runs the suite in `Tests/SuperVisorTests` (Swift Testing). The test target
  depends on the executable target and reaches internals through `@testable import SuperVisor`,
  so logic can be tested without a second library target. Tests that need a session registry
  write real records to a temp directory using the test process's own pid, which is what makes
  them pass the registry's liveness check.
- **`swift build`** alone compiles the binary but does *not* produce the bundle. The bundle is
  required because TCC permission grants (Location, Calendar, Reminders, Accessibility, Bluetooth) and the
  now-playing read only persist for a **stable, signed bundle identity** — a bare `swift run`
  binary gets a fresh identity each launch and grants never stick. `make-app.sh` also compiles
  the MediaRemote adapter dylib (see below), applies `SuperVisor.entitlements`, and DER-encodes
  its Calendar entitlement; `swift build` does none of those packaging steps.

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
  (Media, Calendar, Reminders, FileShelf, Flow, SwarmVisor, Battery, AI Usage).
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
`HoverMonitor.refresh()` — a nudge arrives at a micro-pause with the cursor stationary, so absent
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
- **Agent hook socket payloads** are arbitrary local input. Each connection is size-capped and
  defensively parsed, and a tty must match `^/dev/ttys[0-9]+$` before it is stored or reaches
  AppleScript interpolation. The text fields (`message`, `last_assistant_message`,
  `error_details`) carry model-generated prose that reaches a view: the hook truncates at the
  source, `FleetHookEvent.isValid` rejects a payload whose fields exceed the cap rather than
  trimming it, and `AgentFleetCenter.displayMessage` collapses whitespace and strips control
  characters — an ANSI escape or a newline in a summary would otherwise redraw a notch row.
  Registry `waitingFor` is bounded the same way in `ClaudeSessionMonitor`. None of this text is
  ever logged; `AppLog` records the reason's name only.
- **Screenshot-directory contents** are arbitrary local files. `ScreenshotMonitor` accepts only
  direct, regular, non-symlink image/PDF children carrying macOS's
  `com.apple.metadata:kMDItemIsScreenCapture` attribute, requires a non-zero size, and rejects files
  over 512 MiB. It baselines existing paths before emitting anything. Vision OCR separately caps
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
  so a prompt-injection payload in the file cannot read anything but the copy. A natural-language
  preamble marks the content as data, not instructions, as defense-in-depth. The on-device path has
  no tools, so injected instructions in file content cannot act; the same preamble still marks the
  content as data.

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
  synthesized bounce (`AudioBarsView`) in the same footprint. A **beat aura**
  (`UI/BeatAuraView`, layered behind the morphing surface in `NotchRootView`) glows around the
  notch in the artwork color, following the music's bass envelope. Both are toggleable in
  Settings (`media.trueSpectrum`, `media.beatAura`). Expanded: large artwork, title/artist, a live
  scrubber, transport, and an **audio-output device switcher**. Info streams from one long-lived
  perl adapter (`NowPlayingStream`), which pushes a snapshot only when the state changes; commands
  via `MediaRemoteBridge`. While `calls.autoPauseMusic` is on, a detected call pauses active
  playback and resumes it only when the automatic pause claim still owns the same paused
  now-playing session.
- **Calendar** (`Modules/Calendar`) — next-meeting countdown chip in compact; an agenda with a
  one-tap **Join** button (Zoom / Meet / Teams / Webex link detection) in expanded. EventKit via
  `CalendarService`. **Meeting Mode:** while a meeting with a join link is in progress, Calendar
  contributes no compact mic indicator because macOS already shows microphone activity in the
  menu bar; the sheet leads with a call HUD — the meeting rendered in the agenda's row style
  (calendar-accent dot, green elapsed/ends-in line) above a system-wide **mic-mute** toggle
  (`MicController`), an audio-output switcher, and Join. The agenda carries no header, so the
  in-progress row and upcoming meetings read as one list. A mute applied via the notch is
  auto-restored when the meeting ends. CallSense also raises Meeting Mode for ad-hoc calls from
  the public CoreMediaIO/CoreAudio "running somewhere" camera and microphone properties, with a
  3-second start debounce, a 5-second end debounce, and the spectrum tap's aggregate/virtual
  devices excluded. The ad-hoc HUD says **On a call** and omits the event title, Join, and dismiss;
  a scheduled meeting wins when both signals apply, and mic auto-restore covers either call type.
  Any surfaced meeting can be dismissed from its agenda row or Meeting HUD; the occurrence is
  excluded everywhere, including FlowVisor's meeting deferral. Dismissals live in memory in
  `MeetingDismissalStore` (`Services/Meetings/`), keyed by event ID plus start time and pruned when
  the meeting ends; an **N dismissed** agenda footer lists them for one-tap restore and keeps the
  section visible when every meeting is dismissed.
- **Reminders → "TaskVisor"** (`Modules/Reminders`) — due-today + overdue Apple Reminders. Compact:
  a checklist count badge (red when any are overdue). Expanded: a **tap-to-complete** checklist
  with list color, live due/overdue text, and a high-priority marker. EventKit via
  `RemindersService`.
- **FileShelf** (`Modules/FileShelf`) — one unified staging inbox for both dropped files and
  screenshots (named literally, not a `<Feature>Visor` brand). Each `StagedFile` carries a
  `source` (`.dropped` / `.screenshot` / `.generated`) that drives a corner badge on its tile.
  Dropping a file onto the notch opens the sheet and stages it; `ScreenshotMonitor` (moved into
  this module) recognizes new macOS screenshots through the system
  `com.apple.metadata:kMDItemIsScreenCapture` extended attribute (never by localized/user-defined
  filenames), watching both the destination directory and
  `~/Library/Preferences/com.apple.screencapture.plist` — a destination change reconfigures the
  watcher live, and existing files are baselined on activation/reconfiguration. A new screenshot
  animates into the pill with a 3.2-second peek, then its arrival flourish collapses into the
  persistent count badge. Screenshots evict oldest-first past eight; dropped and generated items
  are never auto-evicted. Expanded: a horizontal filmstrip of tiles with an icon-only capsule —
  Copy, Copy Text (Vision OCR, images/PDF; runs detached, only the resulting `String` returns to
  the main actor), Quick Look, AirDrop, Reveal, Zip, and an **agent-verbs** menu (Summarize /
  Explain / Extract Text) — plus, separated, **Remove** (off-shelf, non-destructive; a generated
  artifact's backing file is deleted) and **Move to Trash** (moves the original to the macOS Trash
  after verifying the file's recorded volume/inode identity, refusing a file swapped at the path).
  Agent verbs route to the on-device system language model when a file has a small plain-text or OCR
  representation; verbatim OCR satisfies Extract Text directly. The sandboxed headless CLI remains
  the path for large or binary content, an unavailable system model, and on-device failures (see
  Untrusted Input). Drag-out, Quick Look, and thumbnails via `FileShelfStore`, `ThumbnailService`,
  `QuickLookController`, `FileActionService`; agent runner + live-operation model in
  `Services/AgentDispatch` and `Services/Operations`.
- **Flow → "FlowVisor"** (`Modules/Flow`) — an activity-aware break coach. Derives a work/break
  state machine from ONE permissionless signal: seconds since the last user input
  (`CGEventSource.secondsSinceLastEventType`, content-blind, no TCC). At the configured work
  interval (default 60 min) of continuous work it peeks a nudge — but only at a micro-pause (≥10 s
  idle, so never mid-keystroke) and, when `flow.deferDuringMeetings` is on, only after any in-progress
  meeting ends (`FlowTracker` makes its own EventKit query reading **only** event start/end dates);
  dismissed meetings and all-day events do not defer nudges.
  Breaks are forgiving: ≥180 s away is a break and silently resets the clock, whether nudged or
  spontaneous — someone who naturally breaks never hears from it; a nudged break earns a brief
  "recharged" compact ack on return. The nudge presents as a banner carrying the heads-down message
  and a one-tap Take action — extending below the notch over a physical cutout, riding inside the
  widened pill on a screen without one; the banner holds (an indefinite peek,
  `requestPeek(.infinity)`) until Take / Snooze / Skip or a spontaneous break resolves it.
  Compact: a break countdown ring or the ack — nothing otherwise; a work session in progress has
  no pill presence at all (the banner is the only work-time surfacing).
  Expanded: Take 5 / Snooze 10 / Skip in the final stretch, and a *today*
  rhythm strip of the session-local work/break segments. Timer discipline per the idle-CPU rule: a
  single rearming deadline task fires only at the next real boundary (60 s sampler, tightening to
  5 s only while a nudge waits for a micro-pause) and is torn down entirely on screen lock / system
  sleep — that suspended time counts as break credit. Settings: `flow.workInterval` (45/60/90),
  `flow.breakLength` (3/5/10), `flow.deferDuringMeetings`.
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
  Attention stays quiet: a newly added entry raises a rotating brand-gradient glow around the
  notch, joins the flat sheet queue, and announces itself through the peek banner (Claude mark,
  session name, reason, one-tap Jump) — below the notch on a cutout screen, inline in the pill on
  a flat one. The toast lives exactly as long as the glow: it holds until the user opens the
  sheet or jumps to the terminal (either clears the glow) or the session leaves the queue, and
  the glow's clearing is the module's only signal that the user looked. There is no other pill
  presence and no attention count. Only a genuinely new session PID announces — an entry
  rewritten in place (a late tty, refreshed metadata) updates the toast where it stands.
  SwarmVisor's `order` of 15 puts its toast ahead of FlowVisor's break nudge when both want the
  banner. Opening the sheet or emptying the queue clears the glow, and an
  already-seen nonempty queue stays quiet until another entry is added. Queue rows (Claude-mark
  led) put blocked sessions first, then most-recent, and live until the session resumes or the
  user dismisses them. A validated tty teleports directly to the matching iTerm2 tab through
  AppleScript. `swarm.showMessages` (**default off**) gates session *content* — the question, the
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
  tracks state from the registry; it loses Jump, turn text, and failure reasons.
- **Battery** (`Modules/Battery`) — power/charging status, time remaining, and connected-device
  (Bluetooth accessory) battery; peeks on plug/unplug and low battery. (`PowerSourceMonitor`,
  `BluetoothMonitor`.)
- **Usage → "AI Usage"** (`Modules/Usage`) — Claude Code and Codex plan-quota runway as two
  tightly-stacked ticker rows at the bottom of the sheet (`CLAUDE 5h 62% · 7d 34% ↻ 4:30 PM`,
  colored by headroom: green < 70 %, amber < 90 %, red past it; chrome shared in
  `UI/UsageTickerRowView`). No compact/pill presence. One module (`AIUsageModule`) owns both
  monitors; each row gates on its own product's activity, and the section exists only while at
  least one row does.
  - **Claude row:** `QuotaMonitor` **watches** `~/.claude/agentpace/last-status.json` (the
    statusline capture the user's Claude Code statusline wrapper rewrites on every refresh)
    through `FileChangeWatcher` and re-parses only when the mtime actually moves; the
    `rate_limits` object carries `used_percentage`/`resets_at` per window. The row exists only
    while Claude Code is actively in use (file fresh within 10 min) **and** quota data is
    recent (30 min TTL) — quota is retained across payloads that omit `rate_limits`
    (desktop-bridge sessions do; terminal sessions carry it). Payload is parsed defensively per
    the untrusted-input convention. Freshness is wall-clock-derived, so when Claude Code stops
    writing, no file event will ever arrive: a **single timer** is armed for the soonest
    deadline that can still hide the row (and none at all once it is hidden), rather than a
    periodic tick that exists only to notice the absence of one.
  - **GPT row:** `CodexQuotaMonitor` uses a recursive FSEvents watcher over
    `~/.codex/sessions/` and reads only JSONL mtimes to determine whether Codex is active; it
    never opens transcript contents or auth files, and sessions crossing midnight or resumed
    from older date folders remain visible. While active, `CodexRateLimitClient` launches the
    installed `codex app-server`, performs its initialize handshake, and reads the supported
    `account/rateLimits/read` snapshot. Codex itself owns authentication and network access.
    The helper is reused across activity updates, throttled to one request per 5 seconds, and
    stopped when the same 10-minute activity window expires. Quota freshness uses the same
    30-minute TTL.

**`Modules/SystemHUD/`** (volume / brightness / keyboard-backlight HUD — `VolumeController`,
`BrightnessController`, `KeyboardBacklightController`, `MediaKeyMonitor`) is present but **NOT wired
into `ModuleRegistry`** — dead/unreferenced code kept for possible future use; nothing activates it
at runtime.

## Shared Services

- **`Services/Logging/`** — `AppLog` sends sparse lifecycle, state-transition, helper, and failure
  events to the unified log while `FileLogMirror` keeps a plain rotating file for direct
  inspection. Callers log only names, states, counts, durations, and error descriptions — never
  file, OCR, or clipboard content — and logging failures never throw or crash the app.
- **`Services/Attention/AttentionGlowCenter.swift`** — a module-agnostic one-shot attention signal
  read by the root view and cleared when the sheet opens.
- **`Services/FileSystem/FileChangeWatcher.swift`** — calls back when a file or directory is
  written, created, replaced, or removed. A vnode `DispatchSource` watches an open descriptor — an
  *inode*, not a path — so a writer that updates atomically (write temp, `rename` into place)
  leaves the watch pointing at the old unlinked inode and no later write is ever reported. The
  watcher therefore re-arms on `.rename`/`.delete`/`.revoke`, and watches the parent directory
  while the file is absent (so it may be started before the file exists). Callbacks are
  debounced, and fire on a private serial queue, not the main actor.
- **`Services/FileSystem/DirectoryTreeWatcher.swift`** — a recursive, debounced FSEvents watcher
  used for Codex's date-partitioned sessions tree and SwarmVisor's Claude session registry. It
  notices nested appends and in-place child rewrites with one stream, including an older Codex
  transcript resumed after its original date, without a discovery poll.
- **`Services/FileSystem/ThumbnailService.swift` + `QuickLookController.swift`** — shared local-file
  previews used by FileShelf. Thumbnail generation stays in Quick Look's service;
  the main actor only materializes the resulting `NSImage`.
- **SIGPIPE is ignored process-wide** (`AppDelegate.applicationDidFinishLaunching`). The app writes
  to pipes/sockets whose peer can vanish at any moment (codex app-server, the headless agent CLI,
  the perl now-playing adapter, hook clients on the swarm socket); the default signal action kills
  the process with **no crash report and no stderr**. With it ignored, such writes fail with EPIPE
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
  enabled flags (default on) and hover sensitivity.

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
  `agentDispatch`, `fileShelf`, `flow`) and mirrors notice/error lines to
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
  before concluding the app is alive.
- The swarm socket (`~/Library/Application Support/SuperVisor/agent-hooks.sock`) doubles as a
  liveness/timeline record: it exists iff an instance bound it and
  died uncleanly since; its mtime is the moment that instance's SwarmModule activated.

## Git

- Committing and pushing directly to this repo is fine — no need to ask first.
- **Don't create PRs for this repo.** When asked to ship changes, push to `main` directly.
- **Commit messages must not carry co-authorship or tooling trailers** — no `Co-Authored-By:`
  line and no `Claude-Session:` line. Keep the message to the change itself.
