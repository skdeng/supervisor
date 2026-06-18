import Foundation

/// Formatting helpers shared by the compact chip and the expanded event list.
enum GlanceFormatting {
    /// A terse countdown for the compact pill, e.g. "12m", "1h", "now", "5d". Designed to
    /// stay within a couple of characters so it fits beside the notch.
    static func compactCountdown(to date: Date, now: Date = Date()) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "now" }
        let minutes = Int((delta / 60).rounded())
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = Int((delta / 3600).rounded(.down))
        if hours < 24 {
            let remMinutes = minutes - hours * 60
            return remMinutes >= 1 ? "\(hours)h\(remMinutes)m" : "\(hours)h"
        }
        let days = Int((delta / 86400).rounded(.down))
        return "\(days)d"
    }

    /// A fuller relative phrase for the expanded list, e.g. "in 12 min", "in 2 hr",
    /// "now", "tomorrow 9:00 AM".
    static func relativeDescription(for event: GlanceEvent, now: Date = Date()) -> String {
        if event.isAllDay {
            return isToday(event.startDate, now: now) ? "All day" : "All day " + weekdayString(event.startDate)
        }

        let delta = event.startDate.timeIntervalSince(now)
        if event.startDate <= now && event.endDate > now {
            return "Now · ends \(timeString(event.endDate))"
        }
        if delta <= 0 {
            return "Now"
        }
        if delta < 60 {
            return "in <1 min"
        }
        if delta < 3600 {
            let minutes = Int((delta / 60).rounded())
            return "in \(minutes) min"
        }
        if delta < 6 * 3600 {
            let hours = delta / 3600
            return String(format: "in %.1f hr", hours)
        }
        // Beyond a few hours, show an absolute time, with a day qualifier if needed.
        if isToday(event.startDate, now: now) {
            return timeString(event.startDate)
        }
        if isTomorrow(event.startDate, now: now) {
            return "Tomorrow \(timeString(event.startDate))"
        }
        return "\(weekdayString(event.startDate)) \(timeString(event.startDate))"
    }

    /// A short title for the compact chip, truncated so it never crowds the notch.
    static func compactTitle(_ title: String, maxLength: Int = 12) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: maxLength - 1)
        return String(trimmed[..<end]) + "…"
    }

    // MARK: Primitives

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    static func timeString(_ date: Date) -> String { timeFormatter.string(from: date) }
    static func weekdayString(_ date: Date) -> String { weekdayFormatter.string(from: date) }

    static func isToday(_ date: Date, now: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: now)
    }

    static func isTomorrow(_ date: Date, now: Date) -> Bool {
        guard let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) else { return false }
        return Calendar.current.isDate(date, inSameDayAs: tomorrow)
    }
}
