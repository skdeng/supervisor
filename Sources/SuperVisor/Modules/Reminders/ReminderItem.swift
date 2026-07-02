import SwiftUI

/// Immutable snapshot of an incomplete reminder surfaced in the notch.
struct ReminderItem: Identifiable, Equatable {
    let id: String
    let title: String
    /// Resolved due date (date-only reminders resolve to that day's start). Always present —
    /// the module only surfaces dated reminders.
    let due: Date
    /// Whether the due date carries a time-of-day (vs. an all-day "due today").
    let hasTime: Bool
    /// EKReminder priority (0 = none, 1–4 high, 5 medium, 6–9 low).
    let priority: Int
    let listName: String
    /// The owning list's color (for the row dot / checkbox tint).
    let accent: Color

    var isHighPriority: Bool { (1...4).contains(priority) }

    /// Whether the reminder is past due as of `now`. Timed reminders are overdue once the
    /// instant passes; date-only reminders only once the whole day has passed.
    func isOverdue(asOf now: Date = Date()) -> Bool {
        if hasTime { return due < now }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: now)
    }

    static func == (lhs: ReminderItem, rhs: ReminderItem) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.due == rhs.due
            && lhs.hasTime == rhs.hasTime
            && lhs.priority == rhs.priority
            && lhs.listName == rhs.listName
            && lhs.accent == rhs.accent
    }
}
