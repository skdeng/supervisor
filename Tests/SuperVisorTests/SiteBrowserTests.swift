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

        #expect(agent.string?.hasSuffix(SiteBrowser.agentSuffix) == true)
        #expect(SiteBrowser.agentSuffix.range(
            of: #"\AVersion/[0-9]{1,3}(\.[0-9]{1,3}){0,2} Safari/605\.1\.15\z"#,
            options: .regularExpression
        ) != nil)
    }

    @Test("A typing message names a kind of field and nothing else")
    func typedFieldMessages() {
        #expect(SiteBrowser.TypedField(messageBody: "password") == .password)
        #expect(SiteBrowser.TypedField(messageBody: "other") == .other)

        #expect(SiteBrowser.TypedField(messageBody: "Password") == nil)
        #expect(SiteBrowser.TypedField(messageBody: "") == nil)
        #expect(SiteBrowser.TypedField(messageBody: NSNull()) == nil)
        #expect(SiteBrowser.TypedField(messageBody: ["password"]) == nil)
        #expect(SiteBrowser.TypedField(messageBody: 1) == nil)
    }

    @Test("Typing into a password field reaches both observers; into any other field, one")
    func typingObservers() {
        let browser = SiteBrowser(policy: .anyHTTPSHost, dataStore: .nonPersistent(), observation: .typing)
        defer { browser.close() }
        var passwords = 0
        var any = 0
        browser.passwordTypedObserver = { passwords += 1 }
        browser.typedObserver = { any += 1 }

        browser.noteTyped(into: .other)
        #expect((passwords, any) == (0, 1))
        browser.noteTyped(into: .password)
        #expect((passwords, any) == (1, 2))

        browser.close()
        browser.noteTyped(into: .password)
        #expect((passwords, any) == (1, 2))
    }

    @Test("Typing observers also work in a browser that observes credentials")
    func typingObserversWithCredentials() {
        let browser = SiteBrowser(
            policy: .anyHTTPSHost,
            dataStore: .nonPersistent(),
            observation: .typingAndCredentials
        )
        defer { browser.close() }
        var passwords = 0
        var any = 0
        browser.passwordTypedObserver = { passwords += 1 }
        browser.typedObserver = { any += 1 }

        browser.noteTyped(into: .password)

        #expect((passwords, any) == (1, 1))
    }

    @Test("The agent string carries the installed Safari's version, else the system's")
    func agentVersion() {
        let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 0)

        #expect(SiteBrowser.safariVersion(installed: "27.0.1", system: system) == "27.0.1")
        #expect(SiteBrowser.safariVersion(installed: "18", system: system) == "18")
        #expect(SiteBrowser.safariVersion(installed: nil, system: system) == "27.1")
        // A value that is not a version never reaches a header.
        #expect(SiteBrowser.safariVersion(installed: "27.0\r\nX-Injected: 1", system: system) == "27.1")
        #expect(SiteBrowser.safariVersion(installed: "", system: system) == "27.1")
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

    @Test("Closing a browser while a script is waiting answers the script with closed, once", .timeLimit(.minutes(1)))
    func closeDuringScript() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        // A script that never answers, and a limit it would take ten minutes to reach.
        var settling = SiteBrowser.Settling.fast
        settling.scriptTimeout = .seconds(600)
        let browser = browser(site, settling: settling)
        _ = try await browser.open(url("https://example.com/a"))

        let running = Task { @MainActor in try await browser.run("await new Promise(() => {}); return 1;") }
        while browser.pendingScriptCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(browser.pendingScriptCount == 1)
        browser.close()

        await #expect(throws: SiteBrowser.Failure.closed) { _ = try await running.value }
        #expect(browser.pendingScriptCount == 0)
        // Closing again is harmless.
        browser.close()
    }

    @Test("A script that answers is no longer waiting, and one that does not is answered by the script limit", .timeLimit(.minutes(1)))
    func scriptAnswers() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>x</p>"))
        var settling = SiteBrowser.Settling.fast
        settling.scriptTimeout = .milliseconds(300)
        let browser = browser(site, settling: settling)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/a"))

        let answered = try await browser.run("return 7;")
        #expect(answered.int == 7)
        #expect(browser.pendingScriptCount == 0)

        await #expect(throws: SiteBrowser.Failure.timedOut) {
            _ = try await browser.run("await new Promise(() => {}); return 1;")
        }
        #expect(browser.pendingScriptCount == 0)
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

        // Each open answers with its own page, which two loads overlapping in one web view
        // would not. Which of the two ran last is the scheduler's choice.
        #expect(pages.map(\.title) == ["One", "Two"])
        #expect([url("https://example.com/one"), url("https://example.com/two")].contains(browser.currentURL))
    }

    @Test("A script that never answers ends at the limit its caller gives, and the browser goes on", .timeLimit(.minutes(1)))
    func scriptLimit() async throws {
        let site = TestSite()
        site.route("/a", page: TestPages.page("A", "<p>a</p>"))
        let browser = browser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/a"))

        await #expect(throws: SiteBrowser.Failure.timedOut) {
            _ = try await browser.run("await new Promise(() => {}); return 1;", timeout: .milliseconds(100))
        }
        #expect(browser.pendingScriptCount == 0)
        #expect(try await browser.run("return 2;").int == 2)
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

    // MARK: Credentials

    private func credentialBrowser(
        _ site: TestSite,
        observation: SiteBrowser.Observation = .typingAndCredentials
    ) -> SiteBrowser {
        SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: hosts),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast,
            observation: observation
        )
    }

    private static let signInForm = """
        <form id="f" method="post" action="https://example.com/session">
        <input id="user" name="username" autocomplete="username" value="alice@example.com">
        <input id="pass" type="password" name="password" autocomplete="current-password" value="s3cret-Value">
        </form>
        """

    /// Waits up to five seconds for `condition`, which a message from the page makes true.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Runs the credential script's own report builder on the element with `id` and posts what it
    /// returns to the message handler, the way the listener does once an event is trusted.
    private func postReport(_ browser: SiteBrowser, element id: String, edit: String = "") async throws {
        _ = try await browser.run(SiteBrowser.credentialHelpersScript + """

            const message = credentialMessage(document.getElementById('\(id)'));
            \(edit)
            window.webkit.messageHandlers.\(SiteBrowser.credentialMessage).postMessage(message);
            return 1;
            """)
    }

    @Test("An input event a script dispatches is never reported as typed credentials", .timeLimit(.minutes(1)))
    func untrustedInputIsNotReported() async throws {
        let site = TestSite()
        // The page's own script, which runs in the page's world, dispatches input events as the
        // page loads.
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm, script: """
            for (const id of ['user', 'pass']) {
              const field = document.getElementById(id);
              field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
              field.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data: 'x' }));
            }
            """))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        _ = try await browser.open(url("https://example.com/login"))

        // The isolated world, where the app's own fills run, dispatches too.
        _ = try await browser.run("""
            for (const id of ['user', 'pass']) {
              const field = document.getElementById(id);
              field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
              field.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data: 'x' }));
            }
            return 1;
            """)
        try await Task.sleep(for: .milliseconds(300))

        #expect(received.isEmpty)
        #expect(browser.droppedCredentials == 0)

        // The channel is open: a report posted to the same handler reaches the observer, so
        // silence above is the script's refusal and not a missing handler.
        try await postReport(browser, element: "pass")
        try await waitUntil { !received.isEmpty }
        #expect(received.count == 1)
        #expect(browser.droppedCredentials == 0)
    }

    @Test("A report posted from the main frame reaches the observer with what the page showed", .timeLimit(.minutes(1)))
    func reportReachesObserver() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        _ = try await browser.open(url("https://example.com/login"))

        try await postReport(browser, element: "user")
        try await postReport(browser, element: "pass")
        try await waitUntil { received.count == 2 }

        try #require(received.count == 2)
        let user = received[0]
        #expect(user.kind == .username)
        #expect(user.value == "alice@example.com")
        #expect(user.field == FieldKey(name: "username", id: "user", autocomplete: "username", type: ""))
        let pass = received[1]
        #expect(pass.kind == .password)
        #expect(pass.value == "s3cret-Value")
        #expect(pass.field == FieldKey(
            name: "password", id: "pass", autocomplete: "current-password", type: "password"
        ))
        for credential in received {
            #expect(credential.origin == "https://example.com")
            #expect(credential.path == "/login")
            #expect(credential.actionHost == "example.com")
            #expect(credential.passwordFields == 1)
            #expect(credential.newPassword == false)
        }
        #expect(browser.droppedCredentials == 0)
    }

    @Test("A report that fails a check is counted and never reaches the observer", .timeLimit(.minutes(1)))
    func failedReportIsDropped() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        _ = try await browser.open(url("https://example.com/login"))

        // The origin the message claims is not the frame's.
        try await postReport(browser, element: "pass", edit: "message.origin = 'https://evil.example.org';")
        try await waitUntil { browser.droppedCredentials == 1 }
        // A key a report does not have.
        try await postReport(browser, element: "pass", edit: "message.extra = 'x';")
        try await waitUntil { browser.droppedCredentials == 2 }
        // A user name typed as a password.
        try await postReport(browser, element: "user", edit: "message.kind = 'password';")
        try await waitUntil { browser.droppedCredentials == 3 }

        #expect(browser.droppedCredentials == 3)
        #expect(received.isEmpty)

        try await postReport(browser, element: "pass")
        try await waitUntil { !received.isEmpty }
        #expect(received.count == 1)
        #expect(browser.droppedCredentials == 3)
    }

    @Test("A report posted after the browser closed is not delivered, and a closed browser takes none", .timeLimit(.minutes(1)))
    func closedBrowserDeliversNothing() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let browser = credentialBrowser(site)
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        _ = try await browser.open(url("https://example.com/login"))
        try await postReport(browser, element: "pass")
        try await waitUntil { received.count == 1 }
        #expect(received.count == 1)

        browser.close()

        #expect(browser.credentialObserver == nil)
        let credential = try #require(typedCredential())
        browser.noteCredential(credential)
        #expect(received.count == 1)
    }

    @Test("A credential noted reaches the observer, and stops reaching it once the browser closes")
    func noteCredential() throws {
        let browser = SiteBrowser(
            policy: .anyHTTPSHost,
            dataStore: .nonPersistent(),
            observation: .typingAndCredentials
        )
        defer { browser.close() }
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        let credential = try #require(typedCredential())

        browser.noteCredential(credential)
        browser.noteCredential(credential)
        #expect(received.count == 2)
        #expect(received.first == credential)

        browser.close()
        browser.noteCredential(credential)
        #expect(received.count == 2)
        #expect(browser.credentialObserver == nil)
    }

    @Test("Only a browser made to observe credentials has the script and its handler", .timeLimit(.minutes(1)))
    func observationLevels() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let probe = """
            const handlers = window.webkit && window.webkit.messageHandlers;
            return {
              credential: handlers ? typeof handlers.\(SiteBrowser.credentialMessage) : 'no handlers',
              typing: handlers ? typeof handlers.\(SiteBrowser.typingMessage) : 'no handlers'
            };
            """

        let levels: [(SiteBrowser.Observation, scripts: Int, credential: String, typing: String)] = [
            (.none, 0, "no handlers", "no handlers"),
            (.typing, 1, "undefined", "object"),
            (.typingAndCredentials, 2, "object", "object"),
        ]
        for (observation, scripts, credential, typing) in levels {
            let browser = credentialBrowser(site, observation: observation)
            defer { browser.close() }
            _ = try await browser.open(url("https://example.com/login"))

            let installed = browser.webView.configuration.userContentController.userScripts
            #expect(installed.count == scripts, "\(observation)")
            let facts = try await browser.run(probe)
            #expect(facts["credential"]?.string == credential, "\(observation)")
            #expect(facts["typing"]?.string == typing, "\(observation)")

            let credentialScripts = installed.filter { $0.source.contains(SiteBrowser.credentialMessage) }
            #expect(credentialScripts.count == (observation == .typingAndCredentials ? 1 : 0), "\(observation)")
            for script in credentialScripts {
                #expect(script.isForMainFrameOnly)
                #expect(script.injectionTime == .atDocumentStart)
            }
            for script in installed where !credentialScripts.contains(script) {
                #expect(!script.isForMainFrameOnly)
                #expect(script.injectionTime == .atDocumentStart)
            }
        }
    }

    @Test("The page's own world has no message handler to post to", .timeLimit(.minutes(1)))
    func pageWorldHasNoHandler() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/login"))

        let reachable = try await browser.webView.evaluateJavaScript("""
            typeof window.webkit === 'undefined' ? 'no webkit'
              : typeof window.webkit.messageHandlers.\(SiteBrowser.credentialMessage)
            """) as? String

        // The page's world has no `window.webkit`, or has one with no such handler.
        #expect(["no webkit", "undefined"].contains(reachable))
    }

    // MARK: The credential script's field rules

    /// What the report builder returns for each element of `page`, by id, evaluated in the
    /// isolated world the listener runs in. A field that is not reported is `null`.
    private func reports(
        for page: String,
        script: String = ""
    ) async throws -> (browser: SiteBrowser, kinds: [String: String]) {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", page))
        let browser = credentialBrowser(site)
        _ = try await browser.open(url("https://example.com/login"))
        let value = try await browser.run(SiteBrowser.credentialHelpersScript + """

            \(script)
            const kinds = {};
            for (const input of document.querySelectorAll('input[id]')) {
              const message = credentialMessage(input);
              kinds[input.id] = message === null ? 'none' : message.kind;
            }
            return kinds;
            """)
        guard case let .object(object) = value else { return (browser, [:]) }
        return (browser, object.compactMapValues { $0.string })
    }

    @Test("Only password fields and user name fields are reported, never a code field, a masked code or PIN, or any other", .timeLimit(.minutes(1)))
    func fieldKinds() async throws {
        let (browser, kinds) = try await reports(for: """
            <input id="plain-user" name="username" value="u">
            <input id="email-type" type="email" name="x" value="e@example.com">
            <input id="password" type="password" name="p" value="p">
            <input id="search" name="q" value="s">
            <input id="code-by-token" name="user_code" autocomplete="one-time-code" value="123456">
            <input id="code-by-word" name="userCode" value="123456">
            <input id="masked-code" type="password" name="otp" autocomplete="one-time-code" value="123456">
            <input id="masked-otp" type="password" name="otp" value="123456">
            <input id="masked-pin" type="password" name="pin" value="1234">
            <input id="masked-cvv" type="password" name="card_cvv" value="123">
            <input id="masked-answer" type="password" name="securityAnswer" value="rex">
            <input id="masked-memorable" type="password" name="memorableWord" value="word">
            <input id="empty" name="username" value="">
            <input id="empty-password" type="password" name="password" value="">
            <input id="login-password" name="loginPassword" value="x">
            <input id="current-password-text" name="user" autocomplete="current-password" value="x">
            <input id="number-user" type="number" name="user" value="1">
            <input id="checkbox-user" type="checkbox" name="user" value="1">
            <input id="hidden-user" type="hidden" name="user" value="1">
            """)
        defer { browser.close() }

        #expect(kinds == [
            "plain-user": "username", "email-type": "username", "password": "password", "search": "none",
            "code-by-token": "none", "code-by-word": "none", "masked-code": "none", "masked-otp": "none",
            "masked-pin": "none", "masked-cvv": "none", "masked-answer": "none", "masked-memorable": "none",
            "empty": "clear", "empty-password": "clear",
            "login-password": "none", "current-password-text": "none", "number-user": "none",
            "checkbox-user": "none", "hidden-user": "none",
        ])
    }

    @Test("A password field that a toggle turned into a text input is still a password", .timeLimit(.minutes(1)))
    func toggledPassword() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", """
            <input id="toggled" type="password" name="loginPassword" value="pw">
            <input id="never-password" type="text" name="loginPassword" value="pw">
            """))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/login"))

        let reports = try await browser.run(SiteBrowser.credentialHelpersScript + """

            document.getElementById('toggled').type = 'text';
            await Promise.resolve();
            return {
              toggled: credentialMessage(document.getElementById('toggled')),
              never: credentialMessage(document.getElementById('never-password'))
            };
            """)

        #expect(reports["toggled"]?["kind"]?.string == "password")
        #expect(reports["toggled"]?["type"]?.string == "password")
        #expect(reports["toggled"]?["name"]?.string == "loginPassword")
        #expect(reports["never"] == .null)
    }

    @Test("The report names the field as the page spells it, and counts the page's passwords", .timeLimit(.minutes(1)))
    func reportFacts() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", """
            <form action="https://login.example.com/session" method="post">
            <input id="user" name="user" autocomplete="  Section-Login USERNAME " value="alice">
            <input id="current" type="password" name="current" value="old">
            <input id="next" type="password" name="next" autocomplete="new-password" value="new">
            <input name="action" value="clobber">
            </form>
            """))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/login"))

        let user = try await browser.run(SiteBrowser.credentialHelpersScript
            + "\nreturn credentialMessage(document.getElementById('user'));")
        let current = try await browser.run(SiteBrowser.credentialHelpersScript
            + "\nreturn credentialMessage(document.getElementById('current'));")

        #expect(user["kind"]?.string == "username")
        #expect(user["autocomplete"]?.string == "section-login username")
        #expect(user["type"]?.string == "")
        #expect(user["actionHost"]?.string == "login.example.com")
        #expect(user["passwordFields"]?.int == 2)
        #expect(user["newPassword"]?.bool == true)
        #expect(current["kind"]?.string == "password")
        #expect(current["autocomplete"]?.string == "")
        #expect(current["newPassword"]?.bool == true)
        // The named input `action` shadows the form's `action` property, not its attribute.
        #expect(current["actionHost"]?.string == "login.example.com")
    }

    @Test("The action host is the host of the form's own https action, and empty otherwise", .timeLimit(.minutes(1)))
    func actionHosts() async throws {
        let cases: [(String, String)] = [
            ("action=\"https://login.example.com/session\"", "login.example.com"),
            ("action=\"/session\"", "example.com"),
            ("", "example.com"),
            ("action=\"http://example.com/session\"", ""),
            ("action=\"javascript:void(0)\"", ""),
            ("action=\"https://[bad\"", ""),
        ]
        for (attribute, expected) in cases {
            let site = TestSite()
            site.route("/login", page: TestPages.page("Sign in", """
                <form \(attribute) method="post"><input id="pass" type="password" value="p"></form>
                <input id="loose" type="password" value="q">
                """))
            let browser = credentialBrowser(site)
            defer { browser.close() }
            _ = try await browser.open(url("https://example.com/login"))

            let inForm = try await browser.run(SiteBrowser.credentialHelpersScript
                + "\nreturn credentialMessage(document.getElementById('pass'));")
            let outside = try await browser.run(SiteBrowser.credentialHelpersScript
                + "\nreturn credentialMessage(document.getElementById('loose'));")

            #expect(inForm["actionHost"]?.string == expected, "\(attribute)")
            #expect(outside["actionHost"]?.string == "", "a field with no form")
        }
    }

    @Test("The path is the page's own, which a change of address by script moves", .timeLimit(.minutes(1)))
    func pathFollowsThePage() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/login"))

        let message = try await browser.run(SiteBrowser.credentialHelpersScript + """

            history.pushState(null, '', '/login/step-two?x=1#y');
            return credentialMessage(document.getElementById('pass'));
            """)

        #expect(message["path"]?.string == "/login/step-two")
        #expect(message["origin"]?.string == "https://example.com")
    }

    @Test("A page with more password inputs than a report counts reports the cap, and a long value is not reported", .timeLimit(.minutes(1)))
    func capsAndLongValues() async throws {
        let site = TestSite()
        let passwords = (1...12).map { "<input id=\"p\($0)\" type=\"password\" value=\"x\">" }.joined()
        site.route("/login", page: TestPages.page("Sign in", passwords))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/login"))

        let message = try await browser.run(SiteBrowser.credentialHelpersScript
            + "\nreturn credentialMessage(document.getElementById('p1'));")
        #expect(message["passwordFields"]?.int == TypedCredential.maximumPasswordFields)

        let lengths = try await browser.run(SiteBrowser.credentialHelpersScript + """

            const field = document.getElementById('p1');
            const results = [];
            for (const length of [16384, 16385]) {
              field.value = 'x'.repeat(length);
              const message = credentialMessage(field);
              results.push(message === null ? -1 : message.value.length);
            }
            return results;
            """)
        #expect(lengths.array?.compactMap { $0.int } == [16384, -1])
    }

    @Test("The script's user name and code rules reach the same verdicts as the rules the sign-in uses", .timeLimit(.minutes(1)))
    func scriptAgreesWithSignInRules() async throws {
        struct Hints {
            var name = ""
            var id = ""
            var autocomplete = ""
            var type = ""
            var inputMode = ""
            var maxLength: Int?
        }
        let rows: [Hints] = [
            Hints(name: "username"),
            Hints(id: "user-email"),
            Hints(autocomplete: "email"),
            Hints(autocomplete: "username"),
            Hints(type: "email"),
            Hints(name: "memberNumber"),
            Hints(name: "accountId", type: "text"),
            Hints(name: "LOGIN"),
            Hints(name: "q"),
            Hints(name: "user", type: "search"),
            Hints(name: "user", type: "number"),
            Hints(name: "user", type: "url"),
            Hints(name: "user", type: "tel"),
            Hints(name: "user_code"),
            Hints(name: "userCode"),
            Hints(name: "userPromoCode"),
            Hints(name: "zip_code_user"),
            Hints(name: "user", autocomplete: "one-time-code"),
            Hints(name: "user", inputMode: "numeric", maxLength: 6),
            Hints(name: "user", inputMode: "numeric", maxLength: 4),
            Hints(name: "user", inputMode: "numeric", maxLength: 8),
            Hints(name: "user", inputMode: "numeric", maxLength: 9),
            Hints(name: "user", inputMode: "numeric", maxLength: 3),
            Hints(name: "user", inputMode: "text", maxLength: 6),
            Hints(name: "user_pin"),
            Hints(name: "userpin"),
            Hints(name: "2fa_user"),
            Hints(name: "user", id: "mfa"),
            Hints(name: "token_user"),
            Hints(name: "verify-user"),
            Hints(name: "verified_user"),
            Hints(name: "user", id: "opinion"),
            Hints(name: "shipping_email"),
            Hints(name: "user_phone", type: "tel"),
            Hints(name: "email", id: "referral"),
            Hints(name: "x", type: "password"),
            Hints(name: "user", type: "password"),
            Hints(name: "password", type: "password"),
            Hints(name: "otp", type: "password"),
            Hints(id: "pin", type: "password"),
            Hints(name: "user_pin", type: "password"),
            Hints(name: "passcode", type: "password"),
            Hints(name: "pass_code", type: "password"),
            Hints(name: "cardCvv", type: "password"),
            Hints(name: "cvc2", type: "password"),
            Hints(name: "memorable-word", type: "password"),
            Hints(name: "securityAnswer", type: "password"),
            Hints(name: "answer", type: "password"),
            Hints(name: "zip_pin", type: "password"),
            Hints(name: "promo_code", type: "password"),
            Hints(name: "opinion", type: "password"),
            Hints(name: "secured", type: "password"),
        ]
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", "<p>fields</p>"))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        _ = try await browser.open(url("https://example.com/login"))

        let arguments: [[String: Any]] = rows.map { row in
            [
                "name": row.name, "id": row.id, "autocomplete": row.autocomplete, "type": row.type,
                "inputmode": row.inputMode, "maxlength": row.maxLength.map(String.init) ?? "",
            ]
        }
        let result = try await browser.run(SiteBrowser.credentialHelpersScript + """

            const kinds = [];
            for (const row of rows) {
              const input = document.createElement('input');
              for (const key of ['name', 'id', 'autocomplete', 'type', 'inputmode', 'maxlength']) {
                if (row[key] !== '') input.setAttribute(key, row[key]);
              }
              input.value = '1';
              document.body.appendChild(input);
              const message = credentialMessage(input);
              kinds.push(message === null ? 'none' : message.kind);
            }
            return kinds;
            """, arguments: ["rows": arguments])
        let kinds = try #require(result.array?.compactMap { $0.string })
        try #require(kinds.count == rows.count)

        for (row, kind) in zip(rows, kinds) {
            let field = ProbedField(
                key: FieldKey(name: row.name, id: row.id, autocomplete: row.autocomplete, type: row.type),
                inputMode: row.inputMode,
                maxLength: row.maxLength
            )
            let page = PageProbe(
                origin: "https://example.com", path: "/login", isSecureTopFrame: true,
                hasChallenge: false, fields: [field]
            )
            let expected: String
            if row.type == "password" {
                expected = SignInRules.isMaskedNonPassword(field.key) ? "none" : "password"
            } else {
                expected = SignInRules.showsUserNameField(page) ? "username" : "none"
            }
            #expect(kind == expected, "\(row)")
        }
        #expect(kinds.filter { $0 == "username" }.count >= 10)
        #expect(kinds.filter { $0 == "none" }.count >= 10)
        #expect(kinds.filter { $0 == "password" }.count >= 6)
    }

    @Test("An emptied field is reported as a clear that names the field and page and carries no value", .timeLimit(.minutes(1)))
    func clearReport() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", Self.signInForm))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        _ = try await browser.open(url("https://example.com/login"))

        try await postReport(browser, element: "pass")
        try await waitUntil { !received.isEmpty }
        #expect(received.first?.kind == .password)

        let message = try await browser.run(SiteBrowser.credentialHelpersScript + """

            const field = document.getElementById('pass');
            field.value = '';
            return credentialMessage(field);
            """)
        #expect(message["kind"]?.string == "clear")
        #expect(message["value"] == nil)
        #expect(message["type"]?.string == "password")
        #expect(message["path"]?.string == "/login")

        try await postReport(browser, element: "pass")
        try await waitUntil { received.count == 2 }
        #expect(received.last?.kind == .cleared)
        #expect(received.last?.field == FieldKey(name: "password", id: "pass", autocomplete: "current-password", type: "password"))
        #expect(browser.droppedCredentials == 0)
    }

    @Test("What the page's own scripts do to prototypes and form names leaves a report unchanged", .timeLimit(.minutes(1)))
    func pageWorldTampering() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Sign in", """
            <form id="f" method="post" action="https://example.com/session">
            <input id="user" name="username" autocomplete="username" value="alice@example.com">
            <input id="pass" type="password" name="password" autocomplete="current-password" value="s3cret-Value">
            <input name="action" value="https://evil.test/steal">
            <input name="id" value="clobbered">
            </form>
            """, script: """
            const valueDescriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            Object.defineProperty(HTMLInputElement.prototype, 'value', {
              get() { return 'patched-value'; },
              set(v) { valueDescriptor.set.call(this, v); },
              configurable: true
            });
            Object.defineProperty(HTMLInputElement.prototype, 'type', { get() { return 'text'; }, configurable: true });
            Element.prototype.getAttribute = function () { return 'patched-attribute'; };
            Document.prototype.querySelectorAll = function () { return []; };
            Object.defineProperty(Document.prototype, 'URL', { get() { return 'https://evil.test/'; }, configurable: true });
            try { window.webkit = { messageHandlers: {} }; } catch (error) {}
            for (const id of ['user', 'pass']) {
              const field = document.getElementById(id);
              field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            }
            window.pageWorldPatched = true;
            """))
        let browser = credentialBrowser(site)
        defer { browser.close() }
        var received: [TypedCredential] = []
        browser.credentialObserver = { received.append($0) }
        _ = try await browser.open(url("https://example.com/login"))
        let patched = try await browser.webView.evaluateJavaScript(
            "document.getElementById('pass').value + '|' + (window.pageWorldPatched === true)"
        ) as? String
        #expect(patched == "patched-value|true")

        let user = try await browser.run(SiteBrowser.credentialHelpersScript
            + "\nreturn credentialMessage(document.getElementById('user'));")
        let pass = try await browser.run(SiteBrowser.credentialHelpersScript
            + "\nreturn credentialMessage(document.getElementById('pass'));")

        #expect(user["kind"]?.string == "username")
        #expect(user["value"]?.string == "alice@example.com")
        #expect(user["name"]?.string == "username")
        #expect(pass["kind"]?.string == "password")
        #expect(pass["value"]?.string == "s3cret-Value")
        #expect(pass["name"]?.string == "password")
        #expect(pass["id"]?.string == "pass")
        #expect(pass["actionHost"]?.string == "example.com")
        #expect(pass["passwordFields"]?.int == 1)
        #expect(received.isEmpty)
        #expect(browser.droppedCredentials == 0)
    }
}
