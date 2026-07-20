import AppKit
import Combine
import SwiftUI

/// Calendar module — surfaces the next meeting in the notch, lets you join it, and powers
/// **Meeting Mode** while a meeting is in progress.
///
/// - **Upcoming:** while the next timed meeting is ongoing or starts within the lead window, a
///   countdown chip appears in the compact pill (`12m` → `1m` → `Now`), and the expanded panel
///   lists upcoming meetings, each with a one-tap **Join** button when a Zoom / Meet / Teams /
///   Webex link is detected.
/// - **Meeting Mode:** once a meeting with a join link is in progress, the expanded panel leads
///   with a call HUD — elapsed timer, a global mic-mute toggle, an audio-output switcher, and
///   Join. If you muted via the notch, the mic is automatically restored when the meeting ends.
///
/// Event data comes from `CalendarService` (EventKit); mic and output control come from
/// `MicController` / `AudioOutputController` (CoreAudio).
@MainActor
final class CalendarModule: NotchModule, ObservableObject {
    let moduleID = "calendar"
    let displayName = "Calendar"
    let order = 20

    let service = CalendarService()
    let dismissals = MeetingDismissalStore.shared
    private let mic = MicController()
    private let audioOutput = AudioOutputController()

    private var context: NotchContext?
    private var cancellables: Set<AnyCancellable> = []
    private var tickTask: Task<Void, Never>?

    /// Surface the compact countdown when the next meeting is ongoing or starts within this.
    private let leadWindow: TimeInterval = 25 * 60

    /// Identity-tagged key of the current compact contribution (countdown event vs. meeting),
    /// so the pill re-lays-out on appear/disappear AND on hand-off (one meeting to the next, or
    /// upcoming → in-meeting). Paired with the expanded contribution's presence.
    private var lastCompactKey: String?
    private var hadExpanded = false

    /// Meeting-end mic restoration: whether a meeting was active last evaluation, and whether
    /// the current mute was applied by us (so we only auto-unmute a mute we initiated).
    private var wasInMeeting = false
    private var weMuted = false

    // MARK: NotchModule lifecycle

    func activate(_ context: NotchContext) {
        self.context = context
        service.start()
        mic.start()
        audioOutput.start()

        // `@Published` emits during willSet, so hop to the next main-queue turn before reading
        // back the service's state — otherwise syncContributions() would observe the PREVIOUS
        // events array and a calendar-change-driven pill update would operate on stale data.
        service.$events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncContributions() }
            .store(in: &cancellables)
        service.$authorization
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncContributions() }
            .store(in: &cancellables)
        // Any unmute — ours, the user's in another app, or hardware — relinquishes our claim,
        // so meeting-end auto-restore only ever undoes a mute we still own.
        mic.$isMuted
            .sink { [weak self] muted in if !muted { self?.weMuted = false } }
            .store(in: &cancellables)

        // Periodic tick: refresh data (roll off ended events) and re-evaluate the
        // time-dependent surfacing as the clock advances toward / into a meeting.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.handleTick()
            }
        }

        syncContributions()
    }

    func deactivate() {
        tickTask?.cancel()
        tickTask = nil
        cancellables.removeAll()
        // Don't leave the mic muted behind us if Meeting Mode muted it.
        if weMuted && mic.isMuted { mic.setMuted(false) }
        mic.stop()
        audioOutput.stop()
        service.stop()
        context = nil
    }

    private func handleTick() {
        service.reload()
        syncContributions()
    }

    // MARK: Contribution bookkeeping

    /// Re-evaluate which contributions are present and nudge the engine only when that changes.
    /// Also restores the mic when a meeting we muted for has ended.
    private func syncContributions() {
        let now = Date()
        let active = service.activeMeeting(asOf: now)
        restoreMicIfMeetingEnded(active: active)

        let compactKey: String?
        if active != nil {
            compactKey = nil
        } else if let event = service.relevantEvent(within: leadWindow, asOf: now) {
            compactKey = "soon:" + event.id
        } else {
            compactKey = nil
        }
        let expanded = service.isDenied || active != nil || !service.events.isEmpty
            || !dismissals.dismissed.isEmpty

        if compactKey != lastCompactKey || expanded != hadExpanded {
            lastCompactKey = compactKey
            hadExpanded = expanded
            context?.setNeedsCompactRefresh()
        }
    }

    /// When a meeting we muted for ends, undo our mute so the mic isn't left silenced. Only acts
    /// on a mute we applied (not one the user set in hardware / another app).
    private func restoreMicIfMeetingEnded(active: CalendarEvent?) {
        let inMeeting = active != nil
        defer { wasInMeeting = inMeeting }
        if inMeeting && !wasInMeeting {
            weMuted = false                       // fresh meeting; forget prior bookkeeping
        }
        if wasInMeeting && !inMeeting && weMuted && mic.isMuted {
            mic.setMuted(false)
            weMuted = false
        }
    }

    // MARK: Actions

    private func join(_ url: URL) {
        // The URL originates from attacker-controllable calendar fields; re-check the scheme
        // allowlist at the point of opening (defense in depth) so no unsafe scheme is ever
        // handed to NSWorkspace, whatever path produced this URL.
        guard MeetingLink.isAllowed(url) else { return }
        NSWorkspace.shared.open(url)
        context?.requestCollapse()
    }

    private func toggleMute() {
        mic.toggleMute()
        weMuted = mic.isMuted
    }

    private func dismiss(_ event: CalendarEvent) {
        dismissals.dismiss(
            id: event.id,
            title: event.title,
            start: event.start,
            end: event.end
        )
        service.reload()
        syncContributions()
    }

    private func restore(_ id: String) {
        dismissals.restore(id)
        service.reload()
        syncContributions()
    }

    // MARK: UI contributions

    func compactLeading() -> AnyView? {
        // Once a meeting begins, macOS already surfaces microphone activity in the menu bar.
        // Keep the pill quiet and reserve the mic state/control for the expanded Meeting HUD.
        if service.activeMeeting() != nil { return nil }
        if let event = service.relevantEvent(within: leadWindow) {
            return AnyView(CalendarCompactView(event: event))
        }
        return nil
    }

    func expandedSection() -> AnyView? {
        if service.isDenied {
            return AnyView(CalendarAccessPromptView())
        }
        guard service.activeMeeting() != nil || !service.events.isEmpty
            || !dismissals.dismissed.isEmpty else { return nil }
        return AnyView(CalendarSection(
            service: service,
            dismissals: dismissals,
            mic: mic,
            audioOutput: audioOutput,
            onJoin: { [weak self] url in self?.join(url) },
            onToggleMute: { [weak self] in self?.toggleMute() },
            onDismiss: { [weak self] event in self?.dismiss(event) },
            onRestore: { [weak self] id in self?.restore(id) }
        ))
    }
}
