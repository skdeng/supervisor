import Combine
import Foundation

enum AttentionReason: Equatable, Sendable {
    case finished(turnDuration: TimeInterval)
    case needsInput(message: String?)
}

struct AttentionEntry: Identifiable, Equatable, Sendable {
    let sessionPID: Int32
    let name: String
    let cwd: String
    let tty: String?
    let reason: AttentionReason
    let since: Date

    var id: Int32 { sessionPID }
}

/// Merges authoritative registry snapshots with low-latency hook metadata.
@MainActor
final class AgentFleetCenter: ObservableObject {
    @Published private(set) var sessions: [FleetSession] = []
    @Published private(set) var ttyBySessionPID: [Int32: String] = [:]
    @Published private(set) var queue: [AttentionEntry] = []

    var workingCount: Int {
        sessions.lazy.filter { $0.status == .busy }.count
    }

    private static let finishedThreshold: TimeInterval = 45

    private struct PendingInput {
        let sessionID: String
        let message: String?
        let since: Date
    }

    private let monitor: ClaudeSessionMonitor
    private let eventSocket: AgentEventSocket
    private var sessionSubscription: AnyCancellable?
    private var lastBusyStart: [Int32: Date] = [:]
    private var pendingInput: [Int32: PendingInput] = [:]
    private var isRunning = false

    init(monitor: ClaudeSessionMonitor, eventSocket: AgentEventSocket) {
        self.monitor = monitor
        self.eventSocket = eventSocket
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        sessionSubscription = monitor.$sessions.sink { [weak self] sessions in
            self?.receive(sessions)
        }
        eventSocket.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionSubscription?.cancel()
        sessionSubscription = nil
        eventSocket.onEvent = nil
        sessions = []
        ttyBySessionPID = [:]
        for pid in queue.map(\.sessionPID) {
            removeQueuedEntry(for: pid)
        }
        lastBusyStart = [:]
        pendingInput = [:]
    }

    func dismiss(_ pid: Int32) {
        removeQueuedEntry(for: pid)
    }

    private func receive(_ nextSessions: [FleetSession]) {
        guard isRunning else { return }
        let previousByPID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
        let nextByPID = Dictionary(uniqueKeysWithValues: nextSessions.map { ($0.pid, $0) })
        let vanishedPIDs = Set(previousByPID.keys).subtracting(nextByPID.keys)

        for pid in vanishedPIDs {
            removeState(for: pid)
        }

        for session in nextSessions {
            let previous = previousByPID[session.pid]
            if let previous, previous.sessionID != session.sessionID {
                removeState(for: session.pid)
            }

            let sameSessionPrevious = previous?.sessionID == session.sessionID ? previous : nil
            reconcile(
                session,
                previous: sameSessionPrevious
            )
        }

        sessions = nextSessions
        let livePIDs = Set(nextByPID.keys)
        ttyBySessionPID = ttyBySessionPID.filter { livePIDs.contains($0.key) }
        let staleQueuedPIDs = queue.map(\.sessionPID).filter { !livePIDs.contains($0) }
        for pid in staleQueuedPIDs {
            removeQueuedEntry(for: pid)
        }
        pendingInput = pendingInput.filter { livePIDs.contains($0.key) }
    }

    private func reconcile(_ session: FleetSession, previous: FleetSession?) {
        switch session.status {
        case .busy:
            if previous?.status != .busy {
                lastBusyStart[session.pid] = session.statusUpdatedAt
            }
            removeQueuedEntry(for: session.pid)

            if let pending = pendingInput[session.pid],
               pending.sessionID != session.sessionID
                    || session.statusUpdatedAt >= pending.since {
                pendingInput[session.pid] = nil
            }

        case .idle, .waiting:
            if previous?.status == .busy {
                let startedAt = lastBusyStart[session.pid]
                    ?? previous?.statusUpdatedAt
                    ?? session.statusUpdatedAt
                let duration = session.statusUpdatedAt.timeIntervalSince(startedAt)
                if duration >= Self.finishedThreshold {
                    upsert(
                        session: session,
                        reason: .finished(turnDuration: duration),
                        since: session.statusUpdatedAt
                    )
                }
            }
            lastBusyStart[session.pid] = nil

            if let pending = pendingInput[session.pid] {
                pendingInput[session.pid] = nil
                guard pending.sessionID == session.sessionID else { break }
                upsert(
                    session: session,
                    reason: .needsInput(message: pending.message),
                    since: pending.since
                )
            } else {
                refreshQueuedMetadata(for: session)
            }
        }
    }

    private func receive(_ event: FleetHookEvent) {
        guard isRunning else { return }

        if let tty = event.tty, Self.isValidTTY(tty) {
            ttyBySessionPID[event.pid] = tty
            refreshQueuedTTY(for: event.pid, tty: tty)
        }

        if event.event == "Notification",
           event.notificationType == "idle_prompt"
                || event.notificationType == "agent_needs_input" {
            let pending = PendingInput(
                sessionID: event.sessionID,
                message: Self.displayMessage(event.message),
                since: Date()
            )
            pendingInput[event.pid] = pending

            if let session = sessions.first(where: {
                $0.pid == event.pid
                    && $0.sessionID == event.sessionID
                    && $0.status != .busy
            }) {
                pendingInput[event.pid] = nil
                upsert(
                    session: session,
                    reason: .needsInput(message: pending.message),
                    since: pending.since
                )
            }
        }

        monitor.refreshSoon()
    }

    private func upsert(
        session: FleetSession,
        reason: AttentionReason,
        since: Date
    ) {
        let entry = AttentionEntry(
            sessionPID: session.pid,
            name: session.name,
            cwd: session.cwd,
            tty: ttyBySessionPID[session.pid],
            reason: reason,
            since: since
        )
        if let index = queue.firstIndex(where: { $0.sessionPID == session.pid }) {
            if queue[index] != entry {
                queue[index] = entry
            }
        } else {
            queue.append(entry)
            AttentionGlowCenter.shared.raise()
            AppLog.notice(
                .swarm,
                "attention added \(entry.name) reason \(Self.logDescription(reason)) count \(queue.count)"
            )
        }
    }

    private func refreshQueuedMetadata(for session: FleetSession) {
        guard let index = queue.firstIndex(where: { $0.sessionPID == session.pid }) else {
            return
        }
        let current = queue[index]
        let refreshed = AttentionEntry(
            sessionPID: session.pid,
            name: session.name,
            cwd: session.cwd,
            tty: ttyBySessionPID[session.pid],
            reason: current.reason,
            since: current.since
        )
        if refreshed != current {
            queue[index] = refreshed
        }
    }

    private func refreshQueuedTTY(for pid: Int32, tty: String) {
        guard let index = queue.firstIndex(where: { $0.sessionPID == pid }) else { return }
        let current = queue[index]
        guard current.tty != tty else { return }
        queue[index] = AttentionEntry(
            sessionPID: current.sessionPID,
            name: current.name,
            cwd: current.cwd,
            tty: tty,
            reason: current.reason,
            since: current.since
        )
    }

    private func removeState(for pid: Int32) {
        removeQueuedEntry(for: pid)
        ttyBySessionPID[pid] = nil
        lastBusyStart[pid] = nil
        pendingInput[pid] = nil
    }

    private func removeQueuedEntry(for pid: Int32) {
        guard let entry = queue.first(where: { $0.sessionPID == pid }) else { return }
        queue.removeAll { $0.sessionPID == pid }
        if queue.isEmpty {
            AttentionGlowCenter.shared.clear()
        }
        AppLog.notice(
            .swarm,
            "attention removed \(entry.name) reason \(Self.logDescription(entry.reason)) count \(queue.count)"
        )
    }

    static func isValidTTY(_ tty: String) -> Bool {
        tty.range(
            of: #"^/dev/ttys[0-9]+$"#,
            options: .regularExpression
        ) != nil
    }

    private static func displayMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(200))
    }

    private static func logDescription(_ reason: AttentionReason) -> String {
        switch reason {
        case let .finished(turnDuration):
            "finished \(Int(turnDuration.rounded()))s"
        case .needsInput:
            "needs input"
        }
    }
}
