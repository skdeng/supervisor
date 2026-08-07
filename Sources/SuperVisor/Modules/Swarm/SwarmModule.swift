import Combine
import SwiftUI

/// SwarmVisor stays absent until an interactive agent session needs attention.
@MainActor
final class SwarmModule: NotchModule, ObservableObject {
    let moduleID = "swarm"
    let displayName = "SwarmVisor"
    let order = 15

    /// The entry the peek banner is currently announcing.
    @Published private(set) var announcedEntry: AttentionEntry?

    private let sessionMonitor: ClaudeSessionMonitor
    private let eventSocket: AgentEventSocket
    private let fleetCenter: AgentFleetCenter
    private let terminalTeleport = TerminalTeleport()

    private var context: NotchContext?
    private var queueSubscription: AnyCancellable?
    private var sessionsSubscription: AnyCancellable?
    private var glowSubscription: AnyCancellable?
    private var expandedPresence = false
    /// The queue's PIDs as of the previous emission, so an emission can be split into sessions
    /// that just entered the queue and entries that were rewritten where they stood.
    private var queuedPIDs: Set<Int32> = []

    init() {
        let sessionMonitor = ClaudeSessionMonitor()
        let eventSocket = AgentEventSocket()
        self.sessionMonitor = sessionMonitor
        self.eventSocket = eventSocket
        fleetCenter = AgentFleetCenter(
            monitor: sessionMonitor,
            eventSocket: eventSocket
        )
    }

    func activate(_ context: NotchContext) {
        guard self.context == nil else { return }
        self.context = context
        expandedPresence = !fleetCenter.queue.isEmpty || fleetCenter.workingCount > 0

        fleetCenter.start()
        // Attention stays quiet: a new queue entry raises the attention glow (the fleet center's
        // doing), joins the sheet queue, and announces itself through a banner that holds until
        // the attention is acknowledged — no pill presence outlives the glow.
        queueSubscription = fleetCenter.$queue.sink { [weak self] queue in
            self?.receive(queue: queue)
        }
        sessionsSubscription = fleetCenter.$sessions.sink { [weak self] _ in
            self?.reconcileExpandedPresence()
        }
        // The toast lives exactly as long as the glow: both are renderings of the same
        // unresolved-attention state, and the glow is what the root view clears when the user
        // opens the sheet. Its clearing is the module's only signal that the user looked.
        glowSubscription = AttentionGlowCenter.shared.$isRaised.sink { [weak self] raised in
            if !raised {
                self?.retireAnnouncement()
            }
        }

        // Hooks can begin waiting for a permission decision at any time, so the listener is
        // established before registry discovery starts.
        eventSocket.start()
        sessionMonitor.start()
    }

    func deactivate() {
        guard let context else { return }
        let hadExpandedSection = expandedPresence
        let wasAnnouncing = announcedEntry != nil

        queueSubscription?.cancel()
        queueSubscription = nil
        sessionsSubscription?.cancel()
        sessionsSubscription = nil
        glowSubscription?.cancel()
        glowSubscription = nil
        eventSocket.stop()
        sessionMonitor.stop()
        fleetCenter.stop()

        announcedEntry = nil
        queuedPIDs = []
        expandedPresence = false
        if hadExpandedSection {
            context.setNeedsCompactRefresh()
        }
        // An announcement in flight holds the surface indefinitely; the hold has to be released
        // before the context goes, or it pins the resting state to `.compact` for good.
        if wasAnnouncing {
            context.requestPeek(0)
        }
        self.context = nil
    }

    func expandedSection() -> AnyView? {
        guard !fleetCenter.queue.isEmpty || fleetCenter.workingCount > 0 else { return nil }
        return AnyView(
            SwarmExpandedView(
                center: fleetCenter,
                settings: SettingsStore.shared,
                terminalTeleport: terminalTeleport
            )
        )
    }

    /// The toast a session raises on entering the queue.
    ///
    /// Module `order` resolves a collision between two banners, and SwarmVisor's 15 deliberately
    /// precedes FlowVisor's 100: a session blocked right now outranks a break nudge. The nudge
    /// keeps its own indefinite hold while it is covered and returns once this toast retires.
    func peekBanner() -> AnyView? {
        guard announcedEntry != nil else { return nil }
        return AnyView(SwarmPeekBannerView(module: self, settings: SettingsStore.shared))
    }

    /// Teleports to the session's terminal and acknowledges the attention: the glow clears, and
    /// the toast retires with it. The queue entry stays: it is cleared only by the session
    /// resuming or by an explicit dismissal, exactly as when Jump is pressed on the sheet row.
    func jump(toTTY tty: String) {
        terminalTeleport.teleport(toTTY: tty)
        AttentionGlowCenter.shared.clear()
        retireAnnouncement()
    }

    /// Splits an emission into sessions that just entered the queue and entries rewritten in
    /// place, so late-arriving metadata — a tty landing after the hook event, a refreshed name or
    /// cwd — updates the toast rather than raising a second one for the same session. When
    /// several enter at once the most recent announces, which the queue's ordering puts first.
    private func receive(queue: [AttentionEntry]) {
        let currentPIDs = Set(queue.map(\.sessionPID))
        let addedPIDs = currentPIDs.subtracting(queuedPIDs)
        queuedPIDs = currentPIDs

        if let newest = queue.first(where: { addedPIDs.contains($0.sessionPID) }) {
            announce(newest)
        } else if let announced = announcedEntry {
            if let refreshed = queue.first(where: { $0.sessionPID == announced.sessionPID }) {
                if refreshed != announced {
                    announcedEntry = refreshed
                }
            } else {
                // The session resumed, was dismissed, or vanished — a toast must not outlive
                // the need that raised it.
                retireAnnouncement()
            }
        }

        reconcileExpandedPresence()
    }

    /// Presents `entry`, replacing whatever the banner already shows, and holds the surface with
    /// an indefinite peek. `retireAnnouncement` is the single exit, reached when the user opens
    /// the sheet (the glow clearing), jumps to the terminal, the session leaves the queue, or the
    /// module deactivates.
    private func announce(_ entry: AttentionEntry) {
        announcedEntry = entry
        context?.requestPeek(.infinity)
        // With another module's banner already holding the peek, the request publishes no engine
        // change at all — the refresh is what makes the root view re-pick the banner slot's
        // winner, or this toast never appears over a held nudge.
        context?.setNeedsCompactRefresh()
    }

    /// Withdraws the banner, then releases the hold — in that order, so the engine's release path
    /// no longer counts this module's banner as an unresolved hold.
    private func retireAnnouncement() {
        guard announcedEntry != nil else { return }
        announcedEntry = nil
        context?.requestPeek(0)
        // A release that hands the hold to a surviving banner publishes no engine change; the
        // refresh hands the banner slot back explicitly.
        context?.setNeedsCompactRefresh()
    }

    private func reconcileExpandedPresence() {
        let isPresent = !fleetCenter.queue.isEmpty || fleetCenter.workingCount > 0
        guard isPresent != expandedPresence else { return }
        expandedPresence = isPresent
        context?.setNeedsCompactRefresh()
    }
}
