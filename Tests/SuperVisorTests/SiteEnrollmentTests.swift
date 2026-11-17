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
        sender: String? = nil,
        passwordHosts: [String]? = nil,
        authenticatorHosts: [String]? = nil
    ) async throws {
        try await enrollment.begin(
            signInAddress: address,
            username: bank.username,
            password: bank.password,
            authenticatorKey: key,
            codeKind: kind,
            codeSender: sender,
            passwordHosts: passwordHosts,
            authenticatorHosts: authenticatorHosts
        )
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    /// Waits up to five seconds for `condition`, which a page the person drives brings about.
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the page never reached the expected state")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

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

    @Test("A texted-code site that never asked for a code is saved as one with no code", .timeLimit(.minutes(1)))
    func textedWithoutACodePage() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank, kind: .text, sender: nil)

        let (grant, _) = try await session.finish(name: "Bank")
        #expect(grant.codeKind == .none)
        #expect(grant.codeSender == nil)
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("A texted-code site that asked for a code that never came gives no grant, as the sender is unknown", .timeLimit(.minutes(1)))
    func textedCodeNeverArrived() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let session = enrollment(bank, stub: CodeStub(firstText: nil))
        defer { session.cancel() }

        try await begin(session, bank, kind: .text, sender: nil)
        #expect(session.browser.currentURL?.path == "/verify")

        // The person types the code into the page themselves.
        _ = try await session.browser.run("""
            document.getElementById('otp').value = '\(bank.code)';
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """)
        try await waitFor { bank.signedIn && session.browser.currentURL?.path == "/home" }
        await session.idle()

        await #expect(throws: SiteEnrollment.Failure.invalidGrant) { _ = try await session.finish(name: "Bank") }
    }

    // MARK: Which password worked

    @Test("A password the app filled, followed by the signed-in page, is confirmed", .timeLimit(.minutes(1)))
    func filledPasswordIsConfirmed() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        #expect(!session.passwordIsConfirmed)

        try await begin(session, bank)

        #expect(session.passwordIsConfirmed)
        let (grant, _) = try await session.finish(name: "Bank")
        #expect(grant.password == bank.password)
    }

    @Test("A password the site rejected, then typed into the page by the person, cannot be saved", .timeLimit(.minutes(1)))
    func rejectedThenRetypedCannotBeSaved() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.begin(
            signInAddress: "example.com/login",
            username: bank.username,
            password: "an-old-password",
            authenticatorKey: nil,
            codeKind: .none,
            codeSender: nil
        )
        #expect(!bank.signedIn)
        #expect(session.browser.currentURL?.path == "/login")
        #expect(!session.passwordIsConfirmed)

        // The person signs in with the right password in the page. A script's events are not
        // trusted, so only the login form coming back says the filled password was wrong.
        _ = try await session.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        try await waitFor { bank.signedIn && session.browser.currentURL?.path == "/home" }
        await session.idle()

        #expect(!session.passwordIsConfirmed)
        await #expect(throws: SiteEnrollment.Failure.passwordNotConfirmed) { _ = try await session.finish(name: "Bank") }
    }

    @Test("Typing into a password field on the page unconfirms the password the app filled", .timeLimit(.minutes(1)))
    func typedPasswordUnconfirms() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        #expect(session.passwordIsConfirmed)

        // The message the page script posts for a person's typing lands here.
        session.browser.noteTyped(into: .password)

        #expect(!session.passwordIsConfirmed)
        await #expect(throws: SiteEnrollment.Failure.passwordNotConfirmed) { _ = try await session.finish(name: "Bank") }

        // A new sign-in starts the question over.
        bank.signOut()
        try await begin(session, bank)
        #expect(session.passwordIsConfirmed)
    }

    @Test("Typing into a field other than the password leaves the filled password confirmed", .timeLimit(.minutes(1)))
    func typingElsewhereKeepsThePasswordConfirmed() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        #expect(session.passwordIsConfirmed)

        session.browser.noteTyped(into: .other)
        await session.idle()

        #expect(session.passwordIsConfirmed)
        _ = try await session.finish(name: "Bank")
    }

    @Test("A synthetic input event on a password field is not taken for the person typing", .timeLimit(.minutes(1)))
    func syntheticTypingIsIgnored() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        var typed = 0
        let observer = session.browser.passwordTypedObserver
        session.browser.passwordTypedObserver = {
            typed += 1
            observer?()
        }
        let anyObserver = session.browser.typedObserver
        session.browser.typedObserver = {
            typed += 1
            anyObserver?()
        }
        _ = try await session.browser.open(url("https://example.com/login"))
        _ = try await session.browser.run("""
            const field = document.getElementById('pass');
            field.value = 'x';
            field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
            field.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, data: 'x' }));
            """)
        try await Task.sleep(for: .milliseconds(200))
        #expect(typed == 0)
    }

    @Test("A sign-in the person did entirely in the page cannot be saved, as the app has nothing to replay", .timeLimit(.minutes(1)))
    func signInByThePersonAloneCannotBeSaved() async throws {
        let bank = TestBank()
        bank.showsChallenge = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank)
        #expect(bank.site.posts.isEmpty)

        _ = try await session.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        try await waitFor { bank.signedIn && session.browser.currentURL?.path == "/home" }
        await session.idle()

        await #expect(throws: SiteEnrollment.Failure.passwordNotFilled) { _ = try await session.finish(name: "Bank") }
    }

    // MARK: Saved secrets on other hosts

    @Test("A saved password is not filled on a host outside its list, and nothing is sent", .timeLimit(.minutes(1)))
    func savedPasswordStaysOnItsHosts() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank, passwordHosts: ["login.example.org"])

        #expect(bank.site.posts.isEmpty)
        #expect(session.unvettedFill == AssistedSignInSession.UnvettedFill(host: "example.com", kind: .password))
        #expect(session.note == SiteEnrollment.Notes.finishYourself)
        let typed = try await session.browser.run("return document.getElementById('pass').value;")
        #expect(typed.string == "")

        // Typed afresh, the password goes in as for a new site.
        try await begin(session, bank)
        #expect(session.unvettedFill == nil)
        #expect(bank.signedIn)
    }

    @Test("A saved password is filled on a host in its list", .timeLimit(.minutes(1)))
    func savedPasswordFillsOnItsHosts() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await begin(session, bank, passwordHosts: ["example.com"])

        #expect(session.unvettedFill == nil)
        #expect(bank.signedIn)
        #expect(session.passwordIsConfirmed)
    }

    @Test("A saved authenticator key is not used on a host outside its list", .timeLimit(.minutes(1)))
    func savedKeyStaysOnItsHosts() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub()
        let session = enrollment(bank, stub: stub)
        defer { session.cancel() }

        try await begin(
            session,
            bank,
            kind: .authenticator,
            key: CodeStub.sampleKey,
            authenticatorHosts: ["login.example.org"]
        )

        #expect(bank.site.posts.map(\.path) == ["/session"])
        #expect(session.unvettedFill == AssistedSignInSession.UnvettedFill(host: "example.com", kind: .code))
        #expect(!stub.calls.contains { $0.hasPrefix("authenticator") })
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

    // MARK: Keeping the session

    /// Signs in on the open page the way a person would, by submitting the form with the
    /// bank's own details, and waits for the signed-in page.
    private func signInByHand(_ session: SiteEnrollment, _ bank: TestBank) async throws {
        _ = try await session.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        try await waitFor { bank.signedIn && session.browser.currentURL?.path == "/home" }
    }

    @Test("Keeping the session fills nothing, and the sign-in the person makes becomes a grant with no secret", .timeLimit(.minutes(1)))
    func keepingTheSession() async throws {
        let bank = TestBank()
        bank.postLoginLocation = "https://app.example.com/overview?welcome=1#top"
        bank.site.route("/overview", host: "app.example.com", page: TestPages.page("Overview", """
            <p>Welcome back</p><a href="/logout">Sign out</a>
            """))
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/login")

        #expect(!session.isWorking)
        #expect(session.note == SiteEnrollment.Notes.signInYourself)
        #expect(session.currentHost == "example.com")
        #expect(bank.site.posts.isEmpty)
        let typed = try await session.browser.run(
            "return document.getElementById('user').value + document.getElementById('pass').value;"
        )
        #expect(typed.string == "")

        _ = try await session.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        try await waitFor { bank.signedIn && session.browser.currentURL?.host == "app.example.com" }
        #expect(!session.passwordIsConfirmed)

        let (grant, record) = try await session.finishKeepingSession(name: "  My   Bank  ")

        #expect(!grant.remembersPassword)
        #expect(grant.isValid(for: "example.com"))
        #expect(grant.username.isEmpty && grant.password.isEmpty)
        #expect(grant.authenticatorKey == nil)
        #expect(grant.codeKind == .none && grant.codeSender == nil)
        #expect(grant.signInSteps.isEmpty)
        #expect(grant.signInURL == url("https://example.com/login"))
        #expect(grant.startURL == url("https://app.example.com/overview"))
        #expect(grant.fillHosts == ["example.com"])
        #expect(grant.browseHosts == ["example.com", "app.example.com"])
        #expect(grant.signOutControlSeen)
        #expect(record.id == "example.com")
        #expect(record.name == "My Bank")
        #expect(record.keepsSessionOnly)
        #expect(record.lastSignedIn != nil)
        #expect(record.isValid)
        #expect(bank.site.posts.count == 1)
    }

    @Test("Keeping the session is refused on a page that still asks for a sign-in, and goes through once the person signs in", .timeLimit(.minutes(1)))
    func keepingTheSessionNeedsASignedInPage() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "https://example.com/login")
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }

        try await signInByHand(session, bank)
        let (grant, _) = try await session.finishKeepingSession(name: "Bank")
        #expect(grant.startURL == url("https://example.com/home"))
        #expect(!grant.remembersPassword)
    }

    @Test("A page that shows no sign-out control is recorded as such when keeping the session", .timeLimit(.minutes(1)))
    func keepingTheSessionRecordsTheSignOutControl() async throws {
        let bank = TestBank()
        bank.site.route("/home", page: TestPages.page("Home", "<p>Welcome back</p><a href=\"/cards\">Cards</a>"))
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/login")
        try await signInByHand(session, bank)
        let (grant, _) = try await session.finishKeepingSession(name: "Bank")

        #expect(!grant.signOutControlSeen)
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("Saving a public page that never asked for a sign-in is refused", .timeLimit(.minutes(1)))
    func keepingTheSessionNeedsASignIn() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        #expect(session.browser.currentURL?.path == "/account")
        await #expect(throws: SiteEnrollment.Failure.signInNotSeen) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }

        // Following the page's own link to the sign-in page and signing in there is a sign-in.
        _ = try await session.browser.open(url("https://example.com/login"))
        await session.idle()
        try await signInByHand(session, bank)
        let (grant, _) = try await session.finishKeepingSession(name: "Bank")
        #expect(grant.startURL == url("https://example.com/home"))
    }

    @Test("A password typed into the page counts as seeing the sign-in", .timeLimit(.minutes(1)))
    func typedPasswordIsASignIn() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        session.browser.passwordTypedObserver?()

        let (grant, _) = try await session.finishKeepingSession(name: "Bank")
        #expect(!grant.remembersPassword)
    }

    @Test("A code step a page shows without a load is seen once the person types", .timeLimit(.minutes(1)))
    func stepShownWithoutALoadIsSeen() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        _ = try await session.browser.run("""
            const box = document.createElement('input');
            box.id = 'step';
            box.autocomplete = 'one-time-code';
            document.body.appendChild(box);
            """)
        await session.idle()
        // The field appeared with no load, so nothing has looked at the page since.
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }

        session.browser.noteTyped(into: .other)
        await session.idle()
        _ = try await session.browser.run("document.getElementById('step').remove();")

        let (grant, _) = try await session.finishKeepingSession(name: "Bank")
        #expect(!grant.remembersPassword)
    }

    @Test("A row of single-character boxes is a sign-in step, and a page showing one is not saved", .timeLimit(.minutes(1)))
    func splitCodeBoxes() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        _ = try await session.browser.run("""
            const row = document.createElement('div');
            row.id = 'row';
            for (let index = 0; index < 6; index++) {
              const box = document.createElement('input');
              box.maxLength = 1;
              row.appendChild(box);
            }
            document.body.appendChild(row);
            """)
        session.browser.noteTyped(into: .other)
        await session.idle()

        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await session.finishKeepingSession(name: "Bank", confirmedByPerson: true)
        }

        _ = try await session.browser.run("document.getElementById('row').remove();")
        let (grant, _) = try await session.finishKeepingSession(name: "Bank")
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("Typing on a page that asks for no sign-in is not a sign-in", .timeLimit(.minutes(1)))
    func typingElsewhereIsNoSignIn() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        _ = try await session.browser.run("""
            const box = document.createElement('input');
            box.type = 'email';
            box.name = 'newsletter';
            document.body.appendChild(box);
            """)
        session.browser.noteTyped(into: .other)
        await session.idle()

        await #expect(throws: SiteEnrollment.Failure.signInNotSeen) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }
    }

    @Test("A page that shows a sign-out control is saved with no sign-in seen", .timeLimit(.minutes(1)))
    func signOutControlIsEvidence() async throws {
        let bank = TestBank()
        bank.site.route("/members", page: TestPages.page("Members", """
            <p>Welcome back</p><a href="/logout">Sign out</a>
            """))
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/members")
        let (grant, _) = try await session.finishKeepingSession(name: "Bank")

        #expect(grant.signOutControlSeen)
        #expect(grant.startURL == url("https://example.com/members"))
    }

    @Test("A kept session rests on a sighting first, then a sign-out control, then the person's word")
    func keptSessionBasis() {
        typealias Basis = SiteEnrollment.KeptSessionBasis
        #expect(Basis(sawSignIn: true, showsSignOutControl: true, confirmedByPerson: true) == .sighting)
        #expect(Basis(sawSignIn: true, showsSignOutControl: false, confirmedByPerson: false) == .sighting)
        #expect(Basis(sawSignIn: false, showsSignOutControl: true, confirmedByPerson: true) == .signOutControl)
        #expect(Basis(sawSignIn: false, showsSignOutControl: true, confirmedByPerson: false) == .signOutControl)
        #expect(Basis(sawSignIn: false, showsSignOutControl: false, confirmedByPerson: true) == .personsWord)
        #expect(Basis(sawSignIn: false, showsSignOutControl: false, confirmedByPerson: false) == nil)
    }

    @Test("The person's confirmation does not save a page that still asks for a sign-in", .timeLimit(.minutes(1)))
    func confirmationDoesNotSaveASignInPage() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/login")

        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await session.finishKeepingSession(name: "Bank", confirmedByPerson: true)
        }
    }

    @Test("With no sign-in seen, the person's confirmation saves the page and nothing else does", .timeLimit(.minutes(1)))
    func confirmationStandsInForASighting() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        await #expect(throws: SiteEnrollment.Failure.signInNotSeen) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }

        let (grant, record) = try await session.finishKeepingSession(name: "Bank", confirmedByPerson: true)

        #expect(!grant.remembersPassword)
        #expect(grant.password.isEmpty)
        #expect(!grant.signOutControlSeen)
        #expect(grant.startURL == url("https://example.com/account"))
        #expect(record.keepsSessionOnly)
    }

    @Test("A sign-in seen in an earlier kept session does not carry into the next", .timeLimit(.minutes(1)))
    func sightingDoesNotCarryOver() async throws {
        let bank = TestBank()
        bank.startPageIsPublic = true
        let session = enrollment(bank)
        defer { session.cancel() }

        try await session.beginKeepingSession(signInAddress: "example.com/login")
        try await session.beginKeepingSession(signInAddress: "example.com/account")

        await #expect(throws: SiteEnrollment.Failure.signInNotSeen) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }
    }

    @Test("Each finish answers only its own begin", .timeLimit(.minutes(1)))
    func finishesDoNotCross() async throws {
        let bank = TestBank()
        let kept = enrollment(bank)
        defer { kept.cancel() }
        try await kept.beginKeepingSession(signInAddress: "example.com/login")
        try await signInByHand(kept, bank)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await kept.finish(name: "Bank") }

        let other = TestBank()
        let assisted = enrollment(other)
        defer { assisted.cancel() }
        try await begin(assisted, other)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await assisted.finishKeepingSession(name: "Bank")
        }
        // A begin of the other kind replaces the first.
        other.signOut()
        try await assisted.beginKeepingSession(signInAddress: "example.com/login")
        try await signInByHand(assisted, other)
        let (grant, _) = try await assisted.finishKeepingSession(name: "Bank")
        #expect(!grant.remembersPassword)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await assisted.finish(name: "Bank") }
    }

    @Test("Keeping the session refuses an address that is not one, loading nothing", .timeLimit(.minutes(1)))
    func keepingTheSessionRefusesAddresses() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }

        for address in ["http://example.com/login", "example.com:8443/login", "user@example.com", ""] {
            await #expect(throws: SiteEnrollment.Failure.invalidAddress, "\(address)") {
                try await session.beginKeepingSession(signInAddress: address)
            }
        }

        #expect(bank.site.requests.isEmpty)
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }
    }

    @Test("A kept session cannot be finished twice, nor once cancelled", .timeLimit(.minutes(1)))
    func keepingTheSessionFinishesOnce() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        try await session.beginKeepingSession(signInAddress: "example.com/login")
        try await signInByHand(session, bank)
        _ = try await session.finishKeepingSession(name: "Bank")
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }

        try await session.beginKeepingSession(signInAddress: "example.com/account")
        session.cancel()
        await #expect(throws: SiteEnrollment.Failure.cancelled) {
            _ = try await session.finishKeepingSession(name: "Bank")
        }
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

        #expect(session.isCancelled)
        await #expect(throws: SiteEnrollment.Failure.cancelled) { _ = try await session.finish(name: "Bank") }
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

    @Test("A load toward another host that fails leaves the bar on the page on display", .timeLimit(.minutes(1)))
    func failedLoadKeepsTheHost() async throws {
        let bank = TestBank()
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)
        #expect(session.currentHost == "example.com")

        var shown: [String?] = []
        let watching = session.$currentHost.sink { shown.append($0) }
        defer { watching.cancel() }
        // The simulated site has no page there, so the load fails.
        await #expect(throws: SiteBrowser.Failure.loadFailed) {
            _ = try await session.browser.open(url("https://nowhere.example.net/"))
        }
        try await Task.sleep(for: .milliseconds(200))

        #expect(session.currentHost == "example.com")
        #expect(session.currentIsSecure)
        #expect(!shown.contains("nowhere.example.net"))
    }

    @Test("A load that has started but not committed does not move the bar", .timeLimit(.minutes(1)))
    func provisionalLoadDoesNotMoveTheHost() async throws {
        let bank = TestBank()
        bank.site.route("/elsewhere", host: "www.example.org", page: TestPages.page("Elsewhere", "<p>other</p>"))
        let session = enrollment(bank)
        defer { session.cancel() }
        try await begin(session, bank)

        let webView = session.browser.webView
        webView.load(URLRequest(url: url("https://www.example.org/elsewhere")))
        // The web view names the page being loaded as soon as the load starts.
        try #require(webView.url?.host() == "www.example.org")
        session.browser.webView(webView, didStartProvisionalNavigation: nil)
        #expect(session.currentHost == "example.com")

        try await waitFor { session.currentHost == "www.example.org" }
        #expect(session.browser.committedURL?.host() == "www.example.org")
    }
}
