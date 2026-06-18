import Foundation

/// A single countdown timer.
///
/// The source of truth for remaining time is a wall-clock `fireDate` while the timer runs,
/// so the countdown stays correct across app sleep, clock drift, and relaunch. When paused,
/// the timer instead remembers the static `remainingWhenPaused` interval and has no
/// `fireDate`; resuming recomputes a fresh `fireDate` from the current wall clock.
struct CountdownTimer: Identifiable, Codable, Equatable {
    enum State: String, Codable {
        case running
        case paused
        /// Reached zero and is awaiting acknowledgement (still listed so the user sees it
        /// rang). Cleared when dismissed.
        case completed
    }

    let id: UUID
    /// Optional user label; empty string renders as the duration.
    var label: String
    /// The full duration the timer was created with, in seconds. Used for ring progress and
    /// for the "restart" affordance.
    var totalDuration: TimeInterval
    /// Absolute wall-clock instant the timer fires. Non-nil only while `running`.
    var fireDate: Date?
    /// Remaining seconds captured at the moment of pausing. Non-nil only while `paused`.
    var remainingWhenPaused: TimeInterval?
    var state: State
    /// Creation order tiebreaker for stable sorting among equal fire dates.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        label: String = "",
        totalDuration: TimeInterval,
        fireDate: Date?,
        remainingWhenPaused: TimeInterval? = nil,
        state: State,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.totalDuration = totalDuration
        self.fireDate = fireDate
        self.remainingWhenPaused = remainingWhenPaused
        self.state = state
        self.createdAt = createdAt
    }

    /// Seconds left, clamped at zero. Derived from the wall clock while running so it is
    /// always accurate regardless of tick cadence.
    func remaining(at now: Date = Date()) -> TimeInterval {
        switch state {
        case .running:
            guard let fireDate else { return 0 }
            return max(0, fireDate.timeIntervalSince(now))
        case .paused:
            return max(0, remainingWhenPaused ?? 0)
        case .completed:
            return 0
        }
    }

    /// Progress from 0 (just started) to 1 (elapsed), for the ring.
    func progress(at now: Date = Date()) -> Double {
        guard totalDuration > 0 else { return 1 }
        let elapsed = totalDuration - remaining(at: now)
        return min(1, max(0, elapsed / totalDuration))
    }

    /// Whether a running timer has reached or passed its fire date.
    func hasElapsed(at now: Date = Date()) -> Bool {
        guard state == .running, let fireDate else { return false }
        return now >= fireDate
    }

    /// A human label for the timer, falling back to its formatted total duration.
    var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CountdownTimer.formatDuration(totalDuration) : trimmed
    }

    // MARK: Formatting

    /// `m:ss` or `h:mm:ss` for the countdown readout.
    static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// A compact, label-friendly duration like "25 min" or "1h 5m".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if m > 0 {
            return s > 0 ? "\(m)m \(s)s" : "\(m) min"
        }
        return "\(s)s"
    }
}
