import Foundation
import Testing

@testable import SuperVisor

@Suite("Page text and snapshots")
struct PageSnapshotTests {
    private let policy = SiteNavigationPolicy(browseHosts: ["example.com"])
    private let pageURL = URL(string: "https://example.com/account")!

    private func make(
        title: String = "Account",
        text: String = "Hello",
        links: [(text: String, href: String)] = []
    ) -> PageSnapshot {
        PageSnapshot.make(url: pageURL, rawTitle: title, rawText: text, rawLinks: links, policy: policy)
    }

    // MARK: Text

    @Test("Control and format characters are removed and line breaks kept")
    func cleansCharacters() {
        #expect(PageText.clean("a\u{1B}[31mred\u{07}\u{00}b", limit: 100) == "a[31mredb")
        #expect(PageText.clean("zero\u{200B}width\u{FEFF}joiner\u{200D}", limit: 100) == "zerowidthjoiner")
        #expect(PageText.clean("one\ntwo", limit: 100) == "one\ntwo")
        #expect(PageText.clean("one\r\ntwo\rthree\u{2028}four\u{85}five", limit: 100) == "one\ntwo\nthree\nfour\nfive")
    }

    @Test("Bidirectional controls cannot reorder what a line says")
    func removesBidirectionalControls() {
        let hostile = "Balance \u{202E}drowssap\u{202C} \u{2066}x\u{2069} \u{200F}\u{200E}\u{061C}ok"
        let cleaned = PageText.clean(hostile, limit: 100)

        #expect(cleaned == "Balance drowssap x ok")
        let controls = cleaned.unicodeScalars.filter {
            (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
                || [0x200E, 0x200F, 0x061C].contains($0.value)
        }
        #expect(controls.isEmpty)
    }

    @Test("Tag characters that hide text are removed")
    func removesTagCharacters() {
        let hidden = String(String.UnicodeScalarView("hidden".unicodeScalars.map {
            Unicode.Scalar(0xE0000 + $0.value)!
        }))
        #expect(PageText.clean("visible" + hidden, limit: 100) == "visible")
    }

    @Test("Whitespace collapses within a line, and runs of blank lines become one")
    func collapsesWhitespace() {
        #expect(PageText.clean("  a \t b\u{00A0}\u{3000}c  ", limit: 100) == "a b c")
        #expect(PageText.clean("a\n\n\n\nb", limit: 100) == "a\n\nb")
        #expect(PageText.clean("a\n   \n\t\n\nb", limit: 100) == "a\n\nb")
        #expect(PageText.clean("\n\n  \na\nb\n\n\n", limit: 100) == "a\nb")
        #expect(PageText.clean(" \n\t\n", limit: 100) == "")
        #expect(PageText.clean("", limit: 100) == "")
    }

    @Test("Text is cut at the limit, counting every character and line break")
    func capsText() {
        #expect(PageText.clean("abcdefghij", limit: 5) == "abcde")
        #expect(PageText.clean("abcde", limit: 5) == "abcde")
        #expect(PageText.clean("ab\n\ncd", limit: 4) == "ab\n\n")
        #expect(PageText.clean("ab\ncd", limit: 4) == "ab\nc")
        #expect(PageText.clean("abc", limit: 0) == "")
        // A run of combining marks is one character to a reader and many scalars to the cap.
        let stacked = "a" + String(repeating: "\u{0301}", count: 10_000)
        #expect(PageText.clean(stacked, limit: 100).unicodeScalars.count == 100)
    }

    @Test("A line is one line of single-spaced text, cut with an ellipsis")
    func cleansLines() {
        #expect(PageText.cleanLine("  Line one\n  line\ttwo  ", limit: 100) == "Line one line two")
        #expect(PageText.cleanLine("a\u{1B}[0m\u{202E}b", limit: 100) == "a[0mb")
        #expect(PageText.cleanLine("abcdefghij", limit: 5) == "abcd…")
        #expect(PageText.cleanLine("abcde", limit: 5) == "abcde")
        #expect(PageText.cleanLine("abcdef", limit: 5) == "abcd…")
        #expect(PageText.cleanLine("   \n ", limit: 5) == "")
        #expect(PageText.cleanLine("abc", limit: 0) == "")
        #expect(PageText.cleanLine(String(repeating: "x ", count: 1_000_000), limit: 200).unicodeScalars.count == 200)
    }

    // MARK: Snapshots

    @Test("A snapshot carries cleaned text, a cut title, and its address")
    func basicSnapshot() {
        let snapshot = make(
            title: "  My \u{202E}Account\n" + String(repeating: "t", count: 300),
            text: "Welcome\u{1B}[1m back\n\n\n\nBalance: $12"
        )

        #expect(snapshot.url == pageURL)
        #expect(snapshot.title.unicodeScalars.count == 200)
        #expect(snapshot.title.hasPrefix("My Account "))
        #expect(snapshot.title.hasSuffix("…"))
        #expect(snapshot.text == "Welcome[1m back\n\nBalance: $12")
    }

    @Test("A page of a million characters is cut to 400,000, from its start")
    func hugeText() {
        let unit = "0123456789abcdef"
        let raw = String(repeating: unit, count: 1_000_000 / unit.count + 1).prefix(1_000_000)
        #expect(raw.count == 1_000_000)

        let snapshot = make(text: String(raw))

        #expect(snapshot.text.unicodeScalars.count == PageSnapshot.textLimit)
        #expect(snapshot.text.hasPrefix(unit + unit))
    }

    @Test("Only links the policy offers are kept, each address once")
    func linksAreFilteredAndUnique() {
        let snapshot = make(links: [
            (text: "Cards", href: "https://example.com/cards"),
            (text: "Cards again", href: "https://example.com/cards"),
            (text: "Elsewhere", href: "https://evil.test/cards"),
            (text: "Sign out", href: "https://example.com/neutral"),
            (text: "Out", href: "https://example.com/logout"),
            (text: "Plain http", href: "http://example.com/cards"),
            (text: "Script", href: "javascript:alert(1)"),
            (text: "Relative", href: "/relative"),
            (text: "Not a URL", href: "https://exa mple.com/"),
            (text: "Statements", href: "https://example.com/statements"),
        ])

        #expect(snapshot.links.map(\.text) == ["Cards", "Statements"])
        #expect(snapshot.links.map(\.url.absoluteString) == [
            "https://example.com/cards", "https://example.com/statements",
        ])
    }

    @Test("A link with no text is named by the last part of its address, or its host")
    func linkLabels() {
        let snapshot = make(links: [
            (text: "", href: "https://example.com/account/statements"),
            (text: " \n ", href: "https://example.com/account/card%20details"),
            (text: "", href: "https://example.com/"),
        ])

        #expect(snapshot.links.map(\.text) == ["statements", "card details", "example.com"])
    }

    @Test("Link text is cleaned and cut, but a refused word past the cut still refuses the link")
    func linkTextCut() {
        let long = String(repeating: "word ", count: 100)
        let kept = make(links: [(text: long, href: "https://example.com/a")])
        #expect(kept.links.first?.text.unicodeScalars.count == 120)
        #expect(kept.links.first?.text.hasSuffix("…") == true)

        let hidden = make(links: [(text: long + "Delete", href: "https://example.com/b")])
        #expect(hidden.links.isEmpty)

        let cleaned = make(links: [(text: "Ca\u{202E}rds\u{1B}[0m", href: "https://example.com/c")])
        #expect(cleaned.links.first?.text == "Cards[0m")
    }

    @Test("Ten thousand links come back as at most 200")
    func linkCap() {
        let links = (0..<10_000).map { (text: "Link \($0)", href: "https://example.com/page/\($0)") }

        let snapshot = make(links: links)

        #expect(snapshot.links.count == PageSnapshot.linkLimit)
        #expect(snapshot.links.first?.text == "Link 0")
        #expect(snapshot.links.last?.text == "Link 199")
    }

    @Test("Ten thousand links with refused ones among them still yield 200 offered")
    func linkCapAfterFiltering() {
        let links = (0..<10_000).map { index in
            index.isMultiple(of: 2)
                ? (text: "Delete \(index)", href: "https://example.com/d/\(index)")
                : (text: "Item \(index)", href: "https://example.com/i/\(index)")
        }

        let snapshot = make(links: links)

        #expect(snapshot.links.count == 200)
        #expect(snapshot.links.allSatisfy { $0.text.hasPrefix("Item") })
    }

    @Test("An address over 2,048 bytes is dropped")
    func overlongAddress() {
        let long = "https://example.com/" + String(repeating: "a", count: 2_100)
        #expect(make(links: [(text: "Long", href: long)]).links.isEmpty)
    }

    // MARK: Slices

    @Test("An empty page has one empty slice")
    func emptySlices() {
        let snapshot = make(text: "")

        #expect(snapshot.sliceCount == 1)
        #expect(snapshot.slice(0) == "")
        #expect(snapshot.slice(1) == nil)
        #expect(snapshot.slice(-1) == nil)
    }

    @Test("Slices are 40,000 characters, the last holding the remainder, and nil past the end")
    func slicing() {
        let exact = PageSnapshot(
            url: pageURL,
            title: "",
            text: String(repeating: "x", count: PageSnapshot.sliceLength),
            links: []
        )
        #expect(exact.sliceCount == 1)
        #expect(exact.slice(0)?.count == 40_000)
        #expect(exact.slice(1) == nil)

        let text = String(repeating: "abcdefghij", count: 8_001)
        let over = PageSnapshot(url: pageURL, title: "", text: text, links: [])
        #expect(over.sliceCount == 3)
        #expect(over.slice(0)?.count == 40_000)
        #expect(over.slice(1)?.count == 40_000)
        #expect(over.slice(2)?.count == 10)
        #expect(over.slice(3) == nil)
        #expect((0..<over.sliceCount).compactMap(over.slice).joined() == text)
    }

    @Test("The largest page divides into ten slices")
    func largestPage() {
        let snapshot = make(text: String(repeating: "word ", count: 500_000))
        #expect(snapshot.text.unicodeScalars.count <= PageSnapshot.textLimit)
        #expect(snapshot.sliceCount == 10)
        #expect(snapshot.slice(9) != nil)
        #expect(snapshot.slice(10) == nil)
    }
}
