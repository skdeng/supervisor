import SwiftUI

/// Immutable snapshot of a calendar event surfaced in the notch.
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    /// A detected meeting join link (Zoom / Meet / Teams / Webex / generic), if any.
    let joinURL: URL?
    /// The meeting provider behind `joinURL`, for the glyph/label.
    let provider: MeetingProvider?
    /// The owning calendar's accent color (used for the agenda dot).
    let accent: Color

    var hasJoin: Bool { joinURL != nil }

    /// Whether `now` falls within the event's time span.
    func isOngoing(asOf now: Date = Date()) -> Bool {
        now >= start && now < end
    }

    /// Seconds until the event starts (negative once it has started).
    func secondsUntilStart(asOf now: Date = Date()) -> TimeInterval {
        start.timeIntervalSince(now)
    }

    // `accent`/`provider` are presentation-derived; identity is the (id, title, time, link).
    static func == (lhs: CalendarEvent, rhs: CalendarEvent) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.start == rhs.start
            && lhs.end == rhs.end
            && lhs.joinURL == rhs.joinURL
    }
}
