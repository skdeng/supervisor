import Foundation

/// A link a reader may follow.
struct PageLink: Equatable, Sendable {
    let text: String
    let url: URL
}

/// What a page said when it was read: its address, title, visible text, and the links a reader
/// may follow.
///
/// Every field began as a page's own output, so it was bounded and cleaned on the way in
/// (`make`) and arrives here ready to show a model.
struct PageSnapshot: Equatable, Sendable {
    static let titleLimit = 200
    static let textLimit = 400_000
    static let linkTextLimit = 120
    static let linkLimit = 200
    static let sliceLength = 40_000
    /// The longest text taken from a page before cleaning.
    static let rawTextLimit = 500_000
    /// The longest link address taken from a page.
    static let rawAddressLimit = 2_048
    /// The longest link text examined for refused words, before it is cut for display.
    private static let linkTextExamined = 2_000

    let url: URL
    let title: String
    /// Visible text, cleaned, at most `textLimit` characters.
    let text: String
    /// Only links the policy offers, de-duplicated by address, at most `linkLimit`.
    let links: [PageLink]

    /// How many slices the text divides into; at least one, so an empty page has a first slice.
    var sliceCount: Int {
        max(1, (text.unicodeScalars.count + Self.sliceLength - 1) / Self.sliceLength)
    }

    /// The `index`th (from zero) run of `sliceLength` characters; nil past the end.
    func slice(_ index: Int) -> String? {
        guard index >= 0, index < sliceCount else { return nil }
        let scalars = text.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: index * Self.sliceLength)
        let end = scalars.index(start, offsetBy: Self.sliceLength, limitedBy: scalars.endIndex)
            ?? scalars.endIndex
        return String(scalars[start..<end])
    }

    /// Builds a snapshot from what a script returned for the page at `url`.
    ///
    /// A link is kept when its address parses and `policy` offers it. Its text is cleaned and
    /// cut for display after the policy has read it whole, so a refused word past the cut
    /// still refuses the link.
    static func make(
        url: URL,
        rawTitle: String,
        rawText: String,
        rawLinks: [(text: String, href: String)],
        policy: SiteNavigationPolicy
    ) -> PageSnapshot {
        var seen = Set<String>()
        var links: [PageLink] = []
        for raw in rawLinks {
            guard links.count < linkLimit else { break }
            guard raw.href.utf8.count <= rawAddressLimit,
                  let address = URL(string: raw.href)
            else { continue }
            let examined = PageText.cleanLine(raw.text, limit: linkTextExamined)
            guard policy.offers(linkText: examined, url: address),
                  seen.insert(address.absoluteString).inserted
            else { continue }
            links.append(PageLink(
                text: label(for: examined, address: address),
                url: address
            ))
        }
        return PageSnapshot(
            url: url,
            title: PageText.cleanLine(rawTitle, limit: titleLimit),
            text: PageText.clean(
                String(String.UnicodeScalarView(rawText.unicodeScalars.prefix(rawTextLimit))),
                limit: textLimit
            ),
            links: links
        )
    }

    /// The link's own text, or the last path component of its address, or its host.
    private static func label(for text: String, address: URL) -> String {
        if !text.isEmpty { return PageText.cleanLine(text, limit: linkTextLimit) }
        let component = address.lastPathComponent
        let fallback = component == "/" || component.isEmpty
            ? (address.host(percentEncoded: false) ?? "")
            : component.removingPercentEncoding ?? component
        return PageText.cleanLine(fallback, limit: linkTextLimit)
    }
}

/// Page text made safe to show a model.
enum PageText {
    /// Page text with control and format characters removed, line breaks kept, runs of blank
    /// lines reduced to one, each line's whitespace collapsed, and the whole cut to `limit`
    /// characters.
    ///
    /// An ANSI escape or a bidirectional override in a page would otherwise redraw a row or
    /// let a line read as something other than what it says. Characters are counted as
    /// Unicode scalars, so a run of combining marks cannot stretch the cap.
    static func clean(_ raw: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var output = String.UnicodeScalarView()
        var count = 0
        var line = String.UnicodeScalarView()
        var pendingSpace = false
        var pendingBlank = false
        var previousWasCarriageReturn = false

        /// Appends the finished line, or notes a blank one. Returns whether the cap is reached.
        func finishLine() -> Bool {
            defer {
                line = String.UnicodeScalarView()
                pendingSpace = false
            }
            guard !line.isEmpty else {
                pendingBlank = count > 0
                return false
            }
            let separator = count == 0 ? 0 : (pendingBlank ? 2 : 1)
            pendingBlank = false
            var combined = String.UnicodeScalarView()
            combined.append(contentsOf: String(repeating: "\n", count: separator).unicodeScalars)
            combined.append(contentsOf: line)
            let room = limit - count
            if combined.count > room {
                output.append(contentsOf: combined.prefix(room))
                count = limit
                return true
            }
            output.append(contentsOf: combined)
            count += combined.count
            return count >= limit
        }

        for scalar in raw.unicodeScalars {
            if isLineBreak(scalar) {
                // A line feed straight after a carriage return is the same break.
                let continuesBreak = scalar == "\n" && previousWasCarriageReturn
                previousWasCarriageReturn = scalar == "\r"
                if continuesBreak { continue }
                if finishLine() { return String(output) }
                continue
            }
            previousWasCarriageReturn = false
            if scalar.properties.isWhitespace {
                pendingSpace = !line.isEmpty
                continue
            }
            if isDropped(scalar) { continue }
            if pendingSpace {
                line.append(" ")
                pendingSpace = false
            }
            line.append(scalar)
        }
        _ = finishLine()
        return String(output)
    }

    /// Text for a title or a link: one line, whitespace collapsed, control and format
    /// characters removed, and cut to `limit` characters with an ellipsis.
    static func cleanLine(_ raw: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        var scalars = String.UnicodeScalarView()
        var count = 0
        var pendingSpace = false
        for scalar in raw.unicodeScalars {
            if isLineBreak(scalar) || scalar.properties.isWhitespace {
                pendingSpace = count > 0
                continue
            }
            if isDropped(scalar) { continue }
            if pendingSpace {
                scalars.append(" ")
                count += 1
                pendingSpace = false
            }
            scalars.append(scalar)
            count += 1
            // One scalar past the cap proves the text runs over it.
            if count > limit { break }
        }
        guard count > limit else { return String(scalars) }
        return String(scalars.prefix(limit - 1)) + "…"
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    private static func isDropped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format: true
        default: false
        }
    }
}
