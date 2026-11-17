import Foundation
import Testing
import WebKit

@testable import SuperVisor

@Suite("Site enrollment", .serialized)
@MainActor
struct SiteEnrollmentTests {
    private func enrollment(_ bank: TestBank, stub: CodeStub = CodeStub()) -> SiteEnrollment {
        SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: stub.codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
    }

    private func begin(
        _ enrollment: SiteEnrollment,
        _ bank: TestBank,
        address: String = "example.com/login",
        kind: SiteGrant.CodeKind = .none,
        key: String? = nil,
        sender: String? = nil
    ) async throws {
        try await enrollment.begin(
            signInAddress: address,
            username: bank.username,
            password: bank.password,
            authenticatorKey: key,
            codeKind: kind,
            codeSender: sender
        )
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: A full enrollment

    @Test("A full enrollment produces a valid grant with the hosts, steps, and start page it saw", .timeLimit(.minutes(1)))
    func fullEnrollment() async throws {
        let bank = TestBank()
        bank.postLoginLocation = "https://app.example.com/overview?welcome=1#top"
        bank.site.route("/overview", host: "app.example.com", page: TestPages.page("Overview", "<p>Welcome back</p>"))
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)

        #expect(!session.isWorking)
        #expect(session.currentHost == "app.example.com")
        #expect(session.currentIsSecure)
        #expect(session.note == SiteEnrollment.Notes.checkAndSave)

        let (grant, record) = try await session.finish(name: "  My   Bank  ")

        #expect(grant.isValid(for: "example.com"))
        #expect(grant.signInURL == url("https://example.com/login"))
        #expect(grant.startURL == url("https://app.example.com/overview"))
        #expect(grant.fillHosts == ["example.com"])
        #expect(grant.browseHosts == ["example.com", "app.example.com"])
        #expect(grant.username == bank.username)
        #expect(grant.password == bank.password)
        #expect(grant.codeKind == .none)
        #expect(grant.codeSender == nil)
        #expect(grant.authenticatorKey == nil)
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        #expect(grant.signInSteps.allSatisfy { $0.origin == "https://example.com" && $0.path == "/login" })
        #expect(grant.signInSteps.map(\.field.name) == ["username", "password"])
        #expect(record.id == "example.com")
        #expect(record.name == "My Bank")
        #expect(record.lastSignedIn != nil)
        #expect(record.isValid)
    }

    @Test("A two-step sign-in is recorded step by step, and a sign-in that goes through another host keeps it as a browse host", .timeLimit(.minutes(1)))
    func twoStepThroughAnotherHost() async throws {
        let bank = TestBank()
        bank.flow = .twoStep
        bank.postLoginLocation = "https://sso.example.com/hop"
        bank.site.route("/hop", host: "sso.example.com", page: TestPages.redirect(to: "https://example.com/account"))
        bank.site.route("/account", page: TestPages.page("Account", "<p>Welcome</p>"))
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank, address: "https://example.com/login")
        let (grant, _) = try await session.finish(name: "Bank")

        #expect(grant.signInSteps.map(\.path) == ["/login", "/password"])
        #expect(grant.startURL == url("https://example.com/account"))
        #expect(Set(grant.browseHosts) == ["example.com", "sso.example.com"])
        #expect(grant.browseHosts.first == "example.com")
        #expect(grant.fillHosts == ["example.com"])
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("A texted code's sender is learned and kept in the grant", .timeLimit(.minutes(1)))
    func textedSenderIsLearned() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(firstText: (bank.code, "24273"))
        let session = enrollment(bank, stub: stub)
        defer { session.cancel() }

        try await begin(session, bank, kind: .text, sender: nil)
        let (grant, _) = try await session.finish(name: "Bank")

        #expect(grant.codeKind == .text)
        #expect(grant.codeSender == "24273")
        #expect(grant.signInSteps.map(\.kind) == [.username, .password, .code])
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("An emailed code keeps the sender it was given, and an authenticator key is kept only for that kind", .timeLimit(.minutes(1)))
    func codeKinds() async throws {
        let bank = TestBank()
        bank.requiresCode = true

        let emailed = enrollment(bank, stub: CodeStub(emailed: bank.code))
        defer { emailed.cancel() }
        try await begin(emailed, bank, kind: .email, key: CodeStub.sampleKey, sender: "no-reply@bank.example")
        let (emailGrant, _) = try await emailed.finish(name: "Bank")
        #expect(emailGrant.codeKind == .email)
        #expect(emailGrant.codeSender == "no-reply@bank.example")
        #expect(emailGrant.authenticatorKey == nil)
        #expect(emailGrant.isValid(for: "example.com"))

        bank.signOut()
        let authenticator = enrollment(bank, stub: CodeStub(authenticator: bank.code))
        defer { authenticator.cancel() }
        try await begin(authenticator, bank, kind: .authenticator, key: CodeStub.sampleKey)
        let (appGrant, _) = try await authenticator.finish(name: "Bank")
        #expect(appGrant.codeKind == .authenticator)
        #expect(appGrant.authenticatorKey == CodeStub.sampleKey)
        #expect(appGrant.codeSender == nil)
        #expect(appGrant.isValid(for: "example.com"))
    }

    @Test("A texted-code site that never asked for a code gives no grant, as the sender is unknown", .timeLimit(.minutes(1)))
    func textedWithoutACodePage() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank, kind: .text, sender: nil)

        await #expect(throws: SiteEnrollment.Failure.invalidGrant) { _ = try await session.finish(name: "Bank") }
    }

    @Test("When the sign-in went through too many hosts, the grant keeps the sign-in, start, and fill hosts", .timeLimit(.minutes(2)))
    func tooManyHosts() async throws {
        let bank = TestBank()
        let chain = (1...12).map { "h\($0).example.com" }
        bank.postLoginLocation = "https://\(chain[0])/hop"
        for (index, host) in chain.enumerated() {
            let next = index + 1 < chain.count ? "https://\(chain[index + 1])/hop" : "https://\(host)/final"
            bank.site.route("/hop", host: host, page: TestPages.redirect(to: next))
        }
        bank.site.route("/final", host: chain.last!, page: TestPages.page("Final", "<p>done</p>"))
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)
        let (grant, _) = try await session.finish(name: "Bank")

        #expect(grant.browseHosts == ["example.com", chain.last!])
        #expect(grant.startURL == url("https://\(chain.last!)/final"))
        #expect(grant.isValid(for: "example.com"))
    }

    // MARK: Pages the user takes over

    @Test("A challenge between the username and the password pauses the app, and the next page is examined afresh", .timeLimit(.minutes(1)))
    func challengePageThenPassword() async throws {
        let bank = TestBank()
        bank.flow = .twoStep
        bank.challengeBetweenSteps = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)

        // The username was filled and the site answered with a challenge, which the app left alone.
        #expect(session.note == SiteEnrollment.Notes.finishYourself)
        #expect(bank.site.posts.map(\.path) == ["/identify"])
        #expect(session.browser.currentURL?.path == "/challenge")
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }

        // The user gets past it, and the next page is the password page.
        _ = try await session.browser.open(url("https://example.com/password"))
        await session.idle()

        #expect(bank.site.posts.map(\.path) == ["/identify", "/session"])
        #expect(bank.signedIn)
        let (grant, _) = try await session.finish(name: "Bank")
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        #expect(grant.signInSteps.map(\.path) == ["/login", "/password"])
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("A page that is not a sign-in at first is left alone, and the sign-in page the user moves to is filled", .timeLimit(.minutes(1)))
    func userMovesToTheLoginPage() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank, address: "example.com/cards")
        #expect(bank.site.posts.isEmpty)

        _ = try await session.browser.open(url("https://example.com/login"))
        await session.idle()

        #expect(bank.site.posts.count == 1)
        #expect(bank.signedIn)
        let (grant, _) = try await session.finish(name: "Bank")
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        // The sign-in address is the one the user typed, and the steps are where they were filled.
        #expect(grant.signInURL == url("https://example.com/cards"))
    }

    @Test("Nothing is filled once the sign-in has led to a page that asks for none", .timeLimit(.minutes(1)))
    func nothingFilledAfterSignIn() async throws {
        let bank = TestBank()
        bank.site.route("/search", page: TestPages.page("Search", """
            <form method="post" action="/search"><input type="text" id="q" name="q"><button type="submit">Go</button></form>
            """))
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        #expect(bank.site.posts.count == 1)

        _ = try await session.browser.open(url("https://example.com/search"))
        await session.idle()

        #expect(bank.site.posts.count == 1)
        let typed = try await session.browser.run("return document.getElementById('q').value;")
        #expect(typed.string == "")
    }

    @Test("The hosts visited after the sign-in is past are not browse hosts", .timeLimit(.minutes(1)))
    func hostsAfterSignInAreNotAdded() async throws {
        let bank = TestBank()
        bank.site.route("/elsewhere", host: "www.example.org", page: TestPages.page("Elsewhere", "<p>other</p>"))
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        let landing = try #require(session.browser.currentURL)

        // The user looks at another site, and comes back to the page they signed in on.
        _ = try await session.browser.open(url("https://www.example.org/elsewhere"))
        await session.idle()
        #expect(session.browser.traversedHosts.contains("www.example.org"))
        _ = try await session.browser.open(landing)
        await session.idle()
        let (grant, _) = try await session.finish(name: "Bank")

        #expect(grant.browseHosts == ["example.com"])
        #expect(grant.startURL == landing)
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("The hosts a sign-in went through before it was past are browse hosts, including a password page's", .timeLimit(.minutes(1)))
    func hostsBeforeSignInAreAdded() async throws {
        let bank = TestBank()
        bank.flow = .twoStep
        bank.site.route("/password", host: "id.example.com", page: TestPages.page("Password", """
            <form method="post" action="https://id.example.com/session">
            <input type="password" id="pass" name="password" autocomplete="current-password">
            <button type="submit">Continue</button></form>
            """))
        bank.site.route("/session", method: "POST", host: "id.example.com") { [unowned bank] request in
            guard request.fields["password"] == bank.password else { return TestPages.redirect(to: "https://example.com/login") }
            bank.markSignedIn()
            return TestPages.redirect(to: "https://example.com/home")
        }
        bank.site.route("/identify", method: "POST") { [unowned bank] _ in
            _ = bank
            return TestPages.redirect(to: "https://id.example.com/password")
        }
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)
        let (grant, _) = try await session.finish(name: "Bank")

        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        #expect(Set(grant.fillHosts) == ["example.com", "id.example.com"])
        #expect(Set(grant.browseHosts) == ["example.com", "id.example.com"])
        #expect(grant.isValid(for: "example.com"))
    }

    // MARK: Finishing

    @Test("The page is read afresh, and one that asks for a sign-in is refused whatever it was a moment before", .timeLimit(.minutes(1)))
    func finishReadsThePageAfresh() async throws {
        let bank = TestBank()
        bank.site.route("/code", page: TestPages.page("Code", """
            <a href="/logout">Sign out</a><form method="post" action="/x"><input name="otp" autocomplete="one-time-code"></form>
            """))
        bank.site.route("/frames", page: TestPages.page("Frames", """
            <a href="/logout">Sign out</a><iframe src="https://accounts.example.com/signin" style="width:400px;height:300px"></iframe>
            """))
        bank.site.route("/again", page: TestPages.page("Again", """
            <form method="post" action="/x"><input type="password" name="password"></form>
            """))
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        let landing = try #require(session.browser.currentURL)

        for path in ["/again", "/code", "/frames"] {
            _ = try await session.browser.open(url("https://example.com\(path)"))
            await session.idle()
            await #expect(throws: SiteEnrollment.Failure.notSignedIn, "\(path)") {
                _ = try await session.finish(name: "Bank")
            }
        }

        // A refusal leaves the enrollment as it was: the user goes back and finishes.
        _ = try await session.browser.open(landing)
        await session.idle()
        let (grant, _) = try await session.finish(name: "Bank")
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("Whether the page the user ended on has a sign-out control is recorded", .timeLimit(.minutes(1)))
    func signOutControlIsRecorded() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)

        let (withControl, _) = try await session.finish(name: "Bank")
        #expect(withControl.signOutControlSeen)

        let plain = TestBank()
        plain.site.route("/home", page: TestPages.page("Home", "<p>Welcome back</p><a href=\"/cards\">Cards</a>"))
        let other = enrollment(plain)
        defer { other.cancel() }
        try await begin(other, plain)
        let (withoutControl, _) = try await other.finish(name: "Bank")
        #expect(!withoutControl.signOutControlSeen)
        #expect(withoutControl.isValid(for: "example.com"))
    }

    @Test("The sender a texted code came from is published for the window to show", .timeLimit(.minutes(1)))
    func learnedSenderIsPublished() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let session = enrollment(bank, stub: CodeStub(firstText: (bank.code, "24273")))
        defer { session.cancel() }
        #expect(session.learnedCodeSender == nil)

        try await begin(session, bank, kind: .text, sender: nil)

        #expect(session.learnedCodeSender == "24273")
    }

    // MARK: Addresses

    @Test(
        "An address is made an https address, or refused",
        arguments: [
            ("example.com", "https://example.com"),
            ("  example.com/login  ", "https://example.com/login"),
            ("Example.COM/Login", "https://example.com/Login"),
            ("https://example.com/login#frag", "https://example.com/login"),
            ("https://example.com/login?next=1", "https://example.com/login?next=1"),
            ("HTTPS://example.com/", "https://example.com/"),
            ("https://sub.example.co.uk/a/b", "https://sub.example.co.uk/a/b"),
        ]
    )
    func normalised(_ address: String, _ expected: String) {
        #expect(SiteEnrollment.normalisedAddress(address)?.absoluteString == expected)
    }

    @Test(
        "An address that is not https, has a port or credentials, or is not a plain host name is refused",
        arguments: [
            "http://example.com/login",
            "ftp://example.com/",
            "192.168.1.1",
            "https://192.168.1.1/login",
            "https://[::1]/",
            "example.com:8443/login",
            "https://example.com:8443/",
            "https://example.com:443/",
            "https://user@example.com/",
            "https://user:secret@example.com/",
            "https://@example.com/",
            "javascript:alert(1)",
            "mailto:a@example.com",
            "file:///etc/hosts",
            "data:text/html,x",
            "https://localhost/",
            "https://example/",
            "https://example.com./",
            "https://exa mple.com/",
            "https://example.com/a b",
            "",
            "   ",
            "https:///path",
            "https://example.com\n.evil.test/",
        ]
    )
    func refusedAddresses(_ address: String) {
        #expect(SiteEnrollment.normalisedAddress(address) == nil)
    }

    @Test("An address that is refused loads nothing and throws invalidAddress", .timeLimit(.minutes(1)))
    func beginRefusesAddresses() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        for address in ["http://example.com/login", "192.168.1.1/login", "example.com:8443/login", "user@example.com"] {
            await #expect(throws: SiteEnrollment.Failure.invalidAddress, "\(address)") {
                try await begin(session, bank, address: address)
            }
        }

        #expect(bank.site.requests.isEmpty)
        #expect(!session.isWorking)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }
    }

    // MARK: Finishing

    @Test("Finishing before any sign-in is not a sign-in", .timeLimit(.minutes(1)))
    func finishBeforeBegin() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }
    }

    @Test("Finishing while the page still asks for a password is not a sign-in", .timeLimit(.minutes(1)))
    func finishWhileSigningIn() async throws {
        let bank = TestBank()
        bank.neverSignsIn = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)

        #expect(session.note == SiteEnrollment.Notes.finishYourself)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }
    }

    @Test("Finishing after a challenge stopped the sign-in, on the login page, is not a sign-in", .timeLimit(.minutes(1)))
    func finishAfterChallenge() async throws {
        let bank = TestBank()
        bank.showsChallenge = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)

        #expect(bank.site.posts.isEmpty)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }
    }

    @Test("An empty name becomes the host, and a long one is cut", .timeLimit(.minutes(1)))
    func nameIsCleaned() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)

        let (_, record) = try await session.finish(name: "   \n ")
        #expect(record.name == "example.com")
        #expect(record.isValid)
    }

    @Test("After finishing, the secrets are gone and the enrollment cannot be finished again", .timeLimit(.minutes(1)))
    func finishOnce() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)

        _ = try await session.finish(name: "Bank")

        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }
    }

    @Test("Cancelling closes the browser and forgets the secrets", .timeLimit(.minutes(1)))
    func cancelForgets() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        try await begin(session, bank)

        session.cancel()

        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await session.finish(name: "Bank") }
    }

    @Test("The host the user sees follows the page they are on", .timeLimit(.minutes(1)))
    func hostFollowsThePage() async throws {
        let bank = TestBank()
        bank.site.route("/elsewhere", host: "www.example.org", page: TestPages.page("Elsewhere", "<p>other</p>"))
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        #expect(session.currentHost == "example.com")

        _ = try await session.browser.open(url("https://www.example.org/elsewhere"))

        #expect(session.currentHost == "www.example.org")
        #expect(session.currentIsSecure)
    }
}
