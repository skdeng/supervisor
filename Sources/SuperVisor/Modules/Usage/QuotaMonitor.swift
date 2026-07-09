import Foundation

/// Reads Claude Code subscription-quota state from the statusline capture file.
///
/// The user's Claude Code statusline command is a capture wrapper that rewrites
/// `~/.claude/agentpace/last-status.json` with the statusline's full stdin JSON on every
/// refresh — so the file's freshness is a live "Claude Code is being used right now" signal,
/// and its `rate_limits` object (`five_hour` / `seven_day`, each `used_percentage` +
/// `resets_at` epoch seconds) carries the plan-quota utilization shown by `/usage`.
///
/// Two wrinkles this absorbs:
/// - Sessions hosted through the desktop-app bridge omit `rate_limits`, and every session
///   overwrites the same file — so the last quota-bearing payload is retained (stamped with
///   its own capture time) across quota-less rewrites.
/// - The payload is external input: size-capped, parsed defensively, unknown fields ignored.
///
/// The file is watched, not polled: a vnode watch fires when the statusline rewrites it, so the
/// row tracks Claude Code within a heartbeat and costs nothing while idle. Freshness, though, is
/// a function of wall-clock time rather than of writes — when Claude Code stops refreshing the
/// capture no event will ever arrive, yet the row still has to disappear. So a single timer is
/// armed for the next instant a deadline lapses, re-armed on each change, instead of a periodic
/// tick that exists only to notice the absence of one.
///
/// All state is main-actor; the module observes `showsRow` presence flips through
/// `onPresenceChange`.
@MainActor
final class QuotaMonitor: ObservableObject {
    /// One rate-limit window, e.g. the 5-hour session limit.
    struct Window: Equatable {
        /// Short display label ("5h", "7d", "Opus").
        let label: String
        /// Percentage of the limit used, 0...100.
        let usedPercentage: Double
        /// When the window resets.
        let resetsAt: Date
    }

    struct Snapshot: Equatable {
        let windows: [Window]
        /// Mtime of the payload the windows came from (not of the latest rewrite).
        let capturedAt: Date
    }

    /// The most recent quota data seen, retained across payloads that omit `rate_limits`.
    @Published private(set) var quota: Snapshot?
    /// Whether any Claude Code session refreshed the capture file recently.
    @Published private(set) var isClaudeActive = false

    /// Called (on the main actor) whenever `showsRow` flips, so the module can ask the
    /// engine to re-lay-out the sheet.
    var onPresenceChange: (() -> Void)?

    /// The row exists only while Claude Code is actively in use and the quota data is recent
    /// enough to trust.
    var showsRow: Bool {
        guard isClaudeActive, let quota else { return false }
        return Date().timeIntervalSince(quota.capturedAt) < Self.quotaTTL
    }

    /// File younger than this ⇒ "Claude Code is actively being used".
    private static let activityWindow: TimeInterval = 10 * 60
    /// Quota older than this is hidden rather than shown wrong.
    private static let quotaTTL: TimeInterval = 30 * 60
    /// Sanity cap on the payload read — the real file is ~1 KB.
    private static let maxPayloadBytes = 1 << 20

    /// Known window keys in display order, with their labels.
    private static let windowKeys: [(key: String, label: String)] = [
        ("five_hour", "5h"),
        ("seven_day", "7d"),
        ("seven_day_opus", "Opus"),
        ("seven_day_sonnet", "Sonnet"),
    ]

    static let defaultCaptureURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agentpace/last-status.json")

    private let captureURL: URL

    init(captureURL: URL = QuotaMonitor.defaultCaptureURL) {
        self.captureURL = captureURL
    }

    private var watcher: FileChangeWatcher?
    private var expiry: Task<Void, Never>?
    /// Mtime of the capture file as of the last refresh; `nil` when the file is absent.
    private var lastMtime: Date?
    /// Mtime of the payload last parsed, so an unchanged file is never re-read.
    private var lastReadMtime: Date?
    private var hadRow = false

    func start() {
        guard watcher == nil else { return }
        let watcher = FileChangeWatcher(url: captureURL) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        self.watcher = watcher
        watcher.start()
        refresh()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        expiry?.cancel()
        expiry = nil
        lastMtime = nil
        lastReadMtime = nil
    }

    /// Re-stat the capture file, re-parse it if it actually changed, and re-arm the expiry.
    private func refresh() {
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: captureURL.path)[.modificationDate]) as? Date
        lastMtime = mtime

        if let mtime {
            if mtime != lastReadMtime {
                lastReadMtime = mtime
                if let windows = readWindows(), !windows.isEmpty {
                    quota = Snapshot(windows: windows, capturedAt: mtime)
                }
            }
        } else {
            lastReadMtime = nil
        }

        updatePresence()
        scheduleExpiry()
    }

    /// Recompute the time-derived state and tell the module if the row appeared or vanished.
    private func updatePresence() {
        isClaudeActive = lastMtime.map { Date().timeIntervalSince($0) < Self.activityWindow } ?? false

        let has = showsRow
        if has != hadRow {
            hadRow = has
            onPresenceChange?()
        }
    }

    /// Arm one timer for the soonest deadline that can still change `showsRow`, and nothing at
    /// all once the row is already hidden — an idle Mac schedules no work.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil

        let now = Date()
        var deadlines: [Date] = []
        if isClaudeActive, let lastMtime {
            deadlines.append(lastMtime.addingTimeInterval(Self.activityWindow))
        }
        if showsRow, let quota {
            deadlines.append(quota.capturedAt.addingTimeInterval(Self.quotaTTL))
        }

        guard let next = deadlines.filter({ $0 > now }).min() else { return }
        let delay = next.timeIntervalSince(now)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.updatePresence()
            self?.scheduleExpiry()
        }
    }

    /// Parse `rate_limits` out of the capture file. Returns `nil` on any read/shape problem
    /// (missing file, oversized, not JSON, no usable windows) — never throws, never trusts.
    private func readWindows() -> [Window]? {
        guard let data = try? Data(contentsOf: captureURL),
              data.count <= Self.maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any]
        else { return nil }

        var windows: [Window] = []
        for (key, label) in Self.windowKeys {
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
}
