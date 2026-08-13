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
///   Join. Camera or microphone use raises the same controls for an unscheduled call. If you
///   muted via the notch, the mic is automatically restored when the call context ends.
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
    private let callMonitor = CallActivityMonitor.shared

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

    /// Call-end mic restoration: whether a scheduled or detected call was active at the last
    /// evaluation, and whether the current mute was applied by this module.
    private var wasInCallContext = false
    private var weMuted = false

    // MARK: NotchModule lifecycle

    func activate(_ context: NotchContext) {
        self.context = context
        service.start()
        mic.start()
        audioOutput.start()
        callMonitor.retain()

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
        Publishers.CombineLatest(
            callMonitor.$isCameraInUse,
            callMonitor.$isMicInUse
        )
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
        wasInCallContext = false
        weMuted = false
        SectionUrgencyCenter.shared.set(false, for: moduleID)
        mic.stop()
        audioOutput.stop()
        callMonitor.release()
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
        let adHocCallActive = active == nil && callMonitor.isCallLikely
        let inCallContext = active != nil || adHocCallActive
        restoreMicIfCallEnded(inCallContext: inCallContext)

        // A call in progress floats this section to the top of the sheet: the mic toggle and
        // Join are what the sheet is being opened for.
        SectionUrgencyCenter.shared.set(inCallContext, for: moduleID)

        let compactKey: String?
        if active != nil {
            compactKey = nil
        } else if let event = service.relevantEvent(within: leadWindow, asOf: now) {
            compactKey = "soon:" + event.id
        } else {
            compactKey = nil
        }
        let expanded = service.isDenied || active != nil || adHocCallActive || !service.events.isEmpty
            || !dismissals.dismissed.isEmpty

        if compactKey != lastCompactKey || expanded != hadExpanded {
            lastCompactKey = compactKey
            hadExpanded = expanded
            context?.setNeedsCompactRefresh()
        }
    }

    /// Undo a mute owned by this module when the scheduled or detected call context ends.
    private func restoreMicIfCallEnded(inCallContext: Bool) {
        defer { wasInCallContext = inCallContext }
        if inCallContext && !wasInCallContext {
            weMuted = false
        }
        if wasInCallContext && !inCallContext && weMuted && mic.isMuted {
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
        let active = service.activeMeeting()
        let adHocCallStartedAt = active == nil && callMonitor.isCallLikely
            ? callMonitor.callStartedAt
            : nil
        guard service.isDenied || active != nil || adHocCallStartedAt != nil || !service.events.isEmpty
            || !dismissals.dismissed.isEmpty else { return nil }
        return AnyView(CalendarSection(
            service: service,
            dismissals: dismissals,
            mic: mic,
            audioOutput: audioOutput,
            callMonitor: callMonitor,
            onJoin: { [weak self] url in self?.join(url) },
            onToggleMute: { [weak self] in self?.toggleMute() },
            onDismiss: { [weak self] event in self?.dismiss(event) },
            onRestore: { [weak self] id in self?.restore(id) }
        ))
    }
}
