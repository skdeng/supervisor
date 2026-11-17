import Foundation

/// Where a site browser may go and which links it may offer, as pure rules.
///
/// Hosts match exactly, never as suffixes or prefixes.
struct SiteNavigationPolicy: Equatable, Sendable {
    let browseHosts: Set<String>
    /// Admits any host. Only an enrollment the user is watching uses it.
    let admitsAnyHost: Bool

    init(browseHosts: Set<String>, admitsAnyHost: Bool = false) {
        self.browseHosts = browseHosts
        self.admitsAnyHost = admitsAnyHost
    }

    /// Any `https` host with no port, for the sign-in the user is watching and typed the
    /// address of.
    static let anyHTTPSHost = SiteNavigationPolicy(browseHosts: [], admitsAnyHost: true)

    /// A main-frame load: `https`, an exact host on the list, no user or password, no explicit
    /// port.
    func allowsMainFrame(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty
        else { return false }
        return admitsAnyHost ? SiteHost.isValid(host) : browseHosts.contains(host)
    }

    /// A frame inside a page: `https` on any host, or `about:blank` / `about:srcdoc`.
    func allowsSubframe(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host(percentEncoded: false)?.isEmpty == false
        case "about":
            return ["about:blank", "about:srcdoc"].contains(url.absoluteString.lowercased())
        default:
            return false
        }
    }

    /// Whether a link may be offered to a reader: allowed as a main-frame load, and neither its
    /// text nor its address reads as something that changes or ends the session.
    ///
    /// Text and address are read as words, split at every character that is not a letter or
    /// digit, where a lowercase letter meets an uppercase one, and between letters and digits
    /// (`cancelOrder` reads as `cancel`, `order`). Words are matched whole, so
    /// `payment-methods` and "Payment methods" are offered while `/pay` and "Pay now" are not.
    func offers(linkText: String, url: URL) -> Bool {
        guard allowsMainFrame(url) else { return false }
        return !Self.refuses(Self.words(in: linkText)) && !Self.refusesAddress(url)
    }

    // MARK: Refused words

    /// Words that read as an action on the account or the session.
    private static let refusedWords: Set<String> = [
        "signout", "signoff", "logout", "logoff", "delete", "remove", "cancel", "cancellation",
        "deactivate", "enroll", "enrol", "unenroll", "unenrol", "confirm", "pay", "transfer",
        "send", "unsubscribe", "submit", "redeem", "apply", "terminate", "revoke",
    ]

    /// Two-word forms of the same.
    private static let refusedWordPairs: Set<[String]> = [
        ["sign", "out"], ["log", "out"], ["sign", "off"], ["log", "off"],
        ["close", "account"], ["account", "close"],
    ]

    /// `text` as lowercase words, split at every character that is not a letter or digit, where
    /// a lowercase letter meets an uppercase one, and between letters and digits.
    ///
    /// With `splittingDigits` false, letters and digits that touch stay one word (`2fa`).
    static func words(in text: String, splittingDigits: Bool = true) -> [String] {
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous {
                let camelBoundary = previous.isLowercase && character.isUppercase
                let digitBoundary = splittingDigits && previous.isNumber != character.isNumber
                if (camelBoundary || digitBoundary) && !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    private static func refusesAddress(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return true
        }
        let parts = [
            components.percentEncodedPath, components.percentEncodedQuery ?? "",
            components.percentEncodedFragment ?? "",
        ]
        // Each part is read as written and as decoded, so `%6Cogout` reads as `logout`.
        for part in parts {
            for variant in [part, part.removingPercentEncoding ?? part] where refuses(words(in: variant)) {
                return true
            }
        }
        return false
    }

    private static func refuses(_ words: [String]) -> Bool {
        if words.contains(where: refusedWords.contains) { return true }
        return zip(words, words.dropFirst()).contains { refusedWordPairs.contains([$0, $1]) }
    }
}
