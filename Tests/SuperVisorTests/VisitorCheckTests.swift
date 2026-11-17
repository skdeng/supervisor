import Foundation
import Testing
import WebKit

@testable import SuperVisor

private func probe(
    origin: String = "https://example.com",
    path: String = "/account",
    fields: [ProbedField] = [],
    challenge: Bool = false,
    loginFrame: Bool = false,
    signIn: Bool = false,
    signOut: Bool = false,
    secure: Bool = true
) -> PageProbe {
    PageProbe(
        origin: origin,
        path: path,
        isSecureTopFrame: secure,
        hasChallenge: challenge,
        fields: fields,
        hasSignOutControl: signOut,
        hasSignInControl: signIn,
        hasLoginFrame: loginFrame
    )
}

private let passwordField = ProbedField(
    key: FieldKey(name: "password", id: "pass", autocomplete: "current-password", type: "password"),
    inputMode: "",
    maxLength: nil
)

private let emailField = ProbedField(
    key: FieldKey(name: "email", id: "email", autocomplete: "email", type: "email"),
    inputMode: "",
    maxLength: nil
)

private let userField = ProbedField(
    key: FieldKey(name: "username", id: "user", autocomplete: "username", type: "text"),
    inputMode: "",
    maxLength: nil
)

private let searchField = ProbedField(
    key: FieldKey(name: "q", id: "search", autocomplete: "", type: "search"),
    inputMode: "",
    maxLength: nil
)

private let plainTextField = ProbedField(
    key: FieldKey(name: "q", id: "search", autocomplete: "", type: "text"),
    inputMode: "",
    maxLength: nil
)

@Suite("Visitor check verdict")
struct VisitorVerdictTests {
    private func verdict(
        signedIn: PageProbe = probe(),
        _ visitor: VisitorOutcome
    ) -> VisitorVerdict {
        VisitorCheck.verdict(signedIn: signedIn, visitor: visitor)
    }

    @Test("A load that failed, or one taken off the site's hosts, says nothing")
    func outcomesWithNoPage() {
        #expect(verdict(.failed) == .inconclusive)
        #expect(verdict(.leftSite) == .inconclusive)
        #expect(verdict(signedIn: probe(signIn: true), .leftSite) == .inconclusive)
    }

    @Test("A challenge says the visitor is unverified, not signed out, unless the page also asks for a sign-in")
    func challenge() {
        // On the signed-in page's address and on another page.
        #expect(verdict(.page(probe(challenge: true))) == .inconclusive)
        #expect(verdict(.page(probe(challenge: true, signIn: true))) == .inconclusive)
        #expect(verdict(.page(probe(path: "/login", challenge: true))) == .inconclusive)
        #expect(verdict(.page(probe(path: "/login", fields: [emailField], challenge: true))) == .inconclusive)
        #expect(verdict(.page(probe(origin: "https://other.example.com", challenge: true, signIn: true))) == .inconclusive)

        // A page that asks for a sign-in as well is a sign-in page.
        #expect(verdict(.page(probe(fields: [passwordField], challenge: true))) == .asksForSignIn)
        #expect(verdict(.page(probe(path: "/login", fields: [passwordField], challenge: true))) == .redirects)
    }

    @Test("At the signed-in page's address, a page that asks for a sign-in outranks a sign-in control, which outranks nothing")
    func sameAddress() {
        let code = ProbedField(
            key: FieldKey(name: "otp", id: "", autocomplete: "one-time-code", type: "text"),
            inputMode: "",
            maxLength: nil
        )
        let box = ProbedField(key: FieldKey(name: "", id: "", autocomplete: "", type: "text"), inputMode: "", maxLength: 1)

        #expect(verdict(.page(probe(fields: [passwordField]))) == .asksForSignIn)
        #expect(verdict(.page(probe(fields: [code]))) == .asksForSignIn)
        #expect(verdict(.page(probe(fields: Array(repeating: box, count: 6)))) == .asksForSignIn)
        #expect(verdict(.page(probe(loginFrame: true))) == .asksForSignIn)
        #expect(verdict(.page(probe(fields: [passwordField], signIn: true))) == .asksForSignIn)
        // A user-name field alone does not ask for a sign-in, here.
        #expect(verdict(.page(probe(fields: [emailField]))) == .looksTheSame)

        #expect(verdict(.page(probe(signIn: true))) == .showsSignInControl)
        #expect(verdict(signedIn: probe(signOut: true), .page(probe(signIn: true))) == .showsSignInControl)
        #expect(verdict(signedIn: probe(signIn: true), .page(probe(signIn: true))) == .looksTheSame)

        #expect(verdict(.page(probe())) == .looksTheSame)
        #expect(verdict(signedIn: probe(signOut: true), .page(probe())) == .looksTheSame)
        #expect(verdict(signedIn: probe(signOut: true), .page(probe(signOut: true))) == .looksTheSame)
        #expect(verdict(signedIn: probe(signIn: true), .page(probe())) == .looksTheSame)
    }

    @Test("A path is the same page when its percent-decoded forms are")
    func encodedPaths() {
        let signedIn = probe(path: "/my%20account")
        #expect(verdict(signedIn: signedIn, .page(probe(path: "/my account"))) == .looksTheSame)
        #expect(verdict(signedIn: signedIn, .page(probe(path: "/my%20account"))) == .looksTheSame)
        #expect(verdict(signedIn: probe(path: "/my account"), .page(probe(path: "/my%20account"))) == .looksTheSame)
        // Paths that differ once decoded are other pages, which say nothing without a sign-in.
        #expect(verdict(signedIn: signedIn, .page(probe(path: "/my%2Faccount"))) == .inconclusive)
        #expect(verdict(signedIn: probe(path: "/%zz"), .page(probe(path: "/%yy"))) == .inconclusive)
        #expect(verdict(signedIn: signedIn, .page(probe(path: "/my%2Faccount", fields: [passwordField]))) == .redirects)
    }

    @Test("Another page on the site that asks for a sign-in or a user name is a redirect, whatever else it shows")
    func redirectToASignInPage() {
        #expect(verdict(.page(probe(path: "/login", fields: [passwordField]))) == .redirects)
        #expect(verdict(.page(probe(path: "/login", fields: [emailField]))) == .redirects)
        #expect(verdict(.page(probe(path: "/login", fields: [userField]))) == .redirects)
        #expect(verdict(.page(probe(path: "/login", loginFrame: true))) == .redirects)
        #expect(verdict(.page(probe(origin: "https://login.example.com", path: "/", fields: [emailField]))) == .redirects)
        #expect(verdict(.page(probe(origin: "https://www.example.com", fields: [passwordField]))) == .redirects)
        // A sign-in control does not change that.
        #expect(verdict(.page(probe(path: "/login", fields: [passwordField], signIn: true))) == .redirects)
        #expect(verdict(.page(probe(path: "/login", fields: [emailField], signIn: true))) == .redirects)
    }

    @Test("Another page with only a sign-in control the signed-in page lacks shows that control, and one with nothing proves nothing")
    func redirectToAnotherPage() {
        // A locale home page that offers to sign in.
        #expect(verdict(.page(probe(path: "/en/", signIn: true))) == .showsSignInControl)
        #expect(verdict(signedIn: probe(signOut: true), .page(probe(path: "/en/", signIn: true))) == .showsSignInControl)
        #expect(verdict(signedIn: probe(signIn: true), .page(probe(path: "/en/", signIn: true))) == .inconclusive)
        // A consent, locale, or landing page that shows neither.
        #expect(verdict(.page(probe(path: "/consent"))) == .inconclusive)
        #expect(verdict(.page(probe(path: "/en/"))) == .inconclusive)
        #expect(verdict(.page(probe(origin: "https://www.example.com"))) == .inconclusive)
        #expect(verdict(signedIn: probe(signIn: true), .page(probe(path: "/en/"))) == .inconclusive)
        // A search box is not a user-name field.
        #expect(verdict(.page(probe(path: "/en/", fields: [searchField]))) == .inconclusive)
        #expect(verdict(.page(probe(path: "/en/", fields: [plainTextField]))) == .inconclusive)
    }

    @Test("Only a visitor who is sent to a sign-in page, asked to sign in, or shown a sign-in control shows the session at work")
    func differsFromSignedIn() {
        #expect(VisitorVerdict.redirects.differsFromSignedIn)
        #expect(VisitorVerdict.asksForSignIn.differsFromSignedIn)
        #expect(VisitorVerdict.showsSignInControl.differsFromSignedIn)
        #expect(!VisitorVerdict.looksTheSame.differsFromSignedIn)
        #expect(!VisitorVerdict.inconclusive.differsFromSignedIn)
    }
}

@Suite("Visitor check", .serialized)
@MainActor
struct VisitorCheckTests {
    private let start = URL(string: "https://example.com/account")!

    private func run(
        _ site: TestSite,
        start: URL? = nil,
        hosts: Set<String> = ["example.com"],
        signedIn: PageProbe = probe(),
        timeout: Duration = VisitorCheck.standardTimeout,
        recheckDelay: Duration = .milliseconds(20)
    ) async -> VisitorVerdict {
        await VisitorCheck.run(
            startURL: start ?? self.start,
            browseHosts: hosts,
            signedIn: signedIn,
            pages: site.answer,
            settling: .fast,
            timeout: timeout,
            recheckDelay: recheckDelay
        )
    }

    @Test("A visitor shown a sign-in control the signed-in page lacks is told apart", .timeLimit(.minutes(1)))
    func showsSignInControl() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Welcome", "<p>Open an account</p><a href=\"/login\">Sign in</a>"))

        #expect(await run(site) == .showsSignInControl)
        #expect(site.requests.map(\.path) == ["/account"])
    }

    @Test("A visitor sent to a sign-in page on the site was redirected; one sent elsewhere proves nothing", .timeLimit(.minutes(1)))
    func redirected() async {
        let site = TestSite()
        site.route("/account", page: TestPages.redirect(to: "/login"))
        site.route("/login", page: TestPages.page("Sign in", "<form><input type=\"password\" name=\"p\"></form>"))
        #expect(await run(site) == .redirects)

        let emailOnly = TestSite()
        emailOnly.route("/account", page: TestPages.redirect(to: "/login"))
        emailOnly.route("/login", page: TestPages.page("Sign in", "<form><input type=\"email\" name=\"email\"></form>"))
        #expect(await run(emailOnly) == .redirects)

        let away = TestSite()
        away.route("/account", page: TestPages.redirect(to: "https://sso.other.test/start"))
        away.route("/start", host: "sso.other.test", page: TestPages.page("Elsewhere", "<p>Elsewhere</p>"))
        #expect(await run(away) == .inconclusive)
        #expect(away.requests.allSatisfy { $0.host == "example.com" })

        // With the other host on the site's list, the same redirect is a page on another origin.
        let allowed = TestSite()
        allowed.route("/account", page: TestPages.redirect(to: "https://sso.other.test/start"))
        allowed.route("/start", host: "sso.other.test", page: TestPages.page("Sign in", "<input type=\"password\" name=\"p\">"))
        #expect(await run(allowed, hosts: ["example.com", "sso.other.test"]) == .redirects)
        #expect(allowed.requests.map(\.host) == ["example.com", "sso.other.test"])
    }

    @Test("A visitor sent to a locale or consent page is told apart only by a sign-in control there", .timeLimit(.minutes(1)))
    func landingPages() async {
        let locale = TestSite()
        locale.route("/account", page: TestPages.redirect(to: "/en"))
        locale.route("/en", page: TestPages.page("Home", "<a href=\"/en/login\">Sign in</a>"))
        #expect(await run(locale) == .showsSignInControl)

        let consent = TestSite()
        consent.route("/account", page: TestPages.redirect(to: "/consent"))
        consent.route("/consent", page: TestPages.page("Cookies", "<p>We use cookies</p>"))
        #expect(await run(consent) == .inconclusive)
    }

    @Test("A visitor who is asked to sign in on the same page, or sees the same page, gets the matching verdict", .timeLimit(.minutes(1)))
    func sameAddress() async {
        let asks = TestSite()
        asks.route("/account", page: TestPages.page("Sign in", "<input type=\"password\" name=\"p\">"))
        #expect(await run(asks) == .asksForSignIn)

        let same = TestSite()
        same.route("/account", page: TestPages.page("Account", "<p>Welcome</p>"))
        #expect(await run(same) == .looksTheSame)
        #expect(same.requests.map(\.path) == ["/account"])
    }

    @Test("A page that shows a shell and then sends the visitor to a sign-in page is caught by the second look", .timeLimit(.minutes(1)))
    func secondLook() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Loading", "<p>Loading</p>", script: """
            setTimeout(() => location.replace('/login'), 1500);
            """))
        site.route("/login", page: TestPages.page("Sign in", "<input type=\"password\" name=\"p\">"))

        #expect(await run(site, recheckDelay: .seconds(3)) == .redirects)
        #expect(site.requests.map(\.path) == ["/account", "/login"])
    }

    @Test("A page that stays the same is looked at again without a second load", .timeLimit(.minutes(1)))
    func secondLookOfAStaticPage() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Account", "<p>Welcome</p>"))

        #expect(await run(site, recheckDelay: .milliseconds(300)) == .looksTheSame)
        #expect(site.requests.count == 1)
    }

    @Test("A page that tries to leave the site's hosts during the second look is inconclusive, not the same", .timeLimit(.minutes(1)))
    func leavesDuringTheSecondLook() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Loading", "<p>Loading</p>", script: """
            setTimeout(() => location.replace('https://sso.other.test/start'), 1000);
            """))
        site.route("/start", host: "sso.other.test", page: TestPages.page("Elsewhere", "<p>Elsewhere</p>"))

        #expect(await run(site, recheckDelay: .seconds(2.5)) == .inconclusive)
        #expect(site.requests.allSatisfy { $0.host == "example.com" })
    }

    @Test("A load that fails is inconclusive", .timeLimit(.minutes(1)))
    func failed() async {
        let site = TestSite()
        #expect(await run(site) == .inconclusive)

        // An address the site's hosts do not admit is never loaded.
        let other = TestSite()
        other.route("/account", host: "other.test", page: TestPages.page("Other", "<p>Other</p>"))
        #expect(await run(other, start: URL(string: "https://other.test/account")!) == .inconclusive)
        #expect(other.requests.isEmpty)
    }

    @Test("A check that is out of time is inconclusive, where the same page otherwise has a verdict", .timeLimit(.minutes(1)))
    func timedOut() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Welcome", "<a href=\"/login\">Sign in</a>"))

        #expect(await run(site, timeout: .zero) == .inconclusive)
        #expect(await run(site) == .showsSignInControl)
    }

    @Test("The time limit ends a second look that would otherwise wait", .timeLimit(.minutes(1)))
    func timeLimitEndsTheSecondLook() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Account", "<p>Welcome</p>"))

        // Left to finish, the second look would find the same page after half a minute.
        #expect(await run(site, timeout: .seconds(2), recheckDelay: .seconds(30)) == .inconclusive)
    }

    @Test("A page that never holds still is read once half the time has passed since it loaded", .timeLimit(.minutes(1)))
    func neverSettles() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Busy", "<a href=\"/login\">Sign in</a><p id=\"ticker\"></p>", script: """
            setInterval(() => { document.getElementById('ticker').textContent += 'x'; }, 15);
            """))

        #expect(await run(site, timeout: .seconds(4)) == .showsSignInControl)
    }

    @Test("A page that never holds still and looks the same is still looked at a second time, and is not inconclusive", .timeLimit(.minutes(1)))
    func neverSettlesAndLooksTheSame() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Busy", "<p>Welcome</p><p id=\"ticker\"></p>", script: """
            setInterval(() => { document.getElementById('ticker').textContent += 'x'; }, 15);
            """))

        #expect(await run(site, timeout: .seconds(4)) == .looksTheSame)
        #expect(site.requests.count == 1)
    }

    @Test("The address is loaded without its query or fragment", .timeLimit(.minutes(1)))
    func queryAndFragmentAreDropped() async {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Account", "<p>Welcome</p>"))

        let verdict = await run(site, start: URL(string: "https://example.com/account?token=abc123&x=1#frag")!)

        #expect(verdict == .looksTheSame)
        #expect(site.requests.count == 1)
        #expect(site.requests.first?.path == "/account")
        #expect(site.requests.first?.fields.isEmpty == true)
    }

    @Test("Each check starts with no cookies, though a page can keep one across loads in a browser that holds them", .timeLimit(.minutes(1)))
    func noCookiesCarryOver() async throws {
        // A page that reads the cookie it left on an earlier load and shows a sign-in control then.
        let page = TestPages.page("Account", "<p>Welcome</p>", script: """
            const earlier = document.cookie.includes('seen=1');
            document.cookie = 'seen=1; path=/';
            if (earlier) document.body.insertAdjacentHTML('beforeend', '<a href="/login">Sign in</a>');
            """)

        // Control: a browser that keeps its data store between loads sees the earlier cookie.
        let control = TestSite()
        control.route("/account", page: page)
        let browser = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: control.answer,
            settling: .fast
        )
        defer { browser.close() }
        _ = try await browser.open(start)
        _ = try await browser.open(start)
        let kept = try await SignInBroker(browser: browser).probe()
        try #require(kept.hasSignInControl, "a page cannot keep a cookie across loads in the simulated site")

        let site = TestSite()
        site.route("/account", page: page)
        #expect(await run(site) == .looksTheSame)
        #expect(await run(site) == .looksTheSame)
        #expect(site.requests.count == 2)
    }
}

@Suite("Hidden read of a start page", .serialized)
@MainActor
struct HiddenReadTests {
    private let start = URL(string: "https://example.com/account?tab=1#top")!

    private func read(_ site: TestSite, hosts: Set<String> = ["example.com"]) async -> PageProbe? {
        await HiddenRead.startPage(
            start,
            browseHosts: hosts,
            dataStore: .nonPersistent(),
            pages: site.answer,
            settling: .fast
        )
    }

    @Test("The start page is read without its query, and what it shows is returned", .timeLimit(.minutes(1)))
    func startPage() async throws {
        let site = TestSite()
        site.route("/account", page: TestPages.page("Account", "<p>Welcome</p><a href=\"/logout\">Sign out</a>"))

        let probe = try #require(await read(site))

        #expect(probe.path == "/account")
        #expect(probe.hasSignOutControl)
        #expect(!probe.hasSignInControl)
        #expect(site.requests.map(\.path) == ["/account"])
        #expect(site.requests.first?.fields.isEmpty == true)
    }

    @Test("A page that is not the start page past the sign-in is not a read of it", .timeLimit(.minutes(1)))
    func notTheStartPage() async {
        let moved = TestSite()
        moved.route("/account", page: TestPages.redirect(to: "/login"))
        moved.route("/login", page: TestPages.page("Sign in", "<p>Welcome</p>"))
        #expect(await read(moved) == nil)

        let asks = TestSite()
        asks.route("/account", page: TestPages.page("Sign in", "<input type=\"password\" name=\"p\">"))
        #expect(await read(asks) == nil)

        let away = TestSite()
        away.route("/account", page: TestPages.redirect(to: "https://sso.other.test/start"))
        #expect(await read(away) == nil)

        #expect(await read(TestSite()) == nil)
    }
}
