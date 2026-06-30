import EventKit
import Foundation

/// A video-meeting provider, inferred from a join URL's host.
enum MeetingProvider: String {
    case zoom, meet, teams, webex, generic

    /// Whether this is a recognized video provider (vs. a bare link).
    var isKnown: Bool { self != .generic }

    var label: String {
        switch self {
        case .zoom: return "Zoom"
        case .meet: return "Google Meet"
        case .teams: return "Teams"
        case .webex: return "Webex"
        case .generic: return "Join"
        }
    }

    static func from(host: String?) -> MeetingProvider {
        let h = (host ?? "").lowercased()
        if h.contains("zoom.us") || h.contains("zoom.com") { return .zoom }
        if h.contains("meet.google.com") { return .meet }
        if h.contains("teams.microsoft.com") || h.contains("teams.live.com") { return .teams }
        if h.contains("webex.com") { return .webex }
        return .generic
    }
}

/// Finds a meeting join link in an event, preferring a recognized video-provider URL.
/// Search order: the event's dedicated URL field, then its location, then its notes.
enum MeetingLink {
    static func detect(in event: EKEvent) -> (url: URL, provider: MeetingProvider)? {
        // 1. The dedicated URL field, if it already points at a known provider.
        if let url = event.url {
            let provider = MeetingProvider.from(host: url.host)
            if provider.isKnown { return (url, provider) }
        }
        // 2. A known-provider URL embedded in the location or notes (where most invites put it).
        for text in [event.location, event.notes].compactMap({ $0 }) {
            for url in urls(in: text) {
                let provider = MeetingProvider.from(host: url.host)
                if provider.isKnown { return (url, provider) }
            }
        }
        // 3. Fall back to any URL: the dedicated field first, then location/notes — as a
        //    generic "Join" link so non-Zoom/Meet/Teams meetings still get a button.
        if let url = event.url { return (url, .generic) }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let url = urls(in: text).first {
                return (url, MeetingProvider.from(host: url.host))
            }
        }
        return nil
    }

    private static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }
}
