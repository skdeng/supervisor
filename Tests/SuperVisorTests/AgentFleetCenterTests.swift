import Foundation
import Testing

@testable import SuperVisor

/// Drives the fleet center through a real session registry on disk, using this process's own
/// pid so the liveness check passes.
@MainActor
@Suite("Attention queue")
struct AgentFleetCenterTests {
    // MARK: - Harness

    private final class Harness {
        let registryURL: URL
        let monitor: ClaudeSessionMonitor
        let socket: AgentEventSocket
        let center: AgentFleetCenter
        let pid = ProcessInfo.processInfo.processIdentifier
        let sessionID = "11111111-2222-3333-4444-555555555555"

        @MainActor
        init() {
            registryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("swarm-tests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: registryURL,
                withIntermediateDirectories: true
            )
            monitor = ClaudeSessionMonitor(registryURL: registryURL)
            socket = AgentEventSocket(
                socketPath: registryURL.appendingPathComponent("unused.sock").path
            )
            center = AgentFleetCenter(monitor: monitor, eventSocket: socket)
        }

        @MainActor
        func start() {
            center.start()
            monitor.start()
        }

        @MainActor
        func tearDown() {
            monitor.stop()
            center.stop()
            try? FileManager.default.removeItem(at: registryURL)
        }

        /// Rewrites the session's registry record. `waitingFor` is written only when present,
        /// matching Claude Code, which omits the key outside the waiting status.
        func write(
            status: String,
            statusUpdatedAt: Date,
            waitingFor: String? = nil,
            name: String = "test-session"
        ) {
            var record: [String: Any] = [
                "pid": pid,
                "sessionId": sessionID,
                "cwd": "/tmp/project",
                "kind": "interactive",
                "name": name,
                "status": status,
                "statusUpdatedAt": Int(statusUpdatedAt.timeIntervalSince1970 * 1_000),
            ]
            if let waitingFor {
                record["waitingFor"] = waitingFor
            }
            let data = try! JSONSerialization.data(withJSONObject: record)
            try! data.write(
                to: registryURL.appendingPathComponent("\(pid).json"),
                options: .atomic
            )
        }

        @MainActor
        func send(
            event: String,
            lastAssistantMessage: String? = nil,
            notificationType: String? = nil,
            error: String? = nil
        ) {
            socket.onEvent?(
                FleetHookEvent(
                    sessionID: sessionID,
                    cwd: "/tmp/project",
                    event: event,
                    pid: pid,
                    tty: "/dev/ttys004",
                    status: .waitingForInput,
                    notificationType: notificationType,
                    message: notificationType == "idle_prompt"
                        ? "Claude is waiting for your input"
                        : nil,
                    lastAssistantMessage: lastAssistantMessage,
                    error: error,
                    errorDetails: nil
                )
            )
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(description)")
    }

    // MARK: - Tests

    @Test("A finished turn enters the queue naming how long it ran")
    func finishedTurnEnters() async {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.write(status: "busy", statusUpdatedAt: Date().addingTimeInterval(-120))
        harness.start()
        await waitUntil("the busy session to load") { !harness.center.sessions.isEmpty }
        #expect(harness.center.queue.isEmpty, "a busy session needs no attention")

        harness.write(status: "idle", statusUpdatedAt: Date())
        harness.monitor.refreshSoon()
        await waitUntil("the finished turn to queue") { !harness.center.queue.isEmpty }

        guard case let .finished(turnDuration, summary) = harness.center.queue[0].reason else {
            Issue.record("expected a finished reason, got \(harness.center.queue[0].reason)")
            return
        }
        #expect(turnDuration ?? 0 >= 100)
        #expect(summary == nil, "no Stop hook fired, so no closing message was captured")
    }

    @Test("The idle notification never replaces what the turn actually said")
    func idleNotificationDoesNotDowngrade() async {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.write(status: "busy", statusUpdatedAt: Date().addingTimeInterval(-120))
        harness.start()
        await waitUntil("the busy session to load") { !harness.center.sessions.isEmpty }

        harness.send(event: "Stop", lastAssistantMessage: "Tests pass and the build is clean.")
        harness.write(status: "idle", statusUpdatedAt: Date())
        harness.monitor.refreshSoon()
        await waitUntil("the finished turn to queue") { !harness.center.queue.isEmpty }

        let queuedAt = harness.center.queue[0].since
        guard case let .finished(_, summary) = harness.center.queue[0].reason else {
            Issue.record("expected a finished reason, got \(harness.center.queue[0].reason)")
            return
        }
        #expect(summary == "Tests pass and the build is clean.")

        // The idle notification arrives a minute later carrying only a fixed sentence.
        harness.send(event: "Notification", notificationType: "idle_prompt")
        try? await Task.sleep(for: .milliseconds(300))

        guard case let .finished(_, stillSummary) = harness.center.queue[0].reason else {
            Issue.record("the closing summary was replaced by the generic notification")
            return
        }
        #expect(stillSummary == "Tests pass and the build is clean.")
        #expect(harness.center.queue[0].since == queuedAt, "the row's age must not restart")
    }

    @Test("A turn ending in a question is distinguished from one ending in a report")
    func questionIsDetected() async {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.write(status: "busy", statusUpdatedAt: Date().addingTimeInterval(-120))
        harness.start()
        await waitUntil("the busy session to load") { !harness.center.sessions.isEmpty }

        harness.send(
            event: "Stop",
            lastAssistantMessage: "Which auth approach do you want?"
        )
        harness.write(status: "idle", statusUpdatedAt: Date())
        harness.monitor.refreshSoon()
        await waitUntil("the question to queue") { !harness.center.queue.isEmpty }

        #expect(
            harness.center.queue[0].reason == .asked(question: "Which auth approach do you want?")
        )
    }

    @Test("A session blocked on approval enters immediately, however short the turn")
    func waitingEntersRegardlessOfTurnLength() async {
        let harness = Harness()
        defer { harness.tearDown() }

        // One second of work — far below the threshold a finished turn must clear.
        harness.write(status: "busy", statusUpdatedAt: Date().addingTimeInterval(-1))
        harness.start()
        await waitUntil("the busy session to load") { !harness.center.sessions.isEmpty }

        harness.write(status: "waiting", statusUpdatedAt: Date(), waitingFor: "approve Bash")
        harness.monitor.refreshSoon()
        await waitUntil("the blocked session to queue") { !harness.center.queue.isEmpty }

        #expect(harness.center.queue[0].reason == .waiting(detail: "approve Bash"))
        #expect(harness.center.queue[0].reason.isBlocking)
    }

    @Test("A failed turn outranks every other reason for the same session")
    func failureOutranksFinished() async {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.write(status: "busy", statusUpdatedAt: Date().addingTimeInterval(-120))
        harness.start()
        await waitUntil("the busy session to load") { !harness.center.sessions.isEmpty }

        harness.send(event: "Stop", lastAssistantMessage: "Partial work done.")
        harness.write(status: "idle", statusUpdatedAt: Date())
        harness.monitor.refreshSoon()
        await waitUntil("the finished turn to queue") { !harness.center.queue.isEmpty }

        harness.send(event: "StopFailure", error: "rate_limit")
        await waitUntil("the failure to take over") {
            if case .failed = harness.center.queue.first?.reason { return true }
            return false
        }

        #expect(harness.center.queue[0].reason == .failed(error: "rate_limit", details: nil))
    }

    @Test("Resuming a session clears its attention entry")
    func resumingClearsTheEntry() async {
        let harness = Harness()
        defer { harness.tearDown() }

        harness.write(status: "busy", statusUpdatedAt: Date().addingTimeInterval(-120))
        harness.start()
        await waitUntil("the busy session to load") { !harness.center.sessions.isEmpty }

        harness.write(status: "idle", statusUpdatedAt: Date())
        harness.monitor.refreshSoon()
        await waitUntil("the finished turn to queue") { !harness.center.queue.isEmpty }

        harness.write(status: "busy", statusUpdatedAt: Date())
        harness.monitor.refreshSoon()
        await waitUntil("the entry to clear") { harness.center.queue.isEmpty }

        #expect(harness.center.queue.isEmpty)
    }
}
