import Combine
import Foundation

/// Claude Code plan-quota state for the AI Usage row, gated on Claude Code being in use.
///
/// **Activity** comes from Claude Code's session registry (`~/.claude/sessions`), which every
/// host writes — a terminal, the desktop app, an editor's terminal. Claude Code counts as in
/// use while any live session is mid-turn or changed status within `Timing.activityWindow`.
///
/// **Quota** comes from the endpoint, with the statusline capture as a stand-in:
/// - `ClaudeUsageClient` reads the account's windows from the usage endpoint while Claude is
///   active: on becoming active, after each registry change (a turn ending is what moves the
///   numbers) no more often than `Timing.requestCooldown`, and `Timing.refreshInterval` after
///   each successful read through a long turn. A failed read retries with exponential backoff
///   from `Timing.retryDelay` up to `Timing.maxRetryDelay`, and registry-change reads wait for
///   that backoff too, so a revoked sign-in costs a handful of requests an hour.
/// - The statusline capture file (`~/.claude/agentpace/last-status.json`, which the user's
///   statusline wrapper rewrites with the statusline's stdin JSON on every refresh) is watched,
///   and its `rate_limits` object — the same windows — applies **only while the endpoint is
///   not producing**: its last read failed, or it has no snapshot within the quota TTL. A
///   statusline re-render carries the numbers of that session's last API response, so a
///   capture with a newer mtime can still hold older numbers than a live endpoint read; while
///   the endpoint answers, the capture is ignored. Only an interactive terminal session renders
///   a statusline; the desktop app drives the CLI headless, so this source alone never sees
///   desktop use. The file is external input: size-capped, parsed defensively, unknown fields
///   ignored.
///
/// Freshness is wall-clock-derived: when Claude Code stops, no registry or file event will
/// ever arrive, yet the row still has to disappear. A single timer is armed for the next
/// instant a deadline lapses, re-armed on each change, instead of a periodic tick that exists
/// only to notice the absence of one.
///
/// All state is main-actor; the module observes `showsRow` presence flips through
/// `onPresenceChange`.
@MainActor
final class QuotaMonitor: ObservableObject {
    typealias Window = UsageTickerWindow

    struct Snapshot: Equatable {
        let windows: [Window]
        /// When the windows were observed: the endpoint read's completion, or the capture
        /// file's mtime. Never in the future.
        let capturedAt: Date
    }

    struct Timing: Sendable {
        /// A session whose status changed within this is "Claude Code is actively being used";
        /// a session mid-turn is active regardless.
        var activityWindow: TimeInterval = 10 * 60
        /// Quota older than this is hidden rather than shown wrong.
        var quotaTTL: TimeInterval = 30 * 60
        /// Minimum spacing between endpoint reads triggered by registry changes.
        var requestCooldown: TimeInterval = 60
        /// Spacing of endpoint reads while active with no registry change in between.
        var refreshInterval: TimeInterval = 5 * 60
        /// Delay before the endpoint is retried after the first failed read; each consecutive
        /// failure doubles it.
        var retryDelay: TimeInterval = 60
        /// Ceiling on the doubled retry delay.
        var maxRetryDelay: TimeInterval = 15 * 60

        static let standard = Timing()
    }

    /// The most recent quota data seen from either source.
    @Published private(set) var quota: Snapshot?
    /// Whether any Claude Code session is mid-turn or changed status recently.
    @Published private(set) var isClaudeActive = false

    /// Called (on the main actor) whenever `showsRow` flips, so the module can ask the
    /// engine to re-lay-out the sheet.
    var onPresenceChange: (() -> Void)?

    /// The row exists only while Claude Code is actively in use and the quota data is recent
    /// enough to trust.
    var showsRow: Bool {
        guard isClaudeActive, let quota else { return false }
        return Date().timeIntervalSince(quota.capturedAt) < timing.quotaTTL
    }

    /// Sanity cap on the capture payload read — the real file is ~1 KB.
    private static let maxPayloadBytes = 1 << 20

    static let defaultCaptureURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agentpace/last-status.json")

    private let sessionMonitor: ClaudeSessionMonitor
    private let client: ClaudeUsageClient
    private let captureURL: URL
    private let timing: Timing

    init(
        sessionMonitor: ClaudeSessionMonitor = ClaudeSessionMonitor(),
        client: ClaudeUsageClient = ClaudeUsageClient(),
        captureURL: URL = QuotaMonitor.defaultCaptureURL,
        timing: Timing = .standard
    ) {
        self.sessionMonitor = sessionMonitor
        self.client = client
        self.captureURL = captureURL
        self.timing = timing
    }

    private var isRunning = false
    private var sessionSubscription: AnyCancellable?
    private var captureWatcher: FileChangeWatcher?
    /// Mtime of the capture payload last parsed, so an unchanged file is never re-read.
    private var lastReadCaptureMtime: Date?
    private var hasBusySession = false
    /// The newest status change across live sessions; `nil` when there are none.
    private var latestStatusChange: Date?
    private var lastRequestAt: Date?
    /// Completion time of the last successful endpoint read; `nil` until one succeeds.
    private var endpointCapturedAt: Date?
    private var lastUnavailableReason: String?
    private var consecutiveFailures = 0
    /// Earliest instant the next endpoint read may start, set by the retry backoff.
    private var nextRequestAllowedAt: Date?
    private var hadRow = false
    private var expiry: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        client.onSnapshot = { [weak self] windows in
            self?.receiveEndpoint(windows)
        }
        client.onUnavailable = { [weak self] reason in
            self?.endpointUnavailable(reason)
        }

        let captureWatcher = FileChangeWatcher(url: captureURL) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshCapture()
                }
            }
        }
        self.captureWatcher = captureWatcher
        captureWatcher.start()
        refreshCapture()

        sessionSubscription = sessionMonitor.$sessions.sink { [weak self] sessions in
            self?.receive(sessions)
        }
        sessionMonitor.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionSubscription?.cancel()
        sessionSubscription = nil
        sessionMonitor.stop()
        captureWatcher?.stop()
        captureWatcher = nil
        cancelEndpointWork()
        client.onSnapshot = nil
        client.onUnavailable = nil
        expiry?.cancel()
        expiry = nil
        lastReadCaptureMtime = nil
        hasBusySession = false
        latestStatusChange = nil
        endpointCapturedAt = nil
        lastUnavailableReason = nil
        consecutiveFailures = 0
        nextRequestAllowedAt = nil
        isClaudeActive = false
        hadRow = false
    }

    // MARK: - Activity

    private func receive(_ sessions: [FleetSession]) {
        guard isRunning else { return }
        // A registry timestamp ahead of the wall clock would hold the row open until the clock
        // caught up; it is read as "just now" instead.
        let now = Date()
        hasBusySession = sessions.contains { $0.status == .busy }
        latestStatusChange = sessions.map { min($0.statusUpdatedAt, now) }.max()

        updatePresence()
        if isClaudeActive { requestQuotaSoon() }
        scheduleExpiry()
    }

    /// Recompute the time-derived state and tell the module if the row appeared or vanished.
    private func updatePresence() {
        let recentChange = latestStatusChange.map {
            Date().timeIntervalSince($0) < timing.activityWindow
        } ?? false
        let active = hasBusySession || recentChange
        if active != isClaudeActive {
            isClaudeActive = active
        }
        if !active {
            cancelEndpointWork()
        }

        let has = showsRow
        if has != hadRow {
            hadRow = has
            AppLog.debug(.usage, "usage claude row -> \(has ? "visible" : "hidden")")
            onPresenceChange?()
        }
    }

    // MARK: - Endpoint quota

    private func requestQuotaSoon() {
        guard isRunning, isClaudeActive else { return }

        requestTask?.cancel()
        let now = Date()
        let elapsed = lastRequestAt.map { now.timeIntervalSince($0) } ?? .infinity
        let backoff = nextRequestAllowedAt.map { $0.timeIntervalSince(now) } ?? 0
        let delay = max(0, timing.requestCooldown - elapsed, backoff)
        requestTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled, self.isRunning, self.isClaudeActive else { return }
            self.lastRequestAt = Date()
            self.client.requestSnapshot()
        }
    }

    /// An endpoint read is the account's current state and always replaces what is shown.
    private func receiveEndpoint(_ windows: [Window]) {
        guard isRunning, !windows.isEmpty else { return }
        if lastUnavailableReason != nil {
            lastUnavailableReason = nil
            AppLog.notice(.usage, "usage endpoint readable again")
        }
        consecutiveFailures = 0
        nextRequestAllowedAt = nil
        let now = Date()
        endpointCapturedAt = now
        apply(Snapshot(windows: windows, capturedAt: now))
        scheduleRefresh()
    }

    /// A failure is logged when its reason changes, so a sign-in that cannot use the endpoint
    /// is reported once rather than on every retry.
    private func endpointUnavailable(_ reason: String) {
        guard isRunning else { return }
        if reason != lastUnavailableReason {
            lastUnavailableReason = reason
            AppLog.error(.usage, "usage endpoint unavailable: \(reason)")
        }
        consecutiveFailures += 1
        let exponent = min(consecutiveFailures - 1, 16)
        let delay = min(timing.retryDelay * pow(2, Double(exponent)), timing.maxRetryDelay)
        nextRequestAllowedAt = Date().addingTimeInterval(delay)
        scheduleRetry(after: delay)
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        guard isRunning, isClaudeActive else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.timing.refreshInterval ?? 0))
            guard let self, !Task.isCancelled, self.isRunning, self.isClaudeActive else { return }
            self.lastRequestAt = Date()
            self.client.requestSnapshot()
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        guard isRunning, isClaudeActive else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.isRunning, self.isClaudeActive else { return }
            self.lastRequestAt = Date()
            self.client.requestSnapshot()
        }
    }

    private func cancelEndpointWork() {
        requestTask?.cancel()
        requestTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        retryTask?.cancel()
        retryTask = nil
        client.stop()
        lastRequestAt = nil
    }

    // MARK: - Capture-file quota

    /// Re-stat the capture file and re-parse it if it actually changed.
    private func refreshCapture() {
        guard isRunning else { return }
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: captureURL.path)[.modificationDate]) as? Date

        guard let mtime else {
            lastReadCaptureMtime = nil
            return
        }
        guard mtime != lastReadCaptureMtime else { return }
        lastReadCaptureMtime = mtime
        if let windows = readCaptureWindows(), !windows.isEmpty {
            receiveCapture(Snapshot(windows: windows, capturedAt: min(mtime, Date())))
        }
    }

    /// Parse `rate_limits` out of the capture file. Returns `nil` on any read/shape problem
    /// (missing file, oversized, not JSON, no usable windows) — never throws, never trusts.
    private func readCaptureWindows() -> [Window]? {
        guard let data = try? Data(contentsOf: captureURL),
              data.count <= Self.maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        var windows: [Window] = []
        for (key, label) in Window.claudeWindowKeys {
            guard let entry = limits[key] as? [String: Any],
                  let used = (entry["used_percentage"] as? NSNumber)?.doubleValue,
                  used.isFinite,
                  let resets = (entry["resets_at"] as? NSNumber)?.doubleValue,
                  resets.isFinite, resets > 0
            else { continue }
            windows.append(Window(
                label: label,
                usedPercentage: min(max(used, 0), 100),
                resetsAt: Date(timeIntervalSince1970: resets)
            ))
        }
        return windows
    }

    /// The capture stands in only while the endpoint is not producing, and then only when it
    /// is newer than what is shown.
    private func receiveCapture(_ snapshot: Snapshot) {
        guard !endpointIsProducing else { return }
        if let quota, quota.capturedAt > snapshot.capturedAt { return }
        apply(snapshot)
    }

    /// Whether the endpoint's last read succeeded and its snapshot is still within the TTL.
    private var endpointIsProducing: Bool {
        guard lastUnavailableReason == nil, let endpointCapturedAt else { return false }
        return Date().timeIntervalSince(endpointCapturedAt) < timing.quotaTTL
    }

    // MARK: - Shared

    private func apply(_ snapshot: Snapshot) {
        quota = snapshot
        updatePresence()
        scheduleExpiry()
    }

    /// Arm one timer for the soonest deadline that can still change `showsRow`, and nothing at
    /// all once nothing can — an idle Mac schedules no work.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil

        let now = Date()
        var deadlines: [Date] = []
        if isClaudeActive, !hasBusySession, let latestStatusChange {
            deadlines.append(latestStatusChange.addingTimeInterval(timing.activityWindow))
        }
        if showsRow, let quota {
            deadlines.append(quota.capturedAt.addingTimeInterval(timing.quotaTTL))
        }

        guard let next = deadlines.filter({ $0 > now }).min() else { return }
        let delay = next.timeIntervalSince(now)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.updatePresence()
            self.scheduleExpiry()
        }
    }
}
