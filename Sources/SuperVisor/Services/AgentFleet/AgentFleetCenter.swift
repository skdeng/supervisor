import Combine
import Foundation

/// Why a session is in the attention queue, most specific first.
///
/// `rank` orders them by how much they tell the user. A reason never replaces a
/// better-informed one for the same session: the idle notification arrives a minute after a
/// turn ends and carries a fixed string, so without that rule it would overwrite what the
/// session actually said.
enum AttentionReason: Equatable, Sendable {
    /// Stopped mid-turn on something the CLI is showing on screen, described in Claude Code's
    /// own words: `approve <ToolName>`, `worker request`, `sandbox request`, `dialog open`,
    /// or `input needed`.
    case waiting(detail: String)
    /// The turn ended abnormally. `error` is one of Claude Code's assistant-error cases —
    /// `rate_limit`, `billing_error`, `authentication_failed`, and the rest.
    case failed(error: String, details: String?)
    /// The turn ended with a question, so the final message is the thing to answer.
    case asked(question: String)
    /// The turn ended normally. `summary` is the final assistant message when one was captured.
    case finished(turnDuration: TimeInterval?, summary: String?)
    /// Idle at the prompt with nothing more specific known. It carries no text because the
    /// notification that raises it always sends the same fixed sentence, which says no more
    /// than the case itself does.
    case needsInput

    var rank: Int {
        switch self {
        case .failed: 4
        case .waiting: 3
        case .asked: 2
        case .finished: 1
        case .needsInput: 0
        }
    }

    /// Whether the session is stopped and cannot proceed without the user, as opposed to
    /// sitting at a prompt having finished its work.
    var isBlocking: Bool {
        switch self {
        case .waiting, .failed: true
        case .asked, .finished, .needsInput: false
        }
    }
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

/// A session mid-turn. It needs nothing from the user, so it carries no reason — only where it
/// is and how long it has been at it.
struct WorkingEntry: Identifiable, Equatable, Sendable {
    let sessionPID: Int32
    let name: String
    let cwd: String
    let tty: String?
    /// When the registry recorded the session turning busy.
    let since: Date

    var id: Int32 { sessionPID }
}

/// Merges authoritative registry snapshots with low-latency hook metadata.
@MainActor
final class AgentFleetCenter: ObservableObject {
    @Published private(set) var sessions: [FleetSession] = []
    @Published private(set) var ttyBySessionPID: [Int32: String] = [:]
    /// Sessions awaiting attention, most recent first: the session that stopped last is the one
    /// the user is most likely still thinking about.
    @Published private(set) var queue: [AttentionEntry] = []

    var workingCount: Int {
        sessions.lazy.filter { $0.status == .busy }.count
    }

    /// Every session the registry reports mid-turn, in registry order, carrying whatever tty a
    /// hook has validated for it.
    var workingSessions: [WorkingEntry] {
        sessions.compactMap { session in
            guard session.status == .busy else { return nil }
            return WorkingEntry(
                sessionPID: session.pid,
                name: session.name,
                cwd: session.cwd,
                tty: ttyBySessionPID[session.pid],
                since: session.statusUpdatedAt
            )
        }
    }

    private static let finishedThreshold: TimeInterval = 45

    private struct PendingInput {
        let sessionID: String
        let since: Date
    }

    private struct PendingFailure {
        let sessionID: String
        let error: String
        let details: String?
        let since: Date
    }

    /// The final assistant message of a turn, captured from the Stop hook before the registry
    /// records the session leaving `busy`.
    private struct TurnOutcome {
        let sessionID: String
        let message: String
    }

    private let monitor: ClaudeSessionMonitor
    private let eventSocket: AgentEventSocket
    private var sessionSubscription: AnyCancellable?
    private var lastBusyStart: [Int32: Date] = [:]
    private var pendingInput: [Int32: PendingInput] = [:]
    private var pendingFailure: [Int32: PendingFailure] = [:]
    private var turnOutcome: [Int32: TurnOutcome] = [:]
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
        pendingFailure = [:]
        turnOutcome = [:]
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
        pendingFailure = pendingFailure.filter { livePIDs.contains($0.key) }
        turnOutcome = turnOutcome.filter { livePIDs.contains($0.key) }
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
            // A new turn invalidates what the previous one ended with, so a stale message can
            // never attach to the next stop.
            turnOutcome[session.pid] = nil
            pendingFailure[session.pid] = nil

        case .waiting:
            lastBusyStart[session.pid] = nil
            // A session blocked on a prompt cannot proceed at all, so it enters regardless of
            // how long the turn ran — the turn-length threshold exists to keep quick *finished*
            // turns quiet, which is a different situation.
            if let detail = session.waitingFor {
                upsert(
                    session: session,
                    reason: .waiting(detail: detail),
                    since: session.statusUpdatedAt
                )
            } else {
                settleStopped(session, previous: previous)
            }

        case .idle:
            settleStopped(session, previous: previous)
            lastBusyStart[session.pid] = nil
        }
    }

    /// Resolves a session that has stopped, preferring the best-informed reason available: a
    /// recorded failure, then what the turn actually ended by saying, then the bare fact that
    /// the prompt is idle.
    private func settleStopped(_ session: FleetSession, previous: FleetSession?) {
        if let failure = pendingFailure[session.pid],
           failure.sessionID == session.sessionID {
            pendingFailure[session.pid] = nil
            upsert(
                session: session,
                reason: .failed(error: failure.error, details: failure.details),
                since: failure.since
            )
            return
        }

        var didUpsert = false

        if previous?.status == .busy {
            let startedAt = lastBusyStart[session.pid]
                ?? previous?.statusUpdatedAt
                ?? session.statusUpdatedAt
            let duration = session.statusUpdatedAt.timeIntervalSince(startedAt)
            if duration >= Self.finishedThreshold {
                upsert(
                    session: session,
                    reason: outcomeReason(for: session, turnDuration: duration)
                        ?? .finished(turnDuration: duration, summary: nil),
                    since: session.statusUpdatedAt
                )
                didUpsert = true
            }
        }

        if let pending = pendingInput[session.pid] {
            pendingInput[session.pid] = nil
            guard pending.sessionID == session.sessionID else { return }
            // The idle notification's own message is a fixed string, so what the turn ended by
            // saying is preferred whenever it was captured.
            upsert(
                session: session,
                reason: outcomeReason(for: session, turnDuration: nil) ?? .needsInput,
                since: pending.since
            )
        } else if !didUpsert {
            refreshQueuedMetadata(for: session)
        }
    }

    /// The reason implied by the final assistant message of the session's last turn, when one
    /// was captured. A trailing question mark is what separates a question the user has to
    /// answer from a report they only have to read.
    private func outcomeReason(
        for session: FleetSession,
        turnDuration: TimeInterval?
    ) -> AttentionReason? {
        guard let outcome = turnOutcome[session.pid],
              outcome.sessionID == session.sessionID
        else { return nil }

        if outcome.message.hasSuffix("?") {
            return .asked(question: outcome.message)
        }
        return .finished(turnDuration: turnDuration, summary: outcome.message)
    }

    private func receive(_ event: FleetHookEvent) {
        guard isRunning else { return }

        if let tty = event.tty, Self.isValidTTY(tty) {
            ttyBySessionPID[event.pid] = tty
            refreshQueuedTTY(for: event.pid, tty: tty)
        }

        if let message = Self.displayMessage(event.lastAssistantMessage) {
            turnOutcome[event.pid] = TurnOutcome(
                sessionID: event.sessionID,
                message: message
            )
        }

        if event.event == "StopFailure", let error = Self.displayMessage(event.error) {
            let failure = PendingFailure(
                sessionID: event.sessionID,
                error: error,
                details: Self.displayMessage(event.errorDetails),
                since: Date()
            )
            pendingFailure[event.pid] = failure

            if let session = liveSession(for: event, requiringStopped: true) {
                pendingFailure[event.pid] = nil
                upsert(
                    session: session,
                    reason: .failed(error: failure.error, details: failure.details),
                    since: failure.since
                )
            }
        }

        if event.event == "Notification", event.notificationType == "idle_prompt" {
            let pending = PendingInput(
                sessionID: event.sessionID,
                since: Date()
            )
            pendingInput[event.pid] = pending

            if let session = liveSession(for: event, requiringStopped: true) {
                pendingInput[event.pid] = nil
                upsert(
                    session: session,
                    reason: outcomeReason(for: session, turnDuration: nil) ?? .needsInput,
                    since: pending.since
                )
            }
        }

        monitor.refreshSoon()
    }

    private func liveSession(
        for event: FleetHookEvent,
        requiringStopped: Bool
    ) -> FleetSession? {
        sessions.first {
            $0.pid == event.pid
                && $0.sessionID == event.sessionID
                && (!requiringStopped || $0.status != .busy)
        }
    }

    private func upsert(
        session: FleetSession,
        reason: AttentionReason,
        since: Date
    ) {
        if let index = queue.firstIndex(where: { $0.sessionPID == session.pid }) {
            let current = queue[index]
            // A less specific reason leaves the entry — including its age — exactly as it
            // stands, so a late generic notification cannot erase a specific one.
            guard reason.rank >= current.reason.rank else {
                refreshQueuedMetadata(for: session)
                return
            }
            let entry = AttentionEntry(
                sessionPID: session.pid,
                name: session.name,
                cwd: session.cwd,
                tty: ttyBySessionPID[session.pid],
                reason: reason,
                since: reason.rank > current.reason.rank ? since : current.since
            )
            if queue[index] != entry {
                queue[index] = entry
            }
            return
        }

        let entry = AttentionEntry(
            sessionPID: session.pid,
            name: session.name,
            cwd: session.cwd,
            tty: ttyBySessionPID[session.pid],
            reason: reason,
            since: since
        )
        queue.append(entry)
        // An entry rewritten in place keeps its `since`, so ordering only needs restoring
        // where one enters — a hook event can surface a session that stopped before one
        // already queued.
        queue.sort { $0.since > $1.since }
        AttentionGlowCenter.shared.raise()
        AppLog.notice(
            .swarm,
            "attention added \(entry.name) reason \(Self.logDescription(reason)) count \(queue.count)"
        )
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
        pendingFailure[pid] = nil
        turnOutcome[pid] = nil
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

    /// Bounds and single-lines text that originates outside the app. The hook truncates first;
    /// this covers any other local writer to the socket.
    static func displayMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let stripped = collapsed.filter { character in
            character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard !stripped.isEmpty else { return nil }
        return String(stripped.prefix(400))
    }

    /// Names the reason without reproducing session content, which never reaches the log.
    private static func logDescription(_ reason: AttentionReason) -> String {
        switch reason {
        case let .waiting(detail):
            "waiting \(detail)"
        case let .failed(error, _):
            "failed \(error)"
        case .asked:
            "asked"
        case let .finished(turnDuration, _):
            turnDuration.map { "finished \(Int($0.rounded()))s" } ?? "finished"
        case .needsInput:
            "needs input"
        }
    }
}
