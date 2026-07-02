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
        // Match the host exactly or as a subdomain — NOT a substring, so a look-alike domain that
        // merely embeds a provider name (e.g. `zoom.us.attacker.com`, `evil-webex.com`) is not
        // mislabeled as the trusted provider.
        func isHost(_ domain: String) -> Bool { h == domain || h.hasSuffix("." + domain) }
        if isHost("zoom.us") || isHost("zoom.com") { return .zoom }
        if isHost("meet.google.com") { return .meet }
        if isHost("teams.microsoft.com") || isHost("teams.live.com") { return .teams }
        if isHost("webex.com") { return .webex }
        return .generic
    }
}

/// Finds a meeting join link in an event, preferring a recognized video-provider URL.
/// Search order: the event's dedicated URL field, then its location, then its notes.
enum MeetingLink {
    /// URL schemes safe to hand to `NSWorkspace.open` for a "Join" action. Event url/location/
    /// notes are attacker-controlled (anyone who can send an invite), so anything outside this
    /// set — `file:`, `smb:`, `x-apple.systempreferences:`, `javascript:`, arbitrary custom app
    /// deep links, `mailto:` — is rejected rather than launched when the victim clicks Join.
    private static let allowedSchemes: Set<String> = [
        "http", "https",              // the vast majority of join links
        "zoommtg", "zoomus",          // Zoom app deep links
        "msteams",                    // Microsoft Teams
        "webex", "webexstart", "wbx", // Webex
    ]

    /// Whether `url` is safe to open for a Join action (scheme is on the allowlist).
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    static func detect(in event: EKEvent) -> (url: URL, provider: MeetingProvider)? {
        // 1. The dedicated URL field, if it already points at a known provider.
        if let url = event.url, isAllowed(url) {
            let provider = MeetingProvider.from(host: url.host)
            if provider.isKnown { return (url, provider) }
        }
        // 2. A known-provider URL embedded in the location or notes (where most invites put it).
        for text in [event.location, event.notes].compactMap({ $0 }) {
            for url in urls(in: text) where isAllowed(url) {
                let provider = MeetingProvider.from(host: url.host)
                if provider.isKnown { return (url, provider) }
            }
        }
        // 3. Fall back to any allowed URL: the dedicated field first, then location/notes — as a
        //    generic "Join" link so non-Zoom/Meet/Teams meetings still get a button.
        if let url = event.url, isAllowed(url) { return (url, .generic) }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let url = urls(in: text).first(where: isAllowed) {
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
