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
/// - **Meeting Mode:** once a meeting with a join link is in progress, the compact pill instead
///   shows your live mic-mute state, and the expanded panel leads with a call HUD — elapsed
///   timer, a global mic-mute toggle, an audio-output switcher, and Join. If you muted via the
///   notch, the mic is automatically restored when the meeting ends.
///
/// Event data comes from `CalendarService` (EventKit); mic and output control come from
/// `MicController` / `AudioOutputController` (CoreAudio).
@MainActor
final class CalendarModule: NotchModule, ObservableObject {
    let moduleID = "calendar"
    let displayName = "Calendar"
    let order = 20

    let service = CalendarService()
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
        if let active {
            compactKey = "mtg:" + active.id
        } else if let event = service.relevantEvent(within: leadWindow, asOf: now) {
            compactKey = "soon:" + event.id
        } else {
            compactKey = nil
        }
        let expanded = service.isDenied || active != nil || !service.events.isEmpty

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

    // MARK: UI contributions

    func compactLeading() -> AnyView? {
        // In a meeting: show mute state. Otherwise: the countdown to the next meeting.
        if let active = service.activeMeeting() {
            return AnyView(MeetingMicChip(mic: mic, event: active))
        }
        if let event = service.relevantEvent(within: leadWindow) {
            return AnyView(CalendarCompactView(event: event))
        }
        return nil
    }

    func expandedSection() -> AnyView? {
        if service.isDenied {
            return AnyView(CalendarAccessPromptView())
        }
        guard service.activeMeeting() != nil || !service.events.isEmpty else { return nil }
        return AnyView(CalendarSection(
            service: service,
            mic: mic,
            audioOutput: audioOutput,
            onJoin: { [weak self] url in self?.join(url) },
            onToggleMute: { [weak self] in self?.toggleMute() }
        ))
    }
}
