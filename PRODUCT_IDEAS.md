# SuperVisor Product Ideas

This document collects potential product directions for SuperVisor. The goal is not to turn the
notch into a generic widget drawer. The strongest features should make the surface feel like the
Mac's ambient action layer:

> Something happens → the notch reacts → one gesture reveals the right action → the result
> resolves back into the notch.

Ideas should ideally combine three qualities:

1. **System awareness** — SuperVisor notices relevant state without manual setup.
2. **Direct manipulation** — people can drag, click, speak, or otherwise act through the notch.
3. **A visible transformation** — the compact and expanded states create a memorable demo moment.

## Opportunity Map

| Idea | Demo wow | Product fit | Relative effort | Suggested priority |
| --- | --- | --- | --- | --- |
| SuperDrop | Very high | Very high | Medium | Next flagship |
| Meeting Ready Room | Very high | Very high | Medium–high | High |
| CueVisor | Very high | Very high | Medium | High |
| ProgressVisor | High | High | Medium–high | High |
| VoiceVisor | Very high | High | High | Later |
| ShareGuard | High | Very high | Medium–high | High |
| Focus Scenes | High | High | Medium | Medium |
| Notch Clipboard | High | High | Medium | Medium |
| Arrival Cards | High | High | Low–medium | Medium |
| DynaKeys | High | Very high | Low; mostly built | Quick win |

## 1. SuperDrop

Evolve ClipVisor from a file shelf into a universal drop portal. The user drops an object onto the
notch, SuperVisor identifies it, and the expanded surface offers actions appropriate to that
object.

### Example actions

- **Images:** resize, change format, compress, extract text, remove a background, or stage for
  drag-out.
- **Files and folders:** zip, rename, AirDrop, Quick Look, or hold temporarily.
- **URLs:** generate a QR code, save for later, copy a cleaned link, or open on another device.
- **Text:** translate, rewrite, summarize, create a reminder, or generate a text file.
- **Calendar invitations:** extract the meeting link, create a reminder, or prepare a Ready Room.

### Signature interaction

The notch magnetically accepts the dragged object, briefly shows its recognized type, and morphs
into a compact action tray. Longer operations collapse into ProgressVisor and leave the result
available for drag-out.

### Product value

This is the broadest flagship opportunity because it is tactile, understandable in a short demo,
and builds directly on ClipVisor's existing drag destination, staging model, thumbnails, Quick
Look, AirDrop, and compression services.

### Important constraints

- Treat every dropped filename, URL, and text payload as untrusted.
- Keep destructive or lossy operations explicit.
- Avoid an overwhelming action list; rank a small set by detected content type.
- Prefer local processing and clearly label actions that require a network service.

## 2. Meeting Ready Room

Shortly before a meeting, the notch wakes up and offers a preflight surface directly beneath the
MacBook camera.

### Proposed experience

- Camera preview and framing check.
- Microphone input level and selected device.
- Speaker/output selection and test.
- Join countdown and one-tap Join.
- Optional appearance or lighting check.
- A clear handoff into the existing Meeting Mode when the meeting begins.

### Signature interaction

The physical camera sits inside the interaction. A small pre-meeting pulse expands into a visual
and audio check, then the same surface becomes the live call HUD.

### Important constraints

- Camera preview requires clear permission and privacy messaging.
- Do not duplicate macOS's persistent microphone privacy indicator in compact mode.
- Starting a preview must be deliberate enough that it never surprises the user.
- Handle meetings with no recognized join link gracefully.

## 3. CueVisor

Presenter notes and timing positioned near the camera lens, where reading causes less visible eye
movement than notes elsewhere on the display.

### Proposed experience

- Paste or import a short list of talking points.
- Show one concise cue at a time beside or below the camera.
- Advance with a global shortcut, presentation clicker, or expanded-panel control.
- Display elapsed time, time remaining, and the next cue.
- Optionally keep a small “questions to revisit” parking lot during a call.

### Signature interaction

The notch becomes a restrained presenter strip that keeps the speaker's gaze close to the camera.
The expanded panel manages the full cue list; compact mode shows only the current prompt or timing.

### Important constraints

- Avoid a dense teleprompter that blocks menu-bar content or distracts the presenter.
- Global shortcuts and clicker input may require Accessibility permission.
- Keep notes local by default.

## 4. ProgressVisor

A unified live-activity surface for work currently in flight across SuperVisor and, where reliable
system APIs allow it, other apps.

### Candidate activities

- SuperDrop conversions and image processing.
- Compression and archive creation.
- AirDrop or transfer progress.
- Large file copies, downloads, or exports.
- Long-running Codex or Claude tasks.
- Timers and scheduled actions.

### Signature interaction

Several operations collapse into a tiny stack or progress ring beside the notch. Hovering or
clicking reveals status and cancellation controls. Completion produces a subtle pulse and leaves
the result draggable from the notch.

### Product value

ProgressVisor provides shared infrastructure for many other ideas. Rather than each module
inventing its own busy/completion UI, operations become consistent live activities.

### Important constraints

- Only show progress that can be measured honestly.
- Cancellation must reflect the underlying operation's real capabilities.
- Completed items need automatic expiry so the notch does not become a permanent task list.

## 5. VoiceVisor

Hold a configurable key and speak a short command grounded in the current context.

### Example commands

- “Remind me about this tomorrow.”
- “Mute my microphone.”
- “Start a 20-minute focus session.”
- “Send this screenshot to my phone.”
- “Rewrite the selected text more concisely.”
- “Zip these files.”

### Signature interaction

The notch becomes a live waveform while the key is held, resolves the speech into a concise intent,
shows the proposed action, and then performs it or asks for confirmation when needed.

### Product value

VoiceVisor becomes compelling when it orchestrates mature SuperVisor actions. A generic chat box
would feel bolted on; short commands acting on selected text, staged files, the current meeting, or
the latest screenshot would feel native.

### Important constraints

- Make recording state unmistakable.
- Require confirmation for destructive, external, or ambiguous actions.
- Define clear local/cloud speech and AI privacy behavior.
- Build this after the underlying action system is reusable across modules.

## 6. ShareGuard

A persistent privacy and control surface while the Mac is sharing or recording its screen.

### Proposed experience

- Indicate when screen sharing or recording is active.
- Show whether a display, window, or region is being shared when detectable.
- Offer a prominent Stop Sharing action.
- Surface mute and output controls without duplicating the macOS privacy indicators.
- Optionally suppress notification previews or warn when sensitive content enters the shared area.

### Signature interaction

Starting a share creates a calm, unmistakable notch state. The controls remain one click away in
full-screen presentations where menu-bar navigation is inconvenient.

### Important constraints

- Detection and stop controls vary by conferencing app and public system API.
- Never imply that sharing stopped unless the underlying session confirms it.
- Sensitive-content detection must remain conservative and privacy-preserving.

## 7. Focus Scenes

One action configures the Mac for a recurring context such as a meeting, presentation, recording,
deep work, or travel.

### A scene could configure

- Focus mode.
- Audio input and output devices.
- Microphone mute state.
- Display brightness.
- A timer or scheduled end.
- A set of apps, links, or documents to open.

### Signature interaction

Selecting a scene causes each setting to resolve as a compact sequence around the notch, then
collapses into a small active-scene indicator with time remaining.

### Important constraints

- Every changed setting needs understandable restoration behavior.
- Some settings may lack stable public write APIs.
- Scenes should expose exactly what they will change before activation.

## 8. Notch Clipboard

A temporary, visual clipboard history designed around drag-out rather than a large history window.

### Proposed experience

- Recently copied text, links, images, and files appear as small cards.
- Drag an item directly into another app.
- Pin intentionally retained items.
- Search or filter only when the expanded list grows.
- Send an image or file into SuperDrop actions.

### Signature interaction

A copy briefly echoes into the notch. Clicking reveals a handful of recent, visually distinct
items ready to drag back into the current workflow.

### Important constraints

- Passwords, one-time codes, and other sensitive clipboard types should be excluded or expire
  immediately.
- Set a small default history limit and automatic expiry.
- Clipboard monitoring should be transparent and independently disableable.

## 9. Arrival Cards

Replace passive connection and power status changes with polished, actionable peeks.

### Candidate events

- AirPods, headphones, keyboards, mice, or controllers connect.
- A charger is attached or removed.
- An external display appears.
- An accessory reaches low battery.
- Audio output automatically changes.

### Signature interaction

The connected device slides into the pill with its name, icon, and battery. Clicking reveals the
one or two actions that matter, such as switching output, opening battery details, or restoring the
previous route.

### Product value

Arrival Cards are lower effort because Battery and audio services already observe much of the
required state. They can significantly improve the sense that SuperVisor is aware of the whole
Mac.

## 10. DynaKeys

Move volume, display brightness, and keyboard-backlight feedback into the notch.

### Current state

Most of DynaKeys already exists under `Modules/SystemHUD/`, including controllers, media-key
observation, compact level peeks, and expanded sliders. It is intentionally not registered in
`ModuleRegistry`.

### Recommended polish before enabling

- Compare its timing and visibility with the native macOS HUD.
- Decide whether to complement or attempt to replace native feedback.
- Validate brightness behavior with auto-brightness and multiple displays.
- Validate keyboard-backlight availability across Mac models.
- Ensure global media-key monitoring degrades gracefully without Accessibility permission.

This is the best quick win, but it is a quality multiplier rather than the next flagship.

## Recommended Roadmap

### Phase 1: tighten the ambient layer

1. Polish and enable DynaKeys.
2. Add Arrival Cards using existing battery and audio observers.
3. Establish a shared live-operation model for progress, completion, cancellation, and expiry.

### Phase 2: build the next flagship

1. Expand ClipVisor into SuperDrop.
2. Route long-running SuperDrop actions through ProgressVisor.
3. Let CaptureVisor hand screenshots into the same image-action pipeline.

### Phase 3: own meetings and presentations

1. Build Meeting Ready Room on top of Calendar and shared audio services.
2. Add CueVisor as a closely related presentation mode.
3. Explore ShareGuard where reliable detection and control are possible.

### Phase 4: orchestration

1. Add Focus Scenes once system actions have consistent restoration semantics.
2. Add VoiceVisor after SuperDrop, scenes, reminders, meetings, and media expose reusable actions.

## Ideas to Deprioritize

Useful features such as a generic weather tile, calculator, unit converter, ordinary timer list,
or notification history can be added later, but they should not drive the product roadmap. On
their own they make SuperVisor feel like widgets placed inside the notch rather than a surface
that notices events and helps complete cross-app actions.

## Evaluation Checklist

Before promoting an idea into implementation, answer:

- What is the five-second demo?
- Why does this belong at the notch instead of in a menu-bar popover?
- What causes the compact contribution to appear and disappear?
- What is the primary action in the expanded surface?
- Does the feature reuse or strengthen another module?
- What permissions or private APIs does it require?
- What external input is untrusted, and where is it validated?
- What happens when the feature is unavailable, denied, interrupted, or disabled?
- How does temporary state expire or restore itself?
- Does the feature reduce friction, or merely display more information?
