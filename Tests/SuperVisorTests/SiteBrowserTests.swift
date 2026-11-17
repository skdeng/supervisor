import Foundation
import Testing
import WebKit

@testable import SuperVisor

@Suite("Site browser", .serialized)
@MainActor
struct SiteBrowserTests {
    private let hosts: Set<String> = ["example.com", "www.example.com"]

    private func browser(
        _ site: TestSite,
        hosts: Set<String>? = nil,
        settling: SiteBrowser.Settling = .fast
    ) -> SiteBrowser {
        SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: hosts ?? self.hosts),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: settling
        )
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: The simulated origin

    @Test("A simulated page has the origin, path, and secure context of a real https page", .timeLimit(.minutes(1)))
    func simulatedOrigin() async throws {
        let site = TestSite()
        site.route("/some/path", page: TestPages.page("Origin", "<p>page</p>"))
        let browser = browser(site)
        defer { browser.close() }

        _ = try await browser.open(url("https://example.com/some/path?q=1#frag"))
        let facts = try await browser.run("""
            return {
              origin: location.origin,
              path: location.pathname,
              search: location.search,
              secure: isSecureContext,
              top: window.top === window.self,
              state: document.readyState
            };
            """)

        #expect(facts["origin"]?.string == "https://example.com")
        #expect(facts["path"]?.string == "/some/path")
        #expect(facts["search"]?.string == "?q=1")
        #expect(facts["secure"]?.bool == true)
        #expect(facts["top"]?.bool == true)
        #expect(facts["state"]?.string == "complete")
        #expect(browser.webView.hasOnlySecureContent)
    }

    @Test("A form submitted in a simulated page is posted to the site with its body", .timeLimit(.minutes(1)))
    func formPostIsIntercepted() async throws {
        let site = TestSite()
        site.route("/form", page: TestPages.page("Form", """
            <form id="f" method="post" action="/submit">
            <input name="a" value="one"><input name="b" value="two words"></form>
            """))
        site.route("/submit", method: "POST") { request in
            TestPages.page("Done", "got \(request.fields.keys.sorted().joined(separator: ","))")
        }
        let browser = browser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/form"))

        let mark = browser.markAction()
        _ = try await browser.run("document.getElementById('f').requestSubmit(); return 1;")
        try await browser.settleAfterAction(since: mark)
        let page = try await browser.snapshot()

        let post = try #require(site.posts.first)
        #expect(site.posts.count == 1)
        #expect(post.path == "/submit")
        #expect(post.fields == ["a": "one", "b": "two words"])
        #expect(page.title == "Done")
        #expect(page.url == url("https://example.com/submit"))
    }

    // MARK: Reading

    @Test("Opening a page returns its text, its title, and the links the policy offers", .timeLimit(.minutes(1)))
    func opensAndReads() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("Alpha", """
            <h1>Heading</h1><p>Some   body   text.</p>
            <a href="/cards">Cards</a>
            <a href="/logout">Sign out</a>
            <a href="https://evil.test/x">Elsewhere</a>
            <a href="https://www.example.com/b">Sibling</a>
            <a href="/cards">Cards again</a>
            <a href="javascript:alert(1)">Script</a>
            """))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/a"))

        #expect(page.title == "Alpha")
        #expect(page.text.contains("Heading"))
        #expect(page.text.contains("Some body text."))
        #expect(page.links.map(\.text) == ["Cards", "Sibling"])
        #expect(page.links.map(\.url.absoluteString) == ["https://example.com/cards", "https://www.example.com/b"])
        #expect(page.url == url("https://example.com/a"))
        #expect(browser.currentURL == page.url)
    }

    @Test("A link to a host off the list is not offered, and nor is one off https", .timeLimit(.minutes(1)))
    func linksToOtherHostsAreNotOffered() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", """
            <a href="https://evil.test/">One</a>
            <a href="https://example.com.evil.test/">Two</a>
            <a href="http://example.com/">Three</a>
            <a href="https://example.com:8443/">Four</a>
            <a href="https://sub.example.com/">Five</a>
            <a href="https://example.com/ok">Six</a>
            """))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/a"))

        #expect(page.links.map(\.text) == ["Six"])
    }

    @Test("Text that appears 600 ms after the load is read once the page has settled", .timeLimit(.minutes(1)))
    func lateTextIsRead() async throws {
        let site = TestSite()
        site.route("/late", page: TestPages.page("Late", "<p id=\"early\">early text</p>", script: """
            setTimeout(() => {
              const p = document.createElement('p');
              p.textContent = 'late text';
              document.body.appendChild(p);
            }, 600);
            """))

        let settled = browser(site, settling: .standard)
        defer { settled.close() }
        let page = try await settled.open(url("https://example.com/late"))

        #expect(page.text.contains("early text"))
        #expect(page.text.contains("late text"))
    }

    @Test("A page has held still after its text length is the same for the given number of looks in a row")
    func settleTracker() {
        func looks(_ stablePolls: Int, _ steps: [Int?]) -> [Bool] {
            var tracker = SiteBrowser.SettleTracker(stablePolls: stablePolls)
            // A nil step is a look at a page still loading.
            return steps.map { step in
                guard let step else {
                    tracker.reset()
                    return false
                }
                return tracker.record(length: step)
            }
        }

        // The first look only sets the length to compare with.
        #expect(looks(2, [10, 10, 10]) == [false, false, true])
        // A change starts the count again, which is what a late render does.
        #expect(looks(2, [10, 10, 25, 25, 25]) == [false, false, false, false, true])
        // A look at a page still loading starts it again too.
        #expect(looks(2, [10, 10, nil, 10, 10, 10]) == [false, false, false, false, false, true])
        // With no looks required the first look settles, so it cannot wait for a late render.
        #expect(looks(0, [10]) == [true])
        #expect(looks(1, [10, 10]) == [false, true])
    }

    @Test("A page that never stops changing is read when the settle limit passes", .timeLimit(.minutes(1)))
    func settleLimit() async throws {
        let site = TestSite()
        site.route("/ticker", page: TestPages.page("Ticker", "<p id=\"t\">x</p>", script: """
            setInterval(() => { document.getElementById('t').textContent += 'x'; }, 10);
            """))
        var settling = SiteBrowser.Settling.fast
        settling.settleLimit = .milliseconds(400)
        let browser = browser(site, settling: settling)
        defer { browser.close() }

        let started = ContinuousClock.now
        let page = try await browser.open(url("https://example.com/ticker"))

        #expect(page.title == "Ticker")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("The browser identifies as a Safari, as sites refuse the bare WebKit agent", .timeLimit(.minutes(1)))
    func userAgent() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        let browser = browser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/a"))

        let agent = try await browser.run("return navigator.userAgent;")

        #expect(agent.string?.contains("Version/26.0 Safari/605.1.15") == true)
    }

    @Test("A closed browser loads, reads, and runs nothing", .timeLimit(.minutes(1)))
    func closedBrowserDoesNothing() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        let browser = browser(site)
        _ = try await browser.open(url("https://example.com/a"))
        site.forgetRequests()

        browser.close()

        await #expect(throws: SiteBrowser.Failure.closed) { _ = try await browser.open(url("https://example.com/a")) }
        await #expect(throws: SiteBrowser.Failure.closed) { _ = try await browser.snapshot() }
        await #expect(throws: SiteBrowser.Failure.closed) { _ = try await browser.run("return 1;") }
        await #expect(throws: SiteBrowser.Failure.closed) { try await browser.settleAfterAction() }
        await #expect(throws: SiteBrowser.Failure.closed) { try await browser.settleLoadedPage() }
        #expect(site.requests.isEmpty)
        // Closing again is harmless.
        browser.close()
    }

    @Test("Closing a browser in the middle of an open ends it with closed", .timeLimit(.minutes(1)))
    func closeDuringOpen() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        var settling = SiteBrowser.Settling.fast
        settling.pollInterval = .milliseconds(300)
        let browser = browser(site, settling: settling)

        let opening = Task { @MainActor in try await browser.open(url("https://example.com/a")) }
        try await Task.sleep(for: .milliseconds(100))
        browser.close()

        await #expect(throws: SiteBrowser.Failure.closed) { _ = try await opening.value }
    }

    @Test("Cancelling the task that is opening a page ends the open", .timeLimit(.minutes(1)))
    func cancelDuringOpen() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        var settling = SiteBrowser.Settling.fast
        settling.pollInterval = .milliseconds(300)
        let browser = browser(site, settling: settling)
        defer { browser.close() }

        let opening = Task { @MainActor in try await browser.open(url("https://example.com/a")) }
        try await Task.sleep(for: .milliseconds(100))
        opening.cancel()

        await #expect(throws: CancellationError.self) { _ = try await opening.value }
    }

    @Test("A load that runs past the total limit times out", .timeLimit(.minutes(1)))
    func totalLimit() async throws {
        let site = TestSite()
        site.route("/slow", page: TestPages.page("Slow", "<p>x</p>"))
        var settling = SiteBrowser.Settling.fast
        settling.totalLimit = .milliseconds(1)
        let browser = browser(site, settling: settling)
        defer { browser.close() }

        await #expect(throws: SiteBrowser.Failure.timedOut) {
            _ = try await browser.open(url("https://example.com/slow"))
        }
    }

    @Test("A script that never finishes times out", .timeLimit(.minutes(1)))
    func scriptTimeout() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        var settling = SiteBrowser.Settling.fast
        settling.scriptTimeout = .milliseconds(300)
        let browser = browser(site, settling: settling)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/a"))

        await #expect(throws: SiteBrowser.Failure.timedOut) {
            _ = try await browser.run("await new Promise(() => {}); return 1;")
        }
    }

    // MARK: Refusals

    @Test("An address the policy does not allow is refused before anything is requested", .timeLimit(.minutes(1)))
    func notAllowed() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        for address in [
            "https://evil.test/",
            "https://example.com.evil.test/",
            "http://example.com/",
            "https://example.com:8443/",
            "https://user@example.com/",
            "file:///etc/hosts",
            "javascript:alert(1)",
        ] {
            await #expect(throws: SiteBrowser.Failure.notAllowed, "\(address)") {
                _ = try await browser.open(url(address))
            }
        }
        #expect(site.requests.isEmpty)
        #expect(browser.currentURL == nil)
    }

    @Test("A page that redirects by script to a host off the list fails with leftSite", .timeLimit(.minutes(1)))
    func scriptRedirectOffSite() async throws {
        let site = TestSite()
        site.route("/jump", page: TestPages.redirect(to: "https://evil.test/landing"))
        site.route("/later", page: TestPages.page("Later", "<p>fine</p>", script: """
            setTimeout(() => { location.href = 'https://evil.test/landing'; }, 100);
            """))
        // Looks 250 ms apart keep the page under watch well past the 100 ms timer.
        var settling = SiteBrowser.Settling.fast
        settling.pollInterval = .milliseconds(250)
        let browser = browser(site, settling: settling)
        defer { browser.close() }

        await #expect(throws: SiteBrowser.Failure.leftSite) {
            _ = try await browser.open(url("https://example.com/jump"))
        }
        await #expect(throws: SiteBrowser.Failure.leftSite) {
            _ = try await browser.open(url("https://example.com/later"))
        }

        #expect(site.requests.allSatisfy { $0.host == "example.com" })
        #expect(browser.refusedNavigations == 2)
        #expect(browser.currentURL?.host != "evil.test")
    }

    @Test("A page that redirects by script to a host on the list is followed", .timeLimit(.minutes(1)))
    func scriptRedirectOnSite() async throws {
        let site = TestSite()
        site.route("/start", page: TestPages.redirect(to: "https://www.example.com/landing"))
        site.route("/landing", host: "www.example.com", page: TestPages.page("Landing", "<p>arrived</p>"))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/start"))

        #expect(page.title == "Landing")
        #expect(page.url == url("https://www.example.com/landing"))
        #expect(browser.visitedHosts.contains("www.example.com"))
    }

    @Test("A form that submits to a host off the list is refused", .timeLimit(.minutes(1)))
    func formToOtherHost() async throws {
        let site = TestSite()
        site.route("/form", page: TestPages.page("Form", """
            <form id="f" method="post" action="https://evil.test/collect"><input name="a" value="1"></form>
            """))
        let browser = browser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/form"))

        let mark = browser.markAction()
        _ = try await browser.run("document.getElementById('f').requestSubmit(); return 1;")
        await #expect(throws: SiteBrowser.Failure.leftSite) {
            try await browser.settleAfterAction(since: mark)
        }

        #expect(site.requests.allSatisfy { $0.host == "example.com" })
        #expect(site.posts.isEmpty)
    }

    @Test("A navigation the site cannot answer fails the load and never reaches the network", .timeLimit(.minutes(1)))
    func unansweredNavigationFails() async throws {
        let site = TestSite()
        site.route("/missing-link", page: TestPages.redirect(to: "/nowhere"))
        let browser = browser(site)
        defer { browser.close() }

        await #expect(throws: SiteBrowser.Failure.loadFailed) {
            _ = try await browser.open(url("https://example.com/nowhere"))
        }
        await #expect(throws: SiteBrowser.Failure.loadFailed) {
            _ = try await browser.open(url("https://example.com/missing-link"))
        }
        #expect(site.requests.map(\.path) == ["/nowhere", "/missing-link", "/nowhere"])
    }

    @Test("Dialogs are answered at once, confirm with false and prompt with nothing", .timeLimit(.minutes(1)))
    func dialogsDoNotHang() async throws {
        let site = TestSite()
        site.route("/dialogs", page: TestPages.page("Before", "<p>x</p>", script: """
            alert('hello');
            const confirmed = confirm('sure?');
            const prompted = prompt('name?', 'default');
            document.title = confirmed + '|' + prompted;
            """))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/dialogs"))

        #expect(page.title == "false|null")
    }

    @Test("A new window is never created", .timeLimit(.minutes(1)))
    func newWindowsAreRefused() async throws {
        let site = TestSite()
        site.route("/windows", page: TestPages.page("Windows", """
            <a id="blank" target="_blank" href="https://example.com/popup">Pop</a>
            """, script: """
            window.open('https://example.com/popup2');
            document.getElementById('blank').click();
            """))
        site.route("/popup", page: TestPages.page("Popup", "popup"))
        site.route("/popup2", page: TestPages.page("Popup two", "popup"))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/windows"))

        #expect(page.title == "Windows")
        #expect(browser.currentURL == url("https://example.com/windows"))
        #expect(site.requests.map(\.path) == ["/windows"])
    }

    @Test("A window the page is allowed to ask for is refused by the browser", .timeLimit(.minutes(1)))
    func newWindowsAreRefusedWhenAllowed() async throws {
        let site = TestSite()
        site.route("/windows", page: TestPages.page("Windows", """
            <a id="blank" target="_blank" href="https://example.com/popup">Pop</a>
            """, script: """
            window.open('https://example.com/popup2');
            document.getElementById('blank').click();
            """))
        site.route("/popup", page: TestPages.page("Popup", "popup"))
        site.route("/popup2", page: TestPages.page("Popup two", "popup"))
        let browser = browser(site)
        defer { browser.close() }
        browser.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let page = try await browser.open(url("https://example.com/windows"))

        #expect(page.title == "Windows")
        #expect(browser.blockedWindows >= 1)
        #expect(browser.currentURL == url("https://example.com/windows"))
        #expect(site.requests.map(\.path) == ["/windows"])
    }

    @Test("A frame from another site is not loaded in a simulated page", .timeLimit(.minutes(1)))
    func frameIsNotLoaded() async throws {
        let site = TestSite()
        site.route("/framed", page: TestPages.page("Framed", """
            <iframe src="https://other.test/frame"></iframe><p>outside</p>
            """))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/framed"))

        #expect(page.text.contains("outside"))
        #expect(!site.requests.contains { $0.host == "other.test" })
        #expect(browser.blockedFrames == 1)
    }

    // MARK: Hosts

    @Test("Hosts of pages that finished loading are recorded, and every host a navigation went through", .timeLimit(.minutes(1)))
    func visitedHosts() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<a href=\"https://www.example.com/b\">B</a>"))
        site.route("/b", host: "www.example.com", page: TestPages.page("B", "b"))
        site.route("/hop", page: TestPages.redirect(to: "https://www.example.com/b"))
        let browser = browser(site)
        defer { browser.close() }

        #expect(browser.visitedHosts.isEmpty)
        _ = try await browser.open(url("https://example.com/a"))
        #expect(browser.visitedHosts == ["example.com"])

        _ = try await browser.open(url("https://www.example.com/b"))
        #expect(browser.visitedHosts == ["example.com", "www.example.com"])
        #expect(browser.traversedHosts == ["example.com", "www.example.com"])

        // A refused address leaves both sets as they were.
        _ = try? await browser.open(url("https://evil.test/"))
        #expect(browser.visitedHosts == ["example.com", "www.example.com"])
    }

    @Test("A host a page was sent through before it finished loading is a traversed host, not a visited one", .timeLimit(.minutes(1)))
    func traversedHosts() async throws {
        let site = TestSite()
        // The identity host answers with a page that moves on at once, before it finishes loading.
        site.route("/sso", host: "www.example.com", page: """
            <!doctype html><html><head><title>Hop</title><script>location.replace('https://example.com/back');</script></head><body></body></html>
            """)
        site.route("/start", page: TestPages.redirect(to: "https://www.example.com/sso"))
        site.route("/back", page: TestPages.page("Back", "<p>home</p>"))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/start"))

        #expect(page.title == "Back")
        #expect(browser.traversedHosts == ["example.com", "www.example.com"])
        #expect(browser.visitedHosts.isSubset(of: browser.traversedHosts))
    }

    @Test("The policy of a browser can be replaced", .timeLimit(.minutes(1)))
    func policyCanChange() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "a"))
        let browser = browser(site, hosts: ["other.example.org"])
        defer { browser.close() }

        await #expect(throws: SiteBrowser.Failure.notAllowed) {
            _ = try await browser.open(url("https://example.com/a"))
        }
        browser.policy = SiteNavigationPolicy(browseHosts: ["example.com"])
        let page = try await browser.open(url("https://example.com/a"))
        #expect(page.title == "A")
    }

    @Test(
        "A fragment of the page that is open is a move within it, and nothing else is",
        arguments: [
            ("https://example.com/p", "https://example.com/p#section", true),
            ("https://example.com/p#one", "https://example.com/p#two", true),
            ("https://example.com/p?q=1", "https://example.com/p?q=1#top", true),
            ("https://example.com/p", "https://example.com/p", false),
            ("https://example.com/p#one", "https://example.com/p", false),
            ("https://example.com/p", "https://example.com/q#section", false),
            ("https://example.com/p?q=1", "https://example.com/p?q=2#top", false),
            ("https://example.com/p", "https://www.example.com/p#section", false),
        ]
    )
    func fragmentMoves(_ current: String, _ target: String, _ within: Bool) {
        #expect(SiteBrowser.isWithinCurrentDocument(URL(string: target)!, current: URL(string: current)) == within)
    }

    @Test("A response that cannot be shown, or that the server marks as an attachment, is refused")
    func refusedResponses() throws {
        func response(_ disposition: String?, type: String = "text/html") throws -> URLResponse {
            var headers = ["Content-Type": type]
            if let disposition { headers["Content-Disposition"] = disposition }
            return try #require(HTTPURLResponse(
                url: url("https://example.com/file"),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ))
        }

        #expect(!SiteBrowser.refusesResponse(canShowMIMEType: true, response: try response(nil)))
        #expect(!SiteBrowser.refusesResponse(canShowMIMEType: true, response: try response("inline")))
        #expect(SiteBrowser.refusesResponse(canShowMIMEType: true, response: try response("attachment; filename=\"a.pdf\"")))
        #expect(SiteBrowser.refusesResponse(canShowMIMEType: true, response: try response("  ATTACHMENT")))
        #expect(SiteBrowser.refusesResponse(canShowMIMEType: false, response: try response(nil, type: "application/zip")))
        let plain = URLResponse(url: url("https://example.com/"), mimeType: "text/html", expectedContentLength: 1, textEncodingName: nil)
        #expect(!SiteBrowser.refusesResponse(canShowMIMEType: true, response: plain))
        #expect(SiteBrowser.refusesResponse(canShowMIMEType: false, response: plain))
    }

    @Test("There is no current document before anything is open", .timeLimit(.minutes(1)))
    func fragmentWithoutADocument() {
        #expect(!SiteBrowser.isWithinCurrentDocument(URL(string: "https://example.com/p#x")!, current: nil))
    }

    @Test("A fragment of the open page is read as a page, as a link to one can be followed", .timeLimit(.minutes(1)))
    func fragmentLoad() async throws {
        let site = TestSite()
        site.route("/p", page: TestPages.page("P", "<p>page</p>"))
        let browser = browser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/p"))

        let started = ContinuousClock.now
        let page = try await browser.open(url("https://example.com/p#section"))

        #expect(page.title == "P")
        #expect(page.url == url("https://example.com/p#section"))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // MARK: Use

    @Test("Two opens at once are taken one after the other", .timeLimit(.minutes(1)))
    func opensAreSerial() async throws {
        let site = TestSite()
        site.route("/one", page: TestPages.page("One", "one"))
        site.route("/two", page: TestPages.page("Two", "two"))
        let browser = browser(site)
        defer { browser.close() }

        async let first = browser.open(url("https://example.com/one"))
        async let second = browser.open(url("https://example.com/two"))
        let pages = try await [first, second]

        #expect(pages.map(\.title) == ["One", "Two"])
        #expect(browser.currentURL == url("https://example.com/two"))
    }

    @Test("A snapshot reads the page as it is now", .timeLimit(.minutes(1)))
    func snapshotReadsNow() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p id=\"t\">before</p>"))
        let browser = browser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/a"))

        _ = try await browser.run("document.getElementById('t').textContent = 'after'; return 1;")
        let page = try await browser.snapshot()

        #expect(page.text == "after")
    }

    @Test("Page text is cleaned: control characters, bidirectional overrides, and runs of blank lines", .timeLimit(.minutes(1)))
    func pageTextIsCleaned() async throws {
        let site = TestSite()
        site.route("/hostile", page: TestPages.page("Host\u{202E}ile", """
            <p>Balance \u{202E}drowssap\u{202C}</p><p>&#x1B;[31mred</p><br><br><br><br><p>after</p>
            """))
        let browser = browser(site)
        defer { browser.close() }

        let page = try await browser.open(url("https://example.com/hostile"))

        #expect(page.title == "Hostile")
        #expect(page.text.unicodeScalars.allSatisfy { $0.value != 0x202E && $0.value != 0x1B })
        #expect(!page.text.contains("\n\n\n"))
        #expect(page.text.contains("Balance drowssap"))
    }
}
