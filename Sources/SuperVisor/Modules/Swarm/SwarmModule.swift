import Combine
import SwiftUI

/// SwarmVisor stays absent until an interactive agent session needs attention.
@MainActor
final class SwarmModule: NotchModule {
    let moduleID = "swarm"
    let displayName = "SwarmVisor"
    let order = 15

    private let sessionMonitor: ClaudeSessionMonitor
    private let eventSocket: AgentEventSocket
    private let fleetCenter: AgentFleetCenter
    private let terminalTeleport = TerminalTeleport()

    private var context: NotchContext?
    private var queueSubscription: AnyCancellable?
    private var sessionsSubscription: AnyCancellable?
    private var expandedPresence = false

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
        // Attention is deliberately quiet: a new queue entry raises only the attention glow
        // (the fleet center's doing) and a sheet row — never a peek banner or pill presence.
        queueSubscription = fleetCenter.$queue.sink { [weak self] _ in
            self?.reconcileExpandedPresence()
        }
        sessionsSubscription = fleetCenter.$sessions.sink { [weak self] _ in
            self?.reconcileExpandedPresence()
        }

        // Hooks can begin waiting for a permission decision at any time, so the listener is
        // established before registry discovery starts.
        eventSocket.start()
        sessionMonitor.start()
    }

    func deactivate() {
        guard let context else { return }
        let hadExpandedSection = expandedPresence

        queueSubscription?.cancel()
        queueSubscription = nil
        sessionsSubscription?.cancel()
        sessionsSubscription = nil
        eventSocket.stop()
        sessionMonitor.stop()
        fleetCenter.stop()

        expandedPresence = false
        if hadExpandedSection {
            context.setNeedsCompactRefresh()
        }
        self.context = nil
    }

    func expandedSection() -> AnyView? {
        guard !fleetCenter.queue.isEmpty || fleetCenter.workingCount > 0 else { return nil }
        return AnyView(
            SwarmExpandedView(
                center: fleetCenter,
                terminalTeleport: terminalTeleport
            )
        )
    }

    private func reconcileExpandedPresence() {
        let isPresent = !fleetCenter.queue.isEmpty || fleetCenter.workingCount > 0
        guard isPresent != expandedPresence else { return }
        expandedPresence = isPresent
        context?.setNeedsCompactRefresh()
    }
}
