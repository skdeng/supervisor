import Foundation

/// Tracks whether Codex is active and obtains its plan-quota windows from app-server.
///
/// Session JSONL *contents* are never opened. Their mtimes are only an activity heartbeat, just
/// as the Claude statusline capture's mtime is for `QuotaMonitor`. A recursive FSEvents stream
/// covers the date-partitioned sessions tree, so sessions that cross midnight or resume from an
/// older date remain visible without polling. A single deadline timer hides the row after
/// activity/quota freshness expires.
@MainActor
final class CodexQuotaMonitor: ObservableObject {
    struct Snapshot: Equatable {
        let windows: [UsageTickerWindow]
        let capturedAt: Date
    }

    @Published private(set) var quota: Snapshot?
    @Published private(set) var isCodexActive = false

    var onPresenceChange: (() -> Void)?

    var showsRow: Bool {
        guard isCodexActive, let quota else { return false }
        return Date().timeIntervalSince(quota.capturedAt) < Self.quotaTTL
    }

    private static let activityWindow: TimeInterval = 10 * 60
    private static let quotaTTL: TimeInterval = 30 * 60
    private static let requestCooldown: TimeInterval = 5
    private static let retryDelay: TimeInterval = 30

    static let defaultSessionsRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    private let sessionsRootURL: URL
    private let client: CodexRateLimitClient

    init(
        sessionsRootURL: URL = CodexQuotaMonitor.defaultSessionsRootURL,
        client: CodexRateLimitClient = CodexRateLimitClient()
    ) {
        self.sessionsRootURL = sessionsRootURL
        self.client = client
    }

    private var isRunning = false
    private var rootWatcher: FileChangeWatcher?
    private var treeWatcher: DirectoryTreeWatcher?
    private var lastActivityAt: Date?
    private var lastRequestAt: Date?
    private var hadRow = false
    private var expiry: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        client.onSnapshot = { [weak self] windows in
            self?.receive(windows)
        }
        client.onUnavailable = { [weak self] in
            self?.scheduleRetry()
        }

        let rootWatcher = FileChangeWatcher(url: sessionsRootURL) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.ensureTreeWatcher()
                    self?.refreshActivity()
                }
            }
        }
        self.rootWatcher = rootWatcher
        rootWatcher.start()
        ensureTreeWatcher()
        refreshActivity()
    }

    func stop() {
        isRunning = false
        rootWatcher?.stop()
        rootWatcher = nil
        treeWatcher?.stop()
        treeWatcher = nil
        expiry?.cancel()
        expiry = nil
        requestTask?.cancel()
        requestTask = nil
        retryTask?.cancel()
        retryTask = nil
        client.stop()
        client.onSnapshot = nil
        client.onUnavailable = nil
        lastActivityAt = nil
        lastRequestAt = nil
        isCodexActive = false
        hadRow = false
    }

    // MARK: - Activity discovery

    private func ensureTreeWatcher() {
        guard isRunning, treeWatcher == nil,
              FileManager.default.fileExists(atPath: sessionsRootURL.path)
        else { return }

        let watcher = DirectoryTreeWatcher(url: sessionsRootURL) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.recordTreeActivity()
                }
            }
        }
        treeWatcher = watcher
        watcher.start()
    }

    /// The recursive stream is scoped to Codex's sessions tree, so any nested event is itself a
    /// fresh activity heartbeat. Avoid re-enumerating years of transcripts on every append.
    private func recordTreeActivity() {
        guard isRunning else { return }
        lastActivityAt = Date()
        updatePresence()
        if isCodexActive { requestQuotaSoon() }
        scheduleExpiry()
    }

    /// Initial/root-creation discovery reads metadata only and finds the newest session mtime.
    private func refreshActivity() {
        guard isRunning else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var newest: Date?
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else { continue }
            if newest == nil || modified > newest! {
                newest = modified
            }
        }
        lastActivityAt = newest

        updatePresence()
        if isCodexActive { requestQuotaSoon() }
        scheduleExpiry()
    }

    private func updatePresence() {
        let active = lastActivityAt.map {
            Date().timeIntervalSince($0) < Self.activityWindow
        } ?? false
        if active != isCodexActive {
            isCodexActive = active
        }

        if !active {
            requestTask?.cancel()
            requestTask = nil
            retryTask?.cancel()
            retryTask = nil
            client.stop()
            lastRequestAt = nil
        }

        let has = showsRow
        if has != hadRow {
            hadRow = has
            AppLog.debug(.usage, "usage app-server row -> \(has ? "visible" : "hidden")")
            onPresenceChange?()
        }
    }

    // MARK: - Quota

    private func requestQuotaSoon() {
        guard isRunning, isCodexActive else { return }

        requestTask?.cancel()
        let elapsed = lastRequestAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, Self.requestCooldown - elapsed)
        requestTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard let self, !Task.isCancelled, self.isRunning, self.isCodexActive else { return }
            self.lastRequestAt = Date()
            self.client.requestSnapshot()
        }
    }

    private func receive(_ windows: [UsageTickerWindow]) {
        guard isRunning, !windows.isEmpty else { return }
        quota = Snapshot(windows: windows, capturedAt: Date())
        updatePresence()
        scheduleExpiry()
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard isRunning, isCodexActive else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.retryDelay))
            guard let self, !Task.isCancelled, self.isRunning, self.isCodexActive else { return }
            self.lastRequestAt = Date()
            self.client.requestSnapshot()
        }
    }

    /// Arm one timer for the soonest activity/quota deadline that can change row presence.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil

        let now = Date()
        var deadlines: [Date] = []
        if isCodexActive, let lastActivityAt {
            deadlines.append(lastActivityAt.addingTimeInterval(Self.activityWindow))
        }
        if showsRow, let quota {
            deadlines.append(quota.capturedAt.addingTimeInterval(Self.quotaTTL))
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
