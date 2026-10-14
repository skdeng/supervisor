import Foundation
import Testing

@testable import SuperVisor

/// Drives the Claude usage monitor through a real session registry on disk (this process's own
/// pid, so the liveness check passes) and a stand-in for the usage endpoint.
/// Serialized because each harness owns FSEvents streams over its own temp directory and the
/// suite's timing is tuned for one monitor at a time.
@MainActor
@Suite("Claude usage row", .serialized)
struct QuotaMonitorTests {
    // MARK: - Harness

    /// A stand-in for the usage endpoint whose answer a test can change mid-run.
    private final class Endpoint: @unchecked Sendable {
        private let lock = NSLock()
        private var _status = 200
        private var _body = Data()
        private var _requests = 0

        var status: Int {
            get { lock.lock(); defer { lock.unlock() }; return _status }
            set { lock.lock(); defer { lock.unlock() }; _status = newValue }
        }

        var body: Data {
            get { lock.lock(); defer { lock.unlock() }; return _body }
            set { lock.lock(); defer { lock.unlock() }; _body = newValue }
        }

        var requests: Int {
            lock.lock(); defer { lock.unlock() }; return _requests
        }

        func respond(to request: URLRequest) -> (Data, URLResponse) {
            lock.lock(); defer { lock.unlock() }
            _requests += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: _status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (_body, response)
        }
    }

    /// Endpoint and capture-file delays short enough to observe in a test; the activity
    /// window and quota TTL are set per test when they are what the test is about.
    private static func timing(
        activityWindow: TimeInterval = 60,
        quotaTTL: TimeInterval = 60,
        refreshInterval: TimeInterval = 60
    ) -> QuotaMonitor.Timing {
        var timing = QuotaMonitor.Timing()
        timing.activityWindow = activityWindow
        timing.quotaTTL = quotaTTL
        timing.requestCooldown = 0.05
        timing.refreshInterval = refreshInterval
        timing.retryDelay = 0.2
        timing.maxRetryDelay = 0.4
        return timing
    }

    @MainActor
    private final class Harness {
        let root: URL
        let registryURL: URL
        let captureURL: URL
        let endpoint = Endpoint()
        let monitor: QuotaMonitor
        let pid = ProcessInfo.processInfo.processIdentifier
        private(set) var presenceFlips = 0

        init(timing: QuotaMonitor.Timing = QuotaMonitorTests.timing(), credential: Data? = usableCredential) {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("usage-tests-\(UUID().uuidString)", isDirectory: true)
            registryURL = root.appendingPathComponent("sessions", isDirectory: true)
            captureURL = root.appendingPathComponent("last-status.json")
            try? FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: true)

            let endpoint = self.endpoint
            endpoint.body = endpointBody(fiveHour: 15, sevenDay: 13)
            let client = ClaudeUsageClient(
                readCredential: { credential },
                transport: { request in endpoint.respond(to: request) }
            )
            monitor = QuotaMonitor(
                sessionMonitor: ClaudeSessionMonitor(registryURL: registryURL),
                client: client,
                captureURL: captureURL,
                timing: timing
            )
            monitor.onPresenceChange = { [weak self] in self?.presenceFlips += 1 }
        }

        func tearDown() {
            monitor.stop()
            try? FileManager.default.removeItem(at: root)
        }

        /// Rewrites this process's registry record the way Claude Code does.
        func writeSession(status: String, statusUpdatedAt: Date = Date()) {
            let record: [String: Any] = [
                "pid": pid,
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "cwd": "/tmp/project",
                "kind": "interactive",
                "name": "test-session",
                "status": status,
                "statusUpdatedAt": Int(statusUpdatedAt.timeIntervalSince1970 * 1_000),
            ]
            let data = try! JSONSerialization.data(withJSONObject: record)
            try! data.write(to: registryURL.appendingPathComponent("\(pid).json"), options: .atomic)
        }

        /// Writes a statusline capture carrying `rate_limits`, optionally backdating its mtime.
        func writeCapture(fiveHour: Double, sevenDay: Double, mtime: Date? = nil) {
            let payload: [String: Any] = [
                "model": ["id": "claude-fable-5-1"],
                "rate_limits": [
                    "five_hour": ["used_percentage": fiveHour, "resets_at": 1_792_011_000],
                    "seven_day": ["used_percentage": sevenDay, "resets_at": 1_792_580_399],
                ],
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            try! data.write(to: captureURL, options: .atomic)
            if let mtime {
                try! FileManager.default.setAttributes(
                    [.modificationDate: mtime],
                    ofItemAtPath: captureURL.path
                )
            }
        }
    }

    private static let usableCredential = credential(
        scopes: ["user:inference", "user:profile"],
        expiresAt: Date().addingTimeInterval(3_600)
    )

    private static func credential(scopes: [String], expiresAt: Date?) -> Data {
        var oauth: [String: Any] = [
            "accessToken": "sk-ant-oat01-test",
            "refreshToken": "sk-ant-ort01-test",
            "scopes": scopes,
            "subscriptionType": "max",
        ]
        if let expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1_000)
        }
        return try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
    }

    /// The endpoint's body as observed live: percentages on a 0–100 scale, microsecond ISO
    /// 8601 reset times with a colon offset, `null` for windows the plan lacks, and fields the
    /// row does not use.
    private static func endpointBody(fiveHour: Double, sevenDay: Double, opus: Double? = nil) -> Data {
        let opusEntry = opus.map {
            #"{"utilization": \#($0), "resets_at": "2026-10-21T10:59:59.673181+00:00"}"#
        } ?? "null"
        return Data("""
        {
          "five_hour": {"utilization": \(fiveHour), "resets_at": "2026-10-14T20:50:00.672919+00:00",
                        "limit_dollars": null, "locked_reason": null},
          "seven_day": {"utilization": \(sevenDay), "resets_at": "2026-10-21T11:00:00.672949+00:00"},
          "seven_day_oauth_apps": null,
          "seven_day_opus": \(opusEntry),
          "seven_day_sonnet": null,
          "extra_usage": {"is_enabled": false, "utilization": null},
          "limits": [{"kind": "session", "percent": \(Int(fiveHour)), "severity": "normal"}]
        }
        """.utf8)
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

    // MARK: - Parsing

    @Test("The endpoint body parses into the Claude windows in display order")
    func endpointBodyParses() {
        let windows = ClaudeUsageClient.windows(from: Self.endpointBody(fiveHour: 15, sevenDay: 13))
        #expect(windows.map(\.label) == ["5h", "7d"])
        #expect(windows.map(\.usedPercentage) == [15, 13])
        #expect(abs(windows[0].resetsAt.timeIntervalSince1970 - 1_792_011_000.672919) < 0.001)
        #expect(abs(windows[1].resetsAt.timeIntervalSince1970 - 1_792_580_400.672949) < 0.001)

        let withOpus = ClaudeUsageClient.windows(from: Self.endpointBody(fiveHour: 15, sevenDay: 13, opus: 40))
        #expect(withOpus.map(\.label) == ["5h", "7d", "Opus"])
        #expect(withOpus[2].usedPercentage == 40)
    }

    @Test("Out-of-range percentages clamp and an unparsable reset time drops its window")
    func endpointBodyIsDefensive() {
        let body = Data("""
        {
          "five_hour": {"utilization": 250, "resets_at": "2026-11-05T07:59:00Z"},
          "seven_day": {"utilization": -5, "resets_at": "2026-10-21T11:00:00+00:00"},
          "seven_day_opus": {"utilization": 10, "resets_at": "next Tuesday"},
          "seven_day_sonnet": {"utilization": "12", "resets_at": "2026-10-21T11:00:00Z"}
        }
        """.utf8)
        let windows = ClaudeUsageClient.windows(from: body)
        #expect(windows.map(\.label) == ["5h", "7d"])
        #expect(windows.map(\.usedPercentage) == [100, 0])
        #expect(windows[0].resetsAt.timeIntervalSince1970 == 1_793_865_540)
        #expect(windows[1].resetsAt.timeIntervalSince1970 == 1_792_580_400)

        #expect(ClaudeUsageClient.windows(from: Data("[1, 2]".utf8)).isEmpty)
        #expect(ClaudeUsageClient.windows(from: Data("not json".utf8)).isEmpty)
    }

    @Test("The stored sign-in parses and gates on scope and expiry")
    func credentialParses() {
        let now = Date()
        let usable = ClaudeOAuthCredential.parse(Self.usableCredential)
        #expect(usable?.accessToken == "sk-ant-oat01-test")
        #expect(usable?.hasProfileScope == true)
        #expect(usable?.isExpired(at: now) == false)

        let unscoped = ClaudeOAuthCredential.parse(Self.credential(scopes: ["user:inference"], expiresAt: nil))
        #expect(unscoped?.hasProfileScope == false)
        #expect(unscoped?.isExpired(at: now) == false)

        let soon = ClaudeOAuthCredential.parse(
            Self.credential(scopes: ["user:profile"], expiresAt: now.addingTimeInterval(2 * 60))
        )
        #expect(soon?.isExpired(at: now) == true)

        let later = ClaudeOAuthCredential.parse(
            Self.credential(scopes: ["user:profile"], expiresAt: now.addingTimeInterval(10 * 60))
        )
        #expect(later?.isExpired(at: now) == false)

        #expect(ClaudeOAuthCredential.parse(Data("{}".utf8)) == nil)
        #expect(ClaudeOAuthCredential.parse(Data(#"{"claudeAiOauth": {"accessToken": ""}}"#.utf8)) == nil)
        #expect(ClaudeOAuthCredential.parse(Data("garbage".utf8)) == nil)
    }

    // MARK: - Presence

    @Test("A session mid-turn shows the row from the endpoint without any statusline capture")
    func busySessionShowsRow() async {
        let h = Harness()
        defer { h.tearDown() }
        h.writeSession(status: "busy")
        h.monitor.start()

        await waitUntil("row visible") { h.monitor.showsRow }
        #expect(h.monitor.isClaudeActive)
        #expect(h.monitor.quota?.windows.map(\.usedPercentage) == [15, 13])
        #expect(h.presenceFlips == 1)
        #expect(h.endpoint.requests == 1)
    }

    @Test("With no live session the endpoint is never read and a fresh capture shows no row")
    func noSessionNoRow() async {
        let h = Harness()
        defer { h.tearDown() }
        h.writeCapture(fiveHour: 60, sevenDay: 40)
        h.monitor.start()

        try? await Task.sleep(for: .milliseconds(400))
        // The capture was parsed; only the activity gate keeps the row hidden.
        #expect(h.monitor.quota?.windows.map(\.usedPercentage) == [60, 40])
        #expect(!h.monitor.showsRow)
        #expect(!h.monitor.isClaudeActive)
        #expect(h.endpoint.requests == 0)
        #expect(h.presenceFlips == 0)
    }

    @Test("An idle session counts as active only within the activity window")
    func idleSessionAgesOut() async {
        let h = Harness(timing: Self.timing(activityWindow: 3))
        defer { h.tearDown() }
        h.writeSession(status: "idle", statusUpdatedAt: Date().addingTimeInterval(-5))
        h.monitor.start()

        try? await Task.sleep(for: .milliseconds(400))
        #expect(!h.monitor.isClaudeActive)
        #expect(h.endpoint.requests == 0)

        // Half the window already spent: the row has ample time to appear before it lapses
        // 1.5 s from now, however loaded the machine.
        h.writeSession(status: "idle", statusUpdatedAt: Date().addingTimeInterval(-1.5))
        await waitUntil("row visible after a fresh status change") { h.monitor.showsRow }
        #expect(h.presenceFlips == 1)

        // The module hears about the flip through the callback, which the expiry timer fires;
        // `showsRow` itself turns false the instant the wall clock passes the deadline.
        await waitUntil("presence callback once the window lapses") { h.presenceFlips == 2 }
        #expect(!h.monitor.showsRow)
        #expect(!h.monitor.isClaudeActive)
    }

    @Test("Quota past its TTL hides the row even while a session stays busy")
    func staleQuotaHidesRow() async {
        let h = Harness(timing: Self.timing(quotaTTL: 0.5))
        defer { h.tearDown() }
        h.writeSession(status: "busy")
        h.monitor.start()

        await waitUntil("row visible") { h.monitor.showsRow }
        await waitUntil("presence callback once the quota ages out") { h.presenceFlips == 2 }
        #expect(!h.monitor.showsRow)
        #expect(h.monitor.isClaudeActive)
    }

    // MARK: - Sources

    @Test("The capture file stands in while the endpoint refuses the sign-in, and yields once it answers")
    func captureFallsBackThenEndpointWins() async {
        let h = Harness()
        defer { h.tearDown() }
        h.endpoint.status = 403
        h.writeCapture(fiveHour: 60, sevenDay: 40)
        h.writeSession(status: "busy")
        h.monitor.start()

        await waitUntil("row visible from the capture") { h.monitor.showsRow }
        #expect(h.monitor.quota?.windows.map(\.usedPercentage) == [60, 40])
        await waitUntil("endpoint attempted") { h.endpoint.requests >= 1 }

        h.endpoint.status = 200
        await waitUntil("endpoint snapshot replaces the capture") {
            h.monitor.quota?.windows.map(\.usedPercentage) == [15, 13]
        }
        #expect(h.monitor.showsRow)
    }

    @Test("A capture is ignored while the endpoint answers and applies once it fails")
    func captureIgnoredWhileEndpointProduces() async {
        let h = Harness()
        defer { h.tearDown() }
        h.writeSession(status: "busy")
        h.monitor.start()
        await waitUntil("row visible from the endpoint") {
            h.monitor.quota?.windows.map(\.usedPercentage) == [15, 13]
        }

        // Newer file, but the endpoint is producing: a statusline re-render carries the numbers
        // of that session's last API response, which may be older than the endpoint's.
        h.writeCapture(fiveHour: 60, sevenDay: 40)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(h.monitor.quota?.windows.map(\.usedPercentage) == [15, 13])

        h.endpoint.status = 500
        let before = h.endpoint.requests
        h.writeSession(status: "idle")
        await waitUntil("endpoint read failed") { h.endpoint.requests > before }
        try? await Task.sleep(for: .milliseconds(100))
        h.writeCapture(fiveHour: 70, sevenDay: 50)
        await waitUntil("capture applies once the endpoint fails") {
            h.monitor.quota?.windows.map(\.usedPercentage) == [70, 50]
        }
        #expect(h.monitor.showsRow)
    }

    @Test("Endpoint reads stop when activity lapses")
    func lapseCancelsEndpointWork() async {
        let h = Harness(timing: Self.timing(activityWindow: 0.8, refreshInterval: 0.2))
        defer { h.tearDown() }
        h.writeSession(status: "idle")
        h.monitor.start()

        await waitUntil("row visible") { h.monitor.showsRow }
        await waitUntil("presence callback once the window lapses") { h.presenceFlips == 2 }
        let settled = h.endpoint.requests
        try? await Task.sleep(for: .milliseconds(600))
        #expect(h.endpoint.requests == settled)
    }

    @Test("Failed reads back off instead of retrying at a fixed rate")
    func failuresBackOff() async {
        let h = Harness()
        defer { h.tearDown() }
        h.endpoint.status = 500
        h.writeSession(status: "busy")
        h.monitor.start()

        // Retries at 0.2 s, 0.4 s, 0.4 s, … after the first read: by 1.1 s that is four
        // reads at most, where a fixed 0.2 s cadence would have made six.
        await waitUntil("first read") { h.endpoint.requests >= 1 }
        try? await Task.sleep(for: .milliseconds(1_100))
        #expect(h.endpoint.requests >= 3)
        #expect(h.endpoint.requests <= 4)
        #expect(!h.monitor.showsRow)
    }

    @Test("A sign-in without the profile scope leaves the row to the capture file")
    func unscopedCredentialSkipsEndpoint() async {
        let h = Harness(credential: Self.credential(scopes: ["user:inference"], expiresAt: nil))
        defer { h.tearDown() }
        h.writeCapture(fiveHour: 60, sevenDay: 40)
        h.writeSession(status: "busy")
        h.monitor.start()

        await waitUntil("row visible from the capture") { h.monitor.showsRow }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(h.endpoint.requests == 0)
        #expect(h.monitor.quota?.windows.map(\.usedPercentage) == [60, 40])
    }
}
