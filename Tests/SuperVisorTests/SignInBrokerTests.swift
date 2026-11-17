import Foundation
import Testing
import WebKit

@testable import SuperVisor

private let usernameField = FieldKey(name: "username", id: "user", autocomplete: "username", type: "text")
private let passwordField = FieldKey(
    name: "password",
    id: "pass",
    autocomplete: "current-password",
    type: "password"
)
private let codeField = FieldKey(name: "otp", id: "otp", autocomplete: "one-time-code", type: "text")

private func step(_ kind: SignInStep.Kind, _ path: String, _ field: FieldKey) -> SignInStep {
    SignInStep(kind: kind, origin: "https://example.com", path: path, field: field)
}

@Suite("Sign-in broker", .serialized)
@MainActor
struct SignInBrokerTests {
    private func browser(_ bank: TestBank, policy: SiteNavigationPolicy? = nil) -> SiteBrowser {
        SiteBrowser(
            policy: policy ?? SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: bank.site.answer,
            settling: .fast
        )
    }

    /// A grant for the bank, signing in through `steps`.
    private func grant(
        _ bank: TestBank,
        steps: [SignInStep],
        kind: SiteGrant.CodeKind = .none,
        key: String? = nil,
        sender: String? = nil,
        fillHosts: [String] = ["example.com"],
        signOutControlSeen: Bool = false
    ) -> SiteGrant {
        SiteGrant(
            username: bank.username,
            password: bank.password,
            authenticatorKey: key,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: fillHosts,
            browseHosts: ["example.com"],
            codeKind: kind,
            codeSender: sender,
            signInSteps: steps,
            signOutControlSeen: signOutControlSeen
        )
    }

    /// Runs the enrollment sign-in on the login page, returning what it recorded and the
    /// browser it used.
    private func enroll(
        _ bank: TestBank,
        kind: SiteGrant.CodeKind = .none,
        key: String? = nil,
        sender: String? = nil,
        stub: CodeStub = CodeStub()
    ) async throws -> (assisted: AssistedSignIn, browser: SiteBrowser) {
        let browser = browser(bank, policy: .anyHTTPSHost)
        _ = try await browser.open(URL(string: "https://example.com/login")!)
        let assisted = await SignInBroker(browser: browser).assistedSignIn(
            username: bank.username,
            password: bank.password,
            authenticatorKey: key,
            codeKind: kind,
            codeSender: sender,
            codes: stub.codes
        )
        return (assisted, browser)
    }

    /// Signs the bank out, opens the start page in a fresh browser, and signs in unattended.
    private func replay(
        _ grant: SiteGrant,
        bank: TestBank,
        stub: CodeStub = CodeStub()
    ) async throws -> SignInOutcome {
        bank.signOut()
        let fresh = browser(bank)
        defer { fresh.close() }
        _ = try await fresh.open(grant.startURL)
        return await SignInBroker(browser: fresh).signIn(with: grant, codes: stub.codes)
    }

    // MARK: Enrollment, then unattended

    @Test("A one-page login signs in during enrollment, records two steps, and the steps sign in on a fresh browser", .timeLimit(.minutes(1)))
    func onePage() async throws {
        let bank = TestBank()
        let (assisted, enrolled) = try await enroll(bank)
        defer { enrolled.close() }

        #expect(assisted.steps == [
            step(.username, "/login", usernameField),
            step(.password, "/login", passwordField),
        ])
        #expect(assisted.stoppedBecause == nil)
        #expect(assisted.learnedCodeSender == nil)
        #expect(assisted.submissionHosts == ["example.com"])
        #expect(bank.signedIn)
        #expect(bank.site.posts.count == 1)
        #expect(bank.site.posts.first?.fields == ["username": bank.username, "password": bank.password])

        bank.site.forgetRequests()
        let outcome = try await replay(grant(bank, steps: assisted.steps), bank: bank)

        #expect(outcome == .signedIn)
        #expect(bank.signedIn)
        #expect(bank.site.posts.count == 1)
        #expect(bank.site.posts.first?.fields == ["username": bank.username, "password": bank.password])
    }

    @Test("A two-step login, the username page and then the password page at another path", .timeLimit(.minutes(1)))
    func twoStep() async throws {
        let bank = TestBank()
        bank.flow = .twoStep
        let (assisted, enrolled) = try await enroll(bank)
        defer { enrolled.close() }

        #expect(assisted.steps == [
            step(.username, "/login", usernameField),
            step(.password, "/password", passwordField),
        ])
        #expect(assisted.stoppedBecause == nil)
        #expect(bank.site.posts.map(\.path) == ["/identify", "/session"])

        bank.site.forgetRequests()
        let outcome = try await replay(grant(bank, steps: assisted.steps), bank: bank)

        #expect(outcome == .signedIn)
        #expect(bank.site.posts.map(\.path) == ["/identify", "/session"])
        #expect(bank.site.posts.last?.fields["password"] == bank.password)
    }

    @Test("A code step reads the authenticator key, in enrollment and unattended", .timeLimit(.minutes(1)))
    func authenticatorCode() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(authenticator: bank.code)
        let (assisted, enrolled) = try await enroll(bank, kind: .authenticator, key: CodeStub.sampleKey, stub: stub)
        defer { enrolled.close() }

        #expect(assisted.steps.map(\.kind) == [.username, .password, .code])
        #expect(assisted.steps.last == step(.code, "/verify", codeField))
        #expect(assisted.stoppedBecause == nil)
        #expect(stub.calls.filter { $0.hasPrefix("authenticator") } == ["authenticator \(CodeStub.sampleKey)"])
        #expect(bank.site.posts.last?.fields == ["otp": bank.code])

        let replayStub = CodeStub(authenticator: bank.code)
        let signIn = grant(bank, steps: assisted.steps, kind: .authenticator, key: CodeStub.sampleKey)
        #expect(signIn.isValid(for: "example.com"))
        let outcome = try await replay(signIn, bank: bank, stub: replayStub)

        #expect(outcome == .signedIn)
        #expect(replayStub.calls.filter { $0.hasPrefix("authenticator") } == ["authenticator \(CodeStub.sampleKey)"])
    }

    @Test("A texted code is read after the baseline taken before the submit that requested it, and enrollment learns the sender", .timeLimit(.minutes(1)))
    func textedCode() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(texted: bank.code, firstText: (bank.code, "24273"))
        let (assisted, enrolled) = try await enroll(bank, kind: .text, sender: nil, stub: stub)
        defer { enrolled.close() }

        #expect(assisted.steps.map(\.kind) == [.username, .password, .code])
        #expect(assisted.learnedCodeSender == "24273")
        #expect(assisted.stoppedBecause == nil)
        // Baselines count 100, 101, ...: 100 at the start, 101 before the submit of the
        // username and password, which is the one that makes the site text a code.
        #expect(stub.calls.filter { $0.hasPrefix("first") } == ["first 101"])

        let replayStub = CodeStub(texted: bank.code)
        let signIn = grant(bank, steps: assisted.steps, kind: .text, sender: "24273")
        let outcome = try await replay(signIn, bank: bank, stub: replayStub)

        #expect(outcome == .signedIn)
        #expect(replayStub.calls.filter { $0.hasPrefix("texted") } == ["texted 24273 101"])
        #expect(!replayStub.calls.contains { $0.hasPrefix("first") })
    }

    @Test("A texted code with a sender given at enrollment is read from that sender", .timeLimit(.minutes(1)))
    func textedCodeWithKnownSender() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(texted: bank.code, firstText: ("000000", "99999"))
        let (assisted, enrolled) = try await enroll(bank, kind: .text, sender: "24273", stub: stub)
        defer { enrolled.close() }

        #expect(assisted.learnedCodeSender == nil)
        #expect(assisted.stoppedBecause == nil)
        #expect(stub.calls.contains("texted 24273 101"))
        #expect(!stub.calls.contains { $0.hasPrefix("first") })
        #expect(bank.signedIn)
    }

    @Test("An emailed code is asked for by its sender, in enrollment and unattended", .timeLimit(.minutes(1)))
    func emailedCode() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let sender = "no-reply@bank.example"
        let stub = CodeStub(emailed: bank.code)
        let (assisted, enrolled) = try await enroll(bank, kind: .email, sender: sender, stub: stub)
        defer { enrolled.close() }

        #expect(assisted.steps.map(\.kind) == [.username, .password, .code])
        #expect(assisted.stoppedBecause == nil)
        #expect(stub.calls.filter { $0.hasPrefix("emailed") } == ["emailed \(sender)"])

        let replayStub = CodeStub(emailed: bank.code)
        let outcome = try await replay(
            grant(bank, steps: assisted.steps, kind: .email, sender: sender),
            bank: bank,
            stub: replayStub
        )

        #expect(outcome == .signedIn)
        #expect(replayStub.calls.filter { $0.hasPrefix("emailed") } == ["emailed \(sender)"])
    }

    @Test(
        "A code that is missing or not four to eight digits stops the sign-in before anything is typed",
        arguments: [nil, "", "12ab56", "123", "123456789", "12 34 56", "482910\n", "٤٨٢٩١٠"]
    )
    func unusableCode(_ code: String?) async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let signIn = grant(
            bank,
            steps: [
                step(.username, "/login", usernameField),
                step(.password, "/login", passwordField),
                step(.code, "/verify", codeField),
            ],
            kind: .authenticator,
            key: CodeStub.sampleKey
        )

        let outcome = try await replay(signIn, bank: bank, stub: CodeStub(authenticator: code))

        #expect(outcome == .needsPerson(.noCode))
        #expect(!bank.signedIn)
        #expect(bank.site.posts.map(\.path) == ["/session"])
    }

    @Test("A texted code needs a baseline, a sender, and a code that arrived", .timeLimit(.minutes(1)))
    func textedCodeUnavailable() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let steps = [
            step(.username, "/login", usernameField),
            step(.password, "/login", passwordField),
            step(.code, "/verify", codeField),
        ]
        let signIn = grant(bank, steps: steps, kind: .text, sender: "24273")

        let noBaseline = CodeStub(baselineAvailable: false)
        #expect(try await replay(signIn, bank: bank, stub: noBaseline) == .needsPerson(.noCode))
        #expect(!noBaseline.calls.contains { $0.hasPrefix("texted") })

        let noText = CodeStub(texted: nil)
        #expect(try await replay(signIn, bank: bank, stub: noText) == .needsPerson(.noCode))
        #expect(noText.calls.contains("texted 24273 101"))
        #expect(!bank.signedIn)
    }

    // MARK: Pages that are not recorded

    @Test("A page after sign-in that asks for the password at an unrecorded path is never filled", .timeLimit(.minutes(1)))
    func confirmPageIsNeverFilled() async throws {
        let bank = TestBank()
        bank.asksToConfirm = true
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        bank.signOut()
        let fresh = browser(bank)
        defer { fresh.close() }
        let signIn = grant(bank, steps: steps)
        _ = try await fresh.open(signIn.startURL)
        let outcome = await SignInBroker(browser: fresh).signIn(with: signIn, codes: CodeStub().codes)

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(fresh.currentURL?.path == "/confirm")
        #expect(bank.site.posts.map(\.path) == ["/session"])
        #expect(bank.site.requests(to: "/confirm").allSatisfy { !$0.isPost })
        let typed = try await fresh.run("return document.getElementById('again').value;")
        #expect(typed.string == "")
    }

    @Test("A recorded step whose path matches but whose field has another name, id, and token is not filled", .timeLimit(.minutes(1)))
    func differentFieldNameIsNotFilled() async throws {
        let bank = TestBank()
        bank.usernameFieldName = "login_id"
        bank.usernameFieldID = "member-box"
        bank.usernameAutocomplete = "off"
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        bank.signOut()
        let fresh = browser(bank)
        defer { fresh.close() }
        let signIn = grant(bank, steps: steps)
        _ = try await fresh.open(signIn.startURL)
        let outcome = await SignInBroker(browser: fresh).signIn(with: signIn, codes: CodeStub().codes)

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(bank.site.posts.isEmpty)
        let typed = try await fresh.run("""
            return [document.getElementById('member-box').value, document.getElementById('pass').value];
            """)
        #expect(typed.array?.compactMap(\.string) == ["", ""])
    }

    @Test("A site that renames only the username field's name is still filled, as its id and token are the recorded ones", .timeLimit(.minutes(1)))
    func renamedNameIsStillMatchedById() async throws {
        let bank = TestBank()
        bank.usernameFieldName = "login_id"
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]
        // The site's own check reads the field by its new name, so the sign-in lands.
        let outcome = try await replay(grant(bank, steps: steps), bank: bank)

        #expect(outcome == .signedIn)
        #expect(bank.site.posts.first?.fields["login_id"] == bank.username)
    }

    @Test("A site that shows the login form again after a submission ends needing a person, with one submission", .timeLimit(.minutes(1)))
    func loginFormKeepsReturning() async throws {
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        // The browser is sent back to the login page.
        let redirecting = TestBank()
        redirecting.neverSignsIn = true
        let redirected = try await replay(grant(redirecting, steps: steps), bank: redirecting)
        #expect(redirected == .needsPerson(.stillSignedOut))
        #expect(redirecting.site.posts.count == 1)

        // The login page is rendered where the form was posted, a page that is not recorded.
        let inPlace = TestBank()
        inPlace.neverSignsIn = true
        inPlace.rendersFailureInPlace = true
        let rendered = try await replay(grant(inPlace, steps: steps), bank: inPlace)
        #expect(rendered == .needsPerson(.unrecognisedPage))
        #expect(inPlace.site.posts.count == 1)

        // A wrong password does the same.
        let wrong = TestBank()
        var signIn = grant(wrong, steps: steps)
        signIn = SiteGrant(
            username: signIn.username,
            password: "not-the-password",
            authenticatorKey: nil,
            signInURL: signIn.signInURL,
            startURL: signIn.startURL,
            fillHosts: signIn.fillHosts,
            browseHosts: signIn.browseHosts,
            codeKind: .none,
            codeSender: nil,
            signInSteps: steps
        )
        #expect(try await replay(signIn, bank: wrong) == .needsPerson(.stillSignedOut))
        #expect(wrong.site.posts.count == 1)
    }

    @Test("A session that does not hold is reported when the start page is loaded again", .timeLimit(.minutes(1)))
    func sessionDoesNotHold() async throws {
        let bank = TestBank()
        bank.startPageIgnoresSession = true
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        let outcome = try await replay(grant(bank, steps: steps), bank: bank)

        #expect(bank.signedIn)
        #expect(outcome == .needsPerson(.stillSignedOut))
        #expect(bank.site.posts.count == 1)
    }

    @Test("A grant with no recorded steps loads nothing and needs a person", .timeLimit(.minutes(1)))
    func noRecordedSteps() async throws {
        let bank = TestBank()
        let bare = browser(bank)
        defer { bare.close() }

        let outcome = await SignInBroker(browser: bare).signIn(with: grant(bank, steps: []), codes: CodeStub().codes)

        #expect(outcome == .needsPerson(.noRecordedSteps))
        #expect(bank.site.requests.isEmpty)
        #expect(bare.currentURL == nil)
    }

    // MARK: Challenges

    @Test(
        "A challenge a person must answer stops both flows before anything is typed",
        arguments: [
            "<iframe src=\"https://www.recaptcha.net/recaptcha/api2/anchor\"></iframe>",
            "<iframe src=\"https://www.google.com/recaptcha/api2/anchor\"></iframe>",
            "<iframe src=\"https://newassets.hcaptcha.com/captcha/v1/frame\"></iframe>",
            "<iframe src=\"https://challenges.cloudflare.com/cdn-cgi/challenge-platform/turnstile/if\"></iframe>",
            "<iframe src=\"https://client-api.arkoselabs.com/v2/frame\"></iframe>",
            "<iframe src=\"https://funcaptcha.com/frame\"></iframe>",
            "<iframe src=\"https://www.recaptcha.net/x\" style=\"width:150px;height:60px;border:0\"></iframe>",
            "<div class=\"g-recaptcha\" style=\"width:304px;height:78px\"></div>",
            "<div id=\"hCaptcha-box\" style=\"width:400px;height:100px\"></div>",
            "<div class=\"login CAPTCHA-wrapper\" style=\"width:150px;height:60px\">check</div>",
        ]
    )
    func challengeStopsBothFlows(_ markup: String) async throws {
        let bank = TestBank()
        bank.extraLoginMarkup = markup
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        let outcome = try await replay(grant(bank, steps: steps), bank: bank)
        #expect(outcome == .needsPerson(.challenge))

        let (assisted, enrolled) = try await enroll(bank)
        defer { enrolled.close() }
        #expect(assisted.stoppedBecause == .challenge)
        #expect(assisted.steps.isEmpty)

        #expect(bank.site.posts.isEmpty)
        #expect(!bank.signedIn)
    }

    @Test(
        "Something that is not a visible, interactive challenge does not stop the sign-in",
        arguments: [
            "<iframe src=\"about:blank\"></iframe><div class=\"promo\" id=\"banner\"></div>",
            // The badge a challenge that runs unseen floats over the page, alone or with its frame.
            "<div class=\"grecaptcha-badge\" style=\"width:256px;height:60px\"></div>",
            "<div class=\"grecaptcha-badge\" style=\"width:256px;height:60px\"><iframe src=\"https://www.google.com/recaptcha/api2/anchor\" style=\"width:256px;height:60px\"></iframe></div>",
            "<div class=\"grecaptcha-badge\" style=\"width:256px;height:60px\"><div class=\"captcha-inner\" style=\"width:200px;height:50px\"></div></div>",
            // Hidden, or too small to be answered.
            "<iframe src=\"https://www.recaptcha.net/x\" style=\"display:none\"></iframe>",
            "<iframe src=\"https://www.recaptcha.net/x\" style=\"width:1px;height:1px\"></iframe>",
            "<iframe src=\"https://www.recaptcha.net/x\" style=\"width:149px;height:200px;border:0\"></iframe>",
            "<iframe src=\"https://www.recaptcha.net/x\" style=\"width:300px;height:59px;border:0\"></iframe>",
            "<div class=\"g-recaptcha\"></div>",
            "<div class=\"captcha\" style=\"visibility:hidden;width:300px;height:100px\"></div>",
            "<div class=\"captcha\" style=\"width:149px;height:80px\"></div>",
        ]
    )
    func notAChallenge(_ markup: String) async throws {
        let bank = TestBank()
        bank.extraLoginMarkup = markup
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        #expect(try await replay(grant(bank, steps: steps), bank: bank) == .signedIn)

        bank.signOut()
        let (assisted, enrolled) = try await enroll(bank)
        defer { enrolled.close() }
        #expect(assisted.stoppedBecause != .challenge)
        #expect(assisted.steps.map(\.kind) == [.username, .password])
    }

    // MARK: Enrollment stops

    @Test("Enrollment stops where a site keeps showing the form, with what it filled recorded", .timeLimit(.minutes(1)))
    func assistedStopsWhenFormReturns() async throws {
        let bank = TestBank()
        bank.neverSignsIn = true
        let (assisted, enrolled) = try await enroll(bank)
        defer { enrolled.close() }

        #expect(assisted.stoppedBecause == .stillSignedOut)
        #expect(assisted.steps.map(\.kind) == [.username, .password])
        #expect(bank.site.posts.count == 1)
    }

    @Test("Enrollment on a page it does not know stops, leaving the rest to the user", .timeLimit(.minutes(1)))
    func assistedStopsWithNothingToFill() async throws {
        let bank = TestBank()
        let enrolled = browser(bank, policy: .anyHTTPSHost)
        defer { enrolled.close() }
        _ = try await enrolled.open(URL(string: "https://example.com/cards")!)

        let assisted = await SignInBroker(browser: enrolled).assistedSignIn(
            username: bank.username,
            password: bank.password,
            authenticatorKey: nil,
            codeKind: .none,
            codeSender: nil,
            codes: CodeStub().codes
        )

        #expect(assisted.stoppedBecause == nil)
        #expect(assisted.steps.isEmpty)
        #expect(bank.site.posts.isEmpty)
    }

    @Test("A code page when no code kind was given stops enrollment", .timeLimit(.minutes(1)))
    func assistedCodePageWithoutCodeKind() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let (assisted, enrolled) = try await enroll(bank, kind: .none)
        defer { enrolled.close() }

        #expect(assisted.stoppedBecause == .noCode)
        #expect(assisted.steps.map(\.kind) == [.username, .password])
        #expect(bank.site.posts.map(\.path) == ["/session"])
    }

    // MARK: The fill guard

    @Test("The fill does nothing when the page is not the one expected", .timeLimit(.minutes(1)))
    func fillGuardsTheExpectedPage() async throws {
        let bank = TestBank()
        let twin = TestPages.page("Twin", """
            <form method="post" action="/session">
            <input type="text" id="user" name="username" autocomplete="username">
            <input type="password" id="pass" name="password" autocomplete="current-password">
            <button type="submit">Sign in</button></form>
            """)
        bank.site.route("/other-login", page: twin)
        bank.site.route("/login", host: "www.example.com", page: twin)
        let both = browser(bank, policy: SiteNavigationPolicy(browseHosts: ["example.com", "www.example.com"]))
        defer { both.close() }
        let broker = SignInBroker(browser: both)
        let requests = [
            SignInBroker.FillRequest(kind: .username, key: usernameField, value: bank.username),
            SignInBroker.FillRequest(kind: .password, key: passwordField, value: bank.password),
        ]

        // The page the probe described was /login; the browser is now on a page with the same form.
        _ = try await both.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()
        _ = try await both.open(URL(string: "https://example.com/other-login")!)
        var status = try await broker.fill(origin: probe.origin, path: probe.path, allowedHosts: ["example.com"], requests: requests)
        #expect(status == .moved)

        // The same path on another origin.
        _ = try await both.open(URL(string: "https://www.example.com/login")!)
        status = try await broker.fill(origin: probe.origin, path: probe.path, allowedHosts: ["example.com"], requests: requests)
        #expect(status == .moved)

        let typed = try await both.run("""
            return [document.getElementById('user').value, document.getElementById('pass').value];
            """)
        #expect(typed.array?.compactMap(\.string) == ["", ""])
        #expect(bank.site.posts.isEmpty)

        // Control: expecting the page it is on, the same call fills and submits.
        _ = try await both.open(URL(string: "https://example.com/other-login")!)
        let here = try await broker.probe()
        let mark = both.markAction()
        status = try await broker.fill(origin: here.origin, path: here.path, allowedHosts: ["example.com"], requests: requests)
        try await both.settleAfterAction(since: mark)
        #expect(status == .filled(actionHost: "example.com"))
        #expect(bank.site.posts.count == 1)
    }

    @Test("A fill into the page it expects submits the form", .timeLimit(.minutes(1)))
    func fillSubmits() async throws {
        let bank = TestBank()
        let page = browser(bank)
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()

        let mark = page.markAction()
        let status = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: ["example.com"],
            requests: [
                SignInBroker.FillRequest(kind: .username, key: usernameField, value: bank.username),
                SignInBroker.FillRequest(kind: .password, key: passwordField, value: bank.password),
            ]
        )
        try await page.settleAfterAction(since: mark)

        #expect(status == .filled(actionHost: "example.com"))
        #expect(bank.signedIn)
        #expect(bank.site.posts.count == 1)
    }

    @Test("A form that submits to a host that is not a fill host is not filled", .timeLimit(.minutes(1)))
    func foreignActionIsNotFilled() async throws {
        let bank = TestBank()
        bank.formAction = "https://evil.test/collect"
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        bank.signOut()
        let fresh = browser(bank, policy: SiteNavigationPolicy(browseHosts: ["example.com", "evil.test"]))
        defer { fresh.close() }
        let signIn = grant(bank, steps: steps)
        _ = try await fresh.open(signIn.startURL)
        let outcome = await SignInBroker(browser: fresh).signIn(with: signIn, codes: CodeStub().codes)

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(!bank.site.requests.contains { $0.host == "evil.test" })
        let typed = try await fresh.run("""
            return [document.getElementById('user').value, document.getElementById('pass').value];
            """)
        #expect(typed.array?.compactMap(\.string) == ["", ""])
    }

    @Test("Enrollment reports where the form it filled submits to", .timeLimit(.minutes(1)))
    func assistedReportsSubmissionHost() async throws {
        let bank = TestBank()
        bank.formAction = "https://auth.example.com/collect"
        bank.site.route(
            "/collect",
            method: "POST",
            host: "auth.example.com",
            page: TestPages.redirect(to: "https://example.com/account")
        )
        let (assisted, enrolled) = try await enroll(bank)
        defer { enrolled.close() }

        #expect(assisted.steps.map(\.kind) == [.username, .password])
        #expect(assisted.submissionHosts == ["auth.example.com"])
    }

    @Test("A form that would send its fields in the address is stopped, and one a script takes over is not", .timeLimit(.minutes(1)))
    func getFormIsBlocked() async throws {
        let bank = TestBank()
        bank.formMethod = "get"
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]

        let outcome = try await replay(grant(bank, steps: steps), bank: bank)

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(!bank.signedIn)
        #expect(!bank.site.requests.contains { $0.fields["password"] != nil })
        #expect(bank.site.requests.allSatisfy { $0.path != "/session" })

        // A form handled by the page's own script is submitted as the page intends.
        let spa = TestSite()
        spa.route("/login", page: TestPages.page("Login", """
            <form id="f" action="/session"><input name="username" id="user" autocomplete="username">
            <input type="password" name="password" id="pass" autocomplete="current-password"></form>
            """, script: """
            document.getElementById('f').addEventListener('submit', (event) => {
              event.preventDefault();
              document.title = 'handled ' + document.getElementById('pass').value.length;
            });
            """))
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: spa.answer,
            settling: .fast
        )
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()
        let status = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: ["example.com"],
            requests: [SignInBroker.FillRequest(kind: .password, key: passwordField, value: "twelve-chars")]
        )

        #expect(status == .filled(actionHost: "example.com"))
        let title = try await page.run("return document.title;")
        #expect(title.string == "handled 12")
        #expect(spa.requests.map(\.path) == ["/login"])
    }

    @Test("A fill sets the value and dispatches bubbling input and change events the page's own scripts hear", .timeLimit(.minutes(1)))
    func fillEventsReachThePage() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("", """
            <div id="wrap"><input name="username" id="user" autocomplete="username"></div>
            """, script: """
            document.getElementById('wrap').addEventListener('input', (event) => {
              document.title += 'I' + document.getElementById('user').value;
            });
            document.getElementById('wrap').addEventListener('change', () => { document.title += 'C'; });
            """))
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast
        )
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()

        let status = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: nil,
            requests: [SignInBroker.FillRequest(kind: .username, key: usernameField, value: "alice")]
        )

        // Both events reached a listener on the field's parent, the input event with the value
        // already in place, and no way to submit was found.
        #expect(status == .noSubmit)
        let title = try await page.run("return document.title;")
        #expect(title.string == "IaliceC")
    }

    @Test("A field that two visible inputs match is not filled", .timeLimit(.minutes(1)))
    func ambiguousFieldIsNotFilled() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Login", """
            <form action="/session" method="post">
            <input name="username" id="first" autocomplete="username"><input name="username" id="second">
            <input type="password" name="password"></form>
            """))
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast
        )
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()

        let status = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: nil,
            requests: [SignInBroker.FillRequest(kind: .username, key: usernameField, value: "alice")]
        )

        #expect(status == .ambiguous)
        #expect(SignInRules.visibleField(for: step(.username, "/login", usernameField), on: probe) == nil)
        let typed = try await page.run("return document.getElementById('first').value + document.getElementById('second').value;")
        #expect(typed.string == "")
    }

    @Test("A fill whose field is gone reports it and types nothing", .timeLimit(.minutes(1)))
    func missingFieldIsNotFilled() async throws {
        let bank = TestBank()
        let page = browser(bank)
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()

        let status = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: nil,
            requests: [
                SignInBroker.FillRequest(kind: .username, key: usernameField, value: "alice"),
                SignInBroker.FillRequest(
                    kind: .password,
                    key: FieldKey(name: "nothing", id: "", autocomplete: "", type: "password"),
                    value: "secret"
                ),
            ]
        )

        #expect(status == .missing)
        let typed = try await page.run("return document.getElementById('user').value;")
        #expect(typed.string == "")
    }

    @Test("A password step never fills a plain text field, nor another step a password field", .timeLimit(.minutes(1)))
    func kindMustMatchTheFieldType() async throws {
        let site = TestSite()
        site.route("/login", page: TestPages.page("Login", """
            <input name="password" id="shown" type="text">
            <input name="username" id="hidden-pass" type="password">
            """))
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast
        )
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let probe = try await broker.probe()

        let asPassword = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: nil,
            requests: [SignInBroker.FillRequest(kind: .password, key: FieldKey(name: "password", id: "", autocomplete: "", type: "text"), value: "s")]
        )
        let asUsername = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: nil,
            requests: [SignInBroker.FillRequest(kind: .username, key: FieldKey(name: "username", id: "", autocomplete: "", type: "password"), value: "u")]
        )

        #expect(asPassword == .missing)
        #expect(asUsername == .missing)
    }

    // MARK: The probe

    @Test("The probe lists visible, enabled, writable text inputs with their identifying attributes", .timeLimit(.minutes(1)))
    func probeFields() async throws {
        let site = TestSite()
        site.route("/form", page: TestPages.page("Form", """
            <input name="Name" id="a" autocomplete="Username" type="TEXT" inputmode="Numeric" maxlength="6">
            <input id="b" type="password">
            <input name="c">
            <input name="hidden-type" type="hidden">
            <input name="submit" type="submit">
            <input name="box" type="checkbox">
            <input name="gone" style="display:none">
            <input name="invisible" style="visibility:hidden">
            <input name="clear" style="opacity:0">
            <input name="zero" style="width:0;height:0;padding:0;border:0">
            <input name="off" disabled>
            <input name="frozen" readonly>
            <div style="display:none"><input name="nested-gone" type="password"></div>
            """))
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast
        )
        defer { page.close() }
        _ = try await page.open(URL(string: "https://example.com/form")!)

        let probe = try await SignInBroker(browser: page).probe()

        #expect(probe.origin == "https://example.com")
        #expect(probe.path == "/form")
        #expect(probe.isSecureTopFrame)
        #expect(!probe.hasChallenge)
        #expect(probe.fields.map(\.key) == [
            FieldKey(name: "Name", id: "a", autocomplete: "username", type: "text"),
            FieldKey(name: "", id: "b", autocomplete: "", type: "password"),
            FieldKey(name: "c", id: "", autocomplete: "", type: ""),
        ])
        #expect(probe.fields[0].inputMode == "numeric")
        #expect(probe.fields[0].maxLength == 6)
        #expect(probe.fields[2].maxLength == nil)
        #expect(probe.hasVisiblePassword)
    }

    @Test("A password field that is not shown does not make a page a sign-in page", .timeLimit(.minutes(1)))
    func hiddenPasswordIsNotAShownOne() async throws {
        let bank = TestBank()
        bank.markSignedIn()
        bank.site.route("/account", page: TestPages.page("Settings", """
            <p>Settings</p><div style="display:none"><input type="password" name="password"></div>
            <input type="password" style="visibility:hidden"><input type="hidden" name="password">
            """))
        let page = browser(bank)
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        let signIn = grant(bank, steps: [step(.username, "/login", usernameField)])

        _ = try await page.open(signIn.startURL)
        #expect(try await broker.probe().hasVisiblePassword == false)
        #expect(try await broker.isSignedIn(signIn))

        bank.site.route("/account", page: TestPages.page("Sign in", "<input type=\"password\" name=\"password\">"))
        _ = try await page.open(signIn.startURL)
        #expect(try await broker.probe().hasVisiblePassword)
        #expect(try await broker.isSignedIn(signIn) == false)
    }

    @Test("The session is signed in only on the start page, with no sign-in asked for, and with a sign-out control when one was seen", .timeLimit(.minutes(2)))
    func signedInDecisionOnPages() async throws {
        let bank = TestBank()
        let page = browser(bank)
        defer { page.close() }
        let broker = SignInBroker(browser: page)
        let steps = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]
        let plain = grant(bank, steps: steps)
        let strict = grant(bank, steps: steps, signOutControlSeen: true)

        // A signed-in start page with a sign-out link.
        bank.markSignedIn()
        _ = try await page.open(plain.startURL)
        #expect(try await broker.isSignedIn(plain))
        #expect(try await broker.isSignedIn(strict))

        // A public start page, with no sign-out control, is signed in unless one was seen.
        bank.startPageIsPublic = true
        bank.signOut()
        _ = try await page.open(plain.startURL)
        #expect(try await broker.isSignedIn(plain))
        #expect(try await broker.isSignedIn(strict) == false)

        // A redirect to the login page is another path, and asks for a password.
        bank.startPageIsPublic = false
        _ = try await page.open(plain.startURL)
        #expect(page.currentURL?.path == "/login")
        #expect(try await broker.isSignedIn(plain) == false)
        #expect(try await broker.isSignedIn(strict) == false)

        // A code page at the start path.
        bank.site.route("/account", page: TestPages.page("Code", """
            <p>Enter the code</p><a href="/logout">Sign out</a>
            <form method="post" action="/verify"><input name="otp" autocomplete="one-time-code"></form>
            """))
        _ = try await page.open(plain.startURL)
        #expect(try await broker.isSignedIn(plain) == false)

        // A sign-in frame the size of the page's content.
        bank.site.route("/account", page: TestPages.page("Framed", """
            <a href="/logout">Sign out</a>
            <iframe src="https://accounts.example.com/signin" style="width:400px;height:300px"></iframe>
            """))
        _ = try await page.open(plain.startURL)
        #expect(try await broker.isSignedIn(plain) == false)
    }

    @Test("A page at a recorded path without the recorded field is not a sign-in page", .timeLimit(.minutes(1)))
    func recordedPathWithoutTheFieldIsNotASignIn() async throws {
        let bank = TestBank()
        bank.site.route("/account", page: TestPages.page("Signed in already", "<p>You are signed in.</p>"))
        let page = browser(bank)
        defer { page.close() }
        let signIn = grant(bank, steps: [SignInStep(
            kind: .username,
            origin: "https://example.com",
            path: "/account",
            field: usernameField
        )])
        _ = try await page.open(signIn.startURL)

        #expect(try await SignInBroker(browser: page).isSignedIn(signIn))
    }

    // MARK: Submitting

    private let samplePassword = "Pw-" + UUID().uuidString.lowercased()

    /// A site whose start page sends the browser to a login page made of `form` and `script`.
    private func loginSite(form: String, script: String = "") -> TestSite {
        let site = TestSite()
        site.route("/account", page: TestPages.redirect(to: "/login"))
        site.route("/login", page: TestPages.page("Login", form, script: script))
        site.route("/session", method: "POST", page: TestPages.page("Posted", "<p>posted</p>"))
        site.route("/session", page: TestPages.page("Posted", "<p>posted</p>"))
        return site
    }

    private func standardForm(
        method: String = "post",
        action: String = "/session",
        button: String = "<button type=\"submit\">Sign in</button>"
    ) -> String {
        """
        <form id="f" method="\(method)" action="\(action)">
        <input type="text" id="user" name="username" autocomplete="username">
        <input type="password" id="pass" name="password" autocomplete="current-password">
        \(button)</form>
        """
    }

    private var defaultSteps: [SignInStep] {
        [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]
    }

    /// Opens the site's start page and signs in through the default steps.
    private func signIn(
        on site: TestSite,
        codes: SignInCodes? = nil
    ) async throws -> (outcome: SignInOutcome, browser: SiteBrowser) {
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast
        )
        let signIn = SiteGrant(
            username: "alice",
            password: samplePassword,
            authenticatorKey: nil,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil,
            signInSteps: defaultSteps
        )
        _ = try await page.open(signIn.startURL)
        let outcome = await SignInBroker(browser: page).signIn(with: signIn, codes: codes ?? CodeStub().codes)
        return (outcome, page)
    }

    @Test("A form whose submit controls are all disabled is not submitted", .timeLimit(.minutes(1)))
    func disabledSubmitIsNotSubmitted() async throws {
        let site = loginSite(form: standardForm(button: "<button type=\"submit\" disabled>Sign in</button>"))

        let (outcome, page) = try await signIn(on: site)
        defer { page.close() }

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(site.posts.isEmpty)
    }

    @Test("A submit control the page enables as the fields fill is used, and an enabled one beside a disabled one", .timeLimit(.minutes(1)))
    func submitEnabledByTheFill() async throws {
        let enabling = loginSite(
            form: standardForm(button: "<button type=\"submit\" id=\"go\" disabled>Sign in</button>"),
            script: """
            document.getElementById('pass').addEventListener('input', () => {
              document.getElementById('go').disabled = false;
            });
            """
        )
        let (enabled, first) = try await signIn(on: enabling)
        defer { first.close() }
        #expect(enabled == .needsPerson(.stillSignedOut))
        #expect(enabling.posts.count == 1)

        let beside = loginSite(form: standardForm(
            button: "<button type=\"submit\" disabled>Old</button><button type=\"submit\">Sign in</button>"
        ))
        let (alongside, second) = try await signIn(on: beside)
        defer { second.close() }
        #expect(alongside == .needsPerson(.stillSignedOut))
        #expect(beside.posts.count == 1)
    }

    @Test("A GET form whose handler stops the event from spreading still sends nothing", .timeLimit(.minutes(1)))
    func stoppedPropagationDoesNotHideAGetForm() async throws {
        let site = loginSite(
            form: standardForm(method: "get"),
            script: """
            document.getElementById('f').addEventListener('submit', (event) => { event.stopPropagation(); });
            window.addEventListener('submit', (event) => { document.title = 'saw it'; }, true);
            """
        )

        let (outcome, page) = try await signIn(on: site)
        defer { page.close() }

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(site.requests.map(\.path) == ["/account", "/login"])
        #expect(!site.requests.contains { $0.fields["password"] != nil })
        #expect(page.currentURL?.path == "/login")
    }

    @Test("A GET form a handler takes over, even one that stops the event from spreading, is left to the page", .timeLimit(.minutes(1)))
    func handledGetFormIsLeftToThePage() async throws {
        let site = loginSite(
            form: standardForm(method: "get"),
            script: """
            document.getElementById('f').addEventListener('submit', (event) => {
              event.stopPropagation();
              event.preventDefault();
              document.title = 'handled';
            });
            """
        )
        let page = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast
        )
        defer { page.close() }
        _ = try await page.open(URL(string: "https://example.com/login")!)
        let broker = SignInBroker(browser: page)
        let probe = try await broker.probe()

        let status = try await broker.fill(
            origin: probe.origin,
            path: probe.path,
            allowedHosts: ["example.com"],
            requests: [SignInBroker.FillRequest(kind: .password, key: passwordField, value: samplePassword)]
        )

        #expect(status == .filled(actionHost: "example.com"))
        #expect(try await page.run("return document.title;").string == "handled")
        #expect(site.requests.map(\.path) == ["/login"])
    }

    @Test("A form whose action changes while the fields fill is checked again just before it is submitted", .timeLimit(.minutes(1)))
    func actionChangedByTheFill() async throws {
        let site = loginSite(
            form: standardForm(),
            script: """
            document.getElementById('pass').addEventListener('input', () => {
              document.getElementById('f').setAttribute('action', 'https://evil.test/collect');
            });
            """
        )

        let (outcome, page) = try await signIn(on: site)
        defer { page.close() }

        #expect(outcome == .needsPerson(.unrecognisedPage))
        #expect(site.posts.isEmpty)
        #expect(!site.requests.contains { $0.host == "evil.test" })
    }

    // MARK: Interruption

    @Test("A sign-in on a browser that is closed is interrupted, and loads and submits nothing", .timeLimit(.minutes(1)))
    func closedBrowserInterruptsSignIn() async throws {
        let bank = TestBank()
        let page = browser(bank)
        let signIn = grant(bank, steps: defaultSteps)
        _ = try await page.open(signIn.startURL)
        page.close()
        bank.site.forgetRequests()

        let outcome = await SignInBroker(browser: page).signIn(with: signIn, codes: CodeStub().codes)

        #expect(outcome == .interrupted)
        #expect(bank.site.requests.isEmpty)
    }

    @Test("A browser closed while a code is awaited submits nothing more", .timeLimit(.minutes(1)))
    func closedWhileAwaitingACode() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let gate = TestGate()
        let stub = CodeStub(texted: bank.code, textedGate: gate)
        let page = browser(bank)
        let signIn = grant(
            bank,
            steps: defaultSteps + [step(.code, "/verify", codeField)],
            kind: .text,
            sender: "24273"
        )
        _ = try await page.open(signIn.startURL)
        let broker = SignInBroker(browser: page)

        let running = Task { @MainActor in await broker.signIn(with: signIn, codes: stub.codes) }
        while !stub.calls.contains(where: { $0.hasPrefix("texted") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        page.close()
        await gate.open()
        let outcome = await running.value

        #expect(outcome == .interrupted)
        #expect(bank.site.posts.map(\.path) == ["/session"])
    }

    /// Code sources whose texted-code source polls until its task is cancelled, recording that
    /// it began and that cancellation stopped it.
    private final class PollingSource: @unchecked Sendable {
        private let lock = NSLock()
        private var began = false
        private var stopped = false

        var hasBegun: Bool { lock.withLock { began } }
        var hasStopped: Bool { lock.withLock { stopped } }

        var codes: SignInCodes {
            SignInCodes(
                authenticator: { _ in nil },
                texted: { [self] _, _ in
                    lock.withLock { began = true }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    lock.withLock { stopped = true }
                    return nil
                },
                emailed: { _, _ in nil },
                messageBaseline: { 1 },
                firstTextedCode: { _ in nil }
            )
        }
    }

    private func waitFor(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test("Cancelling a sign-in that waits for a texted code cancels the code source's own task", .timeLimit(.minutes(1)))
    func cancellingStopsTheCodeSource() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let source = PollingSource()
        let page = browser(bank)
        defer { page.close() }
        let signIn = grant(bank, steps: defaultSteps + [step(.code, "/verify", codeField)], kind: .text, sender: "24273")
        _ = try await page.open(signIn.startURL)
        let broker = SignInBroker(browser: page)

        let running = Task { @MainActor in await broker.signIn(with: signIn, codes: source.codes) }
        #expect(try await waitFor { source.hasBegun })
        running.cancel()

        #expect(await running.value == .interrupted)
        #expect(try await waitFor { source.hasStopped })
    }

    @Test("Closing the browser of a sign-in that waits for a texted code stops the code source", .timeLimit(.minutes(1)))
    func closingStopsTheCodeSource() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let source = PollingSource()
        let page = browser(bank)
        let signIn = grant(bank, steps: defaultSteps + [step(.code, "/verify", codeField)], kind: .text, sender: "24273")
        _ = try await page.open(signIn.startURL)
        let broker = SignInBroker(browser: page)

        let running = Task { @MainActor in await broker.signIn(with: signIn, codes: source.codes) }
        #expect(try await waitFor { source.hasBegun })
        page.close()

        #expect(await running.value == .interrupted)
        #expect(try await waitFor { source.hasStopped })
        #expect(bank.site.posts.map(\.path) == ["/session"])
    }

    @Test("Cancelling an enrollment that waits for a texted code stops the code source", .timeLimit(.minutes(1)))
    func cancellingEnrollmentStopsTheCodeSource() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let source = PollingSource()
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: source.codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        let beginning = Task { @MainActor in
            try await enrollment.begin(
                signInAddress: "example.com/login",
                username: bank.username,
                password: bank.password,
                authenticatorKey: nil,
                codeKind: .text,
                codeSender: "24273"
            )
        }
        #expect(try await waitFor { source.hasBegun })
        enrollment.cancel()
        _ = try? await beginning.value

        #expect(try await waitFor { source.hasStopped })
        #expect(!enrollment.isWorking)
    }

    @Test("A sign-in whose task is cancelled while a code is awaited is interrupted", .timeLimit(.minutes(1)))
    func cancelledWhileAwaitingACode() async throws {
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(texted: bank.code, hangs: true)
        let page = browser(bank)
        defer { page.close() }
        let signIn = grant(
            bank,
            steps: defaultSteps + [step(.code, "/verify", codeField)],
            kind: .text,
            sender: "24273"
        )
        _ = try await page.open(signIn.startURL)
        let broker = SignInBroker(browser: page)

        let running = Task { @MainActor in await broker.signIn(with: signIn, codes: stub.codes) }
        while !stub.calls.contains(where: { $0.hasPrefix("texted") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        running.cancel()
        let outcome = await running.value

        #expect(outcome == .interrupted)
        #expect(bank.site.posts.map(\.path) == ["/session"])
    }

    // MARK: Waiting for codes

    @Test("A code source that never answers ends the wait with noCode at the limit, in each flow", .timeLimit(.minutes(1)))
    func codeWaitIsBounded() async throws {
        let limit = Duration.milliseconds(200)
        let started = ContinuousClock.now

        func unattended(kind: SiteGrant.CodeKind, sender: String) async throws -> SignInOutcome {
            let bank = TestBank()
            bank.requiresCode = true
            let page = browser(bank)
            defer { page.close() }
            let signIn = grant(
                bank,
                steps: defaultSteps + [step(.code, "/verify", codeField)],
                kind: kind,
                sender: sender
            )
            _ = try await page.open(signIn.startURL)
            return await SignInBroker(browser: page, codeWaitLimit: limit)
                .signIn(with: signIn, codes: CodeStub(hangs: true).codes)
        }
        #expect(try await unattended(kind: .text, sender: "24273") == .needsPerson(.noCode))
        #expect(try await unattended(kind: .email, sender: "no-reply@bank.example") == .needsPerson(.noCode))

        // Enrollment, where the first text from any sender is awaited, and where one is from a named sender.
        for (kind, sender) in [(SiteGrant.CodeKind.text, String?.none), (.text, "24273"), (.email, "no-reply@bank.example")] {
            let bank = TestBank()
            bank.requiresCode = true
            let page = browser(bank, policy: .anyHTTPSHost)
            defer { page.close() }
            _ = try await page.open(URL(string: "https://example.com/login")!)
            let assisted = await SignInBroker(browser: page, codeWaitLimit: limit).assistedSignIn(
                username: bank.username,
                password: bank.password,
                authenticatorKey: nil,
                codeKind: kind,
                codeSender: sender,
                codes: CodeStub(hangs: true).codes
            )
            #expect(assisted.stoppedBecause == .noCode)
            #expect(assisted.steps.map(\.kind) == [.username, .password])
        }
        // Five waits of 200 ms, each of which would otherwise have been an hour.
        #expect(ContinuousClock.now - started < .seconds(45))
    }

    @Test("The time a code was requested is the moment before the submit that requested it", .timeLimit(.minutes(1)))
    func emailedCodeIsAskedSince() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var seconds = 1_000.0
            func tick() -> Date {
                lock.withLock {
                    defer { seconds += 1 }
                    return Date(timeIntervalSince1970: seconds)
                }
            }
        }
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(emailed: bank.code)
        let clock = Clock()
        let page = browser(bank)
        defer { page.close() }
        let signIn = grant(
            bank,
            steps: defaultSteps + [step(.code, "/verify", codeField)],
            kind: .email,
            sender: "no-reply@bank.example"
        )
        _ = try await page.open(signIn.startURL)

        let outcome = await SignInBroker(browser: page, now: { clock.tick() }).signIn(with: signIn, codes: stub.codes)

        // The broker looked at the clock when it began (1,000), then before the submit that
        // asks the site for a code (1,001), and read the code with that second time.
        #expect(outcome == .signedIn)
        #expect(stub.emailedSince == [Date(timeIntervalSince1970: 1_001)])
    }

    // MARK: Nothing secret escapes

    @Test("No outcome, error, or log line the sign-in produces contains the password or a code", .timeLimit(.minutes(2)))
    func nothingSecretEscapes() async throws {
        let capture = AppLogCapture()
        AppLog.install(capture)
        defer { AppLog.install(nil) }
        let bank = TestBank()
        bank.requiresCode = true
        let stub = CodeStub(authenticator: bank.code, texted: bank.code, emailed: bank.code, firstText: (bank.code, "24273"))
        var produced: [String] = []

        func note(_ value: some Any) {
            produced.append("\(value)")
            produced.append(String(describing: value))
            produced.append(String(reflecting: value))
        }

        // A full sign-in, a failure, a refusal, and a challenge.
        let (assisted, enrolled) = try await enroll(bank, kind: .authenticator, key: CodeStub.sampleKey, stub: stub)
        enrolled.close()
        note(assisted)
        let signIn = grant(bank, steps: assisted.steps, kind: .authenticator, key: CodeStub.sampleKey)
        note(try await replay(signIn, bank: bank, stub: stub))

        bank.neverSignsIn = true
        note(try await replay(signIn, bank: bank, stub: stub))
        bank.neverSignsIn = false
        bank.showsChallenge = true
        note(try await replay(signIn, bank: bank, stub: stub))
        bank.showsChallenge = false
        note(try await replay(signIn, bank: bank, stub: CodeStub(authenticator: nil)))
        let signedOut = try await enroll(bank, kind: .none, stub: stub)
        signedOut.browser.close()
        note(signedOut.assisted)

        let refused = browser(bank)
        defer { refused.close() }
        do {
            _ = try await refused.open(URL(string: "https://evil.test/")!)
        } catch {
            note(error)
        }
        // A page that sends the browser off the site, and a start page that cannot be loaded
        // after a sign-in, both of which are logged.
        bank.site.route("/jump", page: TestPages.redirect(to: "https://evil.test/landing"))
        do {
            _ = try await refused.open(URL(string: "https://example.com/jump")!)
        } catch {
            note(error)
        }
        final class Counter { var value = 0 }
        let startRequests = Counter()
        bank.site.route("/account") { _ in
            startRequests.value += 1
            return TestPages.redirect(to: startRequests.value == 1 ? "/login" : "/gone")
        }
        note(try await replay(signIn, bank: bank, stub: stub))
        do {
            let broker = SignInBroker(browser: refused)
            _ = try await broker.fill(origin: "https://example.com", path: "/login", allowedHosts: nil, requests: [
                SignInBroker.FillRequest(kind: .password, key: passwordField, value: bank.password),
            ])
        } catch {
            note(error)
        }

        // A request to type something renders as a placeholder whatever the value.
        let request = SignInBroker.FillRequest(kind: .password, key: passwordField, value: bank.password)
        note(request)
        note([request])
        var dumped = ""
        dump(request, to: &dumped)
        produced.append(dumped)

        for line in produced {
            #expect(!line.contains(bank.password))
            #expect(!line.contains(bank.code))
            #expect(!line.contains(CodeStub.sampleKey))
        }

        // Everything the code logged while it ran, with the log and its file left alone.
        let logged = capture.lines
        #expect(logged.contains { $0.contains("[sites]") })
        for line in logged {
            #expect(!line.contains(bank.password))
            #expect(!line.contains(bank.username))
            #expect(!line.contains(bank.code))
            #expect(!line.contains(CodeStub.sampleKey))
        }
    }

    @Test("A session that holds the typed secrets prints as a fixed placeholder however it is rendered")
    func sessionRedaction() {
        let bank = TestBank()
        let page = browser(bank)
        defer { page.close() }
        let session = AssistedSignInSession(
            broker: SignInBroker(browser: page),
            username: "alice-typed-name",
            password: "hunter2-typed",
            authenticatorKey: CodeStub.sampleKey,
            codeKind: .authenticator,
            codeSender: nil,
            codes: CodeStub().codes
        )
        var dumped = ""
        dump(session, to: &dumped)

        for rendering in [
            session.description, session.debugDescription, "\(session)", String(reflecting: session),
            String(describing: [session]), dumped,
        ] {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains("alice-typed-name"))
            #expect(!rendering.contains("hunter2"))
            #expect(!rendering.contains(CodeStub.sampleKey))
        }
    }

    @Test("A request to fill a field prints as a fixed placeholder however it is rendered")
    func fillRequestRedaction() {
        let request = SignInBroker.FillRequest(kind: .password, key: passwordField, value: "hunter2-secret")
        var dumped = ""
        dump(request, to: &dumped)

        for rendering in [
            request.description, request.debugDescription, "\(request)", String(describing: request),
            String(reflecting: request), String(describing: [request]), dumped,
        ] {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains("hunter2"))
            #expect(!rendering.contains("password"))
        }
    }
}

// MARK: - Pure rules

private func field(
    name: String = "",
    id: String = "",
    autocomplete: String = "",
    type: String = "",
    inputMode: String = "",
    maxLength: Int? = nil,
    form: Int? = nil,
    formHasSubmit: Bool = false
) -> ProbedField {
    ProbedField(
        key: FieldKey(name: name, id: id, autocomplete: autocomplete, type: type),
        inputMode: inputMode,
        maxLength: maxLength,
        form: form,
        formHasSubmit: formHasSubmit
    )
}

@Suite("Sign-in broker rules")
struct SignInBrokerRuleTests {
    private func page(
        _ fields: [ProbedField],
        origin: String = "https://example.com",
        path: String = "/login",
        signOut: Bool = false,
        loginFrame: Bool = false
    ) -> PageProbe {
        PageProbe(
            origin: origin,
            path: path,
            isSecureTopFrame: true,
            hasChallenge: false,
            fields: fields,
            hasSignOutControl: signOut,
            hasLoginFrame: loginFrame
        )
    }

    private func kinds(_ decision: SignInRules.Decision) -> [SignInStep.Kind]? {
        if case let .fill(picks) = decision { return picks.map(\.kind) }
        return nil
    }

    // MARK: Matching

    @Test("A step matches the one visible field on the recorded page that its key describes")
    func matching() {
        let recorded = step(.username, "/login", FieldKey(name: "user", id: "u", autocomplete: "username", type: "text"))
        let user = field(name: "user", id: "other", autocomplete: "email", type: "email")
        let pass = field(name: "password", type: "password")

        #expect(SignInRules.visibleField(for: recorded, on: page([user, pass])) == user)
        // Another path or origin is another page.
        #expect(SignInRules.visibleField(for: recorded, on: page([user], path: "/other")) == nil)
        #expect(SignInRules.visibleField(for: recorded, on: page([user], origin: "https://www.example.com")) == nil)
        // Two fields that match leave it undecided.
        #expect(SignInRules.visibleField(for: recorded, on: page([user, field(name: "user")])) == nil)
        #expect(SignInRules.visibleField(for: recorded, on: page([])) == nil)
    }

    @Test("A field matches by the recorded name, or the recorded id, or the recorded token with its type")
    func anyOfNameIDOrToken() {
        let recorded = step(.username, "/login", FieldKey(name: "user", id: "u", autocomplete: "username", type: "text"))
        func matches(_ candidate: ProbedField) -> Bool {
            SignInRules.visibleField(for: recorded, on: page([candidate])) != nil
        }

        #expect(matches(field(name: "user", id: "x", autocomplete: "off", type: "email")))
        #expect(matches(field(name: "login", id: "u", autocomplete: "off", type: "email")))
        #expect(matches(field(name: "login", id: "x", autocomplete: "username", type: "text")))
        // The token counts only with the recorded type.
        #expect(!matches(field(name: "login", id: "x", autocomplete: "username", type: "email")))
        #expect(!matches(field(name: "login", id: "x", autocomplete: "", type: "text")))
        #expect(!matches(field(name: "login", id: "x", autocomplete: "off", type: "text")))
        // What was not recorded matches nothing, an attribute-less field included.
        let blank = step(.username, "/login", FieldKey(name: "", id: "", autocomplete: "", type: ""))
        #expect(SignInRules.visibleField(for: blank, on: page([field()])) == nil)
        let named = step(.username, "/login", FieldKey(name: "user", id: "", autocomplete: "", type: ""))
        #expect(SignInRules.visibleField(for: named, on: page([field(id: "", autocomplete: "", type: "")])) == nil)
        #expect(SignInRules.visibleField(for: named, on: page([field(name: "user")])) != nil)
    }

    @Test("Each way of matching is held to the recorded value, not a likeness of it")
    func fallbackMatching() {
        let byID = step(.username, "/login", FieldKey(name: "", id: "email-box", autocomplete: "x", type: "text"))
        #expect(SignInRules.visibleField(for: byID, on: page([field(id: "email-box", type: "text")])) != nil)
        #expect(SignInRules.visibleField(for: byID, on: page([field(id: "email-box2")])) == nil)
        // A name on the page does not stand in for the recorded id.
        #expect(SignInRules.visibleField(for: byID, on: page([field(name: "email-box")])) == nil)

        let byToken = step(.username, "/login", FieldKey(name: "", id: "", autocomplete: "username", type: "text"))
        #expect(SignInRules.visibleField(for: byToken, on: page([field(name: "any", id: "any", autocomplete: "username", type: "text")])) != nil)
        #expect(SignInRules.visibleField(for: byToken, on: page([field(autocomplete: "username", type: "email")])) == nil)
        #expect(SignInRules.visibleField(for: byToken, on: page([field(autocomplete: "email", type: "text")])) == nil)
    }

    @Test("A password step takes only a password field, and the others never take one")
    func kindAndType() {
        let password = step(.password, "/login", FieldKey(name: "secret", id: "", autocomplete: "", type: "password"))
        #expect(SignInRules.visibleField(for: password, on: page([field(name: "secret", type: "text")])) == nil)
        #expect(SignInRules.visibleField(for: password, on: page([field(name: "secret", type: "password")])) != nil)

        let username = step(.username, "/login", FieldKey(name: "secret", id: "", autocomplete: "", type: "text"))
        #expect(SignInRules.visibleField(for: username, on: page([field(name: "secret", type: "password")])) == nil)
        let code = step(.code, "/login", FieldKey(name: "secret", id: "", autocomplete: "", type: "text"))
        #expect(SignInRules.visibleField(for: code, on: page([field(name: "secret", type: "password")])) == nil)
    }

    @Test("A page that matches only some of its recorded steps is changed when it shows a field none of them accounts for")
    func alteredPages() {
        let username = step(.username, "/login", FieldKey(name: "user", id: "", autocomplete: "", type: "text"))
        let password = step(.password, "/login", FieldKey(name: "pass", id: "", autocomplete: "", type: "password"))
        let user = field(name: "user", type: "text")
        let pass = field(name: "pass", type: "password")
        let renamed = field(name: "login_id", type: "text")

        // The password is found but the username field has another name.
        #expect(SignInRules.isAlteredPage(recordedHere: [username, password], matched: [pass], on: page([renamed, pass])))
        // The username is found but the password field has another name.
        #expect(SignInRules.isAlteredPage(recordedHere: [username, password], matched: [user], on: page([user, field(name: "passwd", type: "password")])))
        // A search box beside the username field is a field no step accounts for.
        #expect(SignInRules.isAlteredPage(recordedHere: [username, password], matched: [user], on: page([field(name: "q"), user])))
        // The page after the username, at the same address, shows only the password field.
        #expect(!SignInRules.isAlteredPage(recordedHere: [username, password], matched: [pass], on: page([pass])))
        // Every recorded step matched, or none did.
        #expect(!SignInRules.isAlteredPage(recordedHere: [username, password], matched: [user, pass], on: page([user, pass, field(name: "q")])))
        #expect(!SignInRules.isAlteredPage(recordedHere: [username, password], matched: [], on: page([renamed])))
    }

    @Test(
        "A code is four to eight ASCII digits and nothing else",
        arguments: [
            ("1234", true), ("482910", true), ("12345678", true), ("123", false),
            ("123456789", false), ("12 34 56", false), ("482910\n", false), (" 482910", false),
            ("12ab56", false), ("", false), ("٤٨٢٩١٠", false), ("１２３４５６", false),
        ]
    )
    func validCodes(_ code: String, _ valid: Bool) {
        #expect((SignInRules.validCode(code) != nil) == valid)
    }

    // MARK: What to fill

    @Test("A password page is filled with the username beside it, or the password alone once the username is filled")
    func passwordPage() {
        let user = field(name: "username", type: "text")
        let pass = field(name: "password", type: "password")

        #expect(kinds(SignInRules.decide(page: page([user, pass]), used: [], codeKind: .none)) == [.username, .password])
        #expect(kinds(SignInRules.decide(page: page([pass]), used: [], codeKind: .none)) == [.password])
        #expect(kinds(SignInRules.decide(page: page([user, pass]), used: [.username], codeKind: .none)) == [.password])
        #expect(SignInRules.decide(page: page([user, pass]), used: [.username, .password], codeKind: .none) == .stop(.stillSignedOut))
        // The password field wins over a field that looks like a code.
        let otp = field(name: "otp", autocomplete: "one-time-code")
        #expect(kinds(SignInRules.decide(page: page([otp, pass]), used: [], codeKind: .text)) == [.password])
    }

    @Test("A page without a password field asks for a code, a username, or nothing")
    func pageWithoutPassword() {
        let otp = field(name: "otp", autocomplete: "one-time-code", type: "text")
        #expect(kinds(SignInRules.decide(page: page([otp]), used: [.username, .password], codeKind: .authenticator)) == [.code])
        #expect(SignInRules.decide(page: page([otp]), used: [.username, .password], codeKind: .none) == .stop(.noCode))
        #expect(SignInRules.decide(page: page([otp]), used: [.code], codeKind: .authenticator) == .stop(.stillSignedOut))

        let user = field(name: "email", type: "email")
        #expect(kinds(SignInRules.decide(page: page([user]), used: [], codeKind: .none)) == [.username])
        #expect(SignInRules.decide(page: page([user]), used: [.username], codeKind: .none) == .stop(.stillSignedOut))
        #expect(SignInRules.decide(page: page([]), used: [], codeKind: .none) == .stop(nil))
    }

    @Test(
        "A field is a code field by its autocomplete token, its name or id, or its numeric hints",
        arguments: [
            field(autocomplete: "one-time-code"),
            field(name: "otp"), field(name: "code"), field(name: "token"), field(name: "pin"),
            field(name: "passcode"), field(name: "totp"), field(name: "mfa"), field(name: "2fa"),
            field(name: "verification"), field(name: "verify"),
            field(name: "verification_code"), field(id: "mfa-input"), field(name: "2fa_token"),
            field(name: "PIN"), field(id: "securityCode"), field(name: "verifyBox"),
            field(name: "smsCode"), field(id: "verificationCode"), field(name: "x", id: "otp"),
            field(inputMode: "numeric", maxLength: 6), field(inputMode: "numeric", maxLength: 4),
            field(inputMode: "numeric", maxLength: 8),
        ]
    )
    func codeFields(_ code: ProbedField) {
        #expect(SignInRules.isCodeField(code))
        #expect(kinds(SignInRules.decide(page: page([code]), used: [.username, .password], codeKind: .text)) == [.code])
    }

    @Test(
        "A field is not a code field when it has other hints, or a word that makes it another kind of code",
        arguments: [
            field(inputMode: "numeric", maxLength: 3), field(inputMode: "numeric", maxLength: 9),
            field(inputMode: "numeric"), field(inputMode: "text", maxLength: 6), field(name: "nickname"),
            field(name: "shipping"), field(name: "opinion"), field(name: "zipcode"),
            field(name: "promocode"), field(name: "verified"), field(name: "mapping"),
            field(name: "zip_code"), field(name: "zipCode"), field(name: "promo_code"),
            field(name: "postal-code"), field(name: "post_code"), field(name: "country_code"),
            field(name: "area-code"), field(name: "gift_code"), field(name: "coupon_code"),
            field(name: "discount_code"), field(name: "referral_code"), field(name: "invite_code"),
            field(name: "tracking_code"), field(name: "csrf_token"), field(name: "token", id: "csrf"),
            field(name: "zip", inputMode: "numeric", maxLength: 5),
            field(name: "pin", type: "password"),
        ]
    )
    func notCodeFields(_ other: ProbedField) {
        #expect(!SignInRules.isCodeField(other))
        let decision = SignInRules.decide(page: page([other]), used: [.username, .password], codeKind: .text)
        #expect(kinds(decision) != [.code])
    }

    @Test(
        "A field is a username field by its autocomplete token, its type, or its name or id",
        arguments: [
            field(autocomplete: "username", type: "text"), field(autocomplete: "email", type: "text"),
            field(type: "email"), field(name: "user_name"), field(id: "loginId"),
            field(name: "memberNumber", type: "tel"), field(id: "AccountNo"), field(name: "Email"),
        ]
    )
    func usernameFields(_ candidate: ProbedField) {
        let noise = field(name: "search", type: "text")
        #expect(kinds(SignInRules.decide(page: page([noise, candidate]), used: [], codeKind: .none)) == [.username])
        let decision = SignInRules.decide(page: page([noise, candidate]), used: [], codeKind: .none)
        if case let .fill(picks) = decision { #expect(picks.first?.field == candidate) }
    }

    @Test("With no hints, a lone text field is the username and two are not guessed between")
    func loneTextField() {
        #expect(kinds(SignInRules.decide(page: page([field(name: "q")]), used: [], codeKind: .none)) == [.username])
        #expect(SignInRules.decide(page: page([field(name: "q"), field(name: "r")]), used: [], codeKind: .none) == .stop(nil))
        // Fields that take no username are not text fields here.
        #expect(SignInRules.decide(page: page([field(name: "q", type: "search")]), used: [], codeKind: .none) == .stop(nil))
        #expect(SignInRules.decide(page: page([field(name: "n", type: "number")]), used: [], codeKind: .none) == .stop(nil))
    }

    @Test("The username goes in the password's own form, not a search box before it")
    func usernameInThePasswordsForm() {
        let search = field(name: "q", type: "text", form: 0, formHasSubmit: true)
        let plain = field(name: "field1", type: "text", form: 1, formHasSubmit: true)
        let pass = field(name: "pw", type: "password", form: 1, formHasSubmit: true)

        func username(_ fields: [ProbedField]) -> ProbedField? {
            guard case let .fill(picks) = SignInRules.decide(page: page(fields), used: [], codeKind: .none) else { return nil }
            return picks.first { $0.kind == .username }?.field
        }

        #expect(username([search, plain, pass]) == plain)
        // A hint in the password's form wins over an unhinted first field of that form.
        let hinted = field(name: "email", type: "email", form: 1, formHasSubmit: true)
        #expect(username([search, plain, hinted, pass]) == hinted)
        // A hinted field outside the password's form is used only when the form has none.
        let outside = field(name: "email", type: "email", form: 2, formHasSubmit: true)
        #expect(username([search, outside, plain, pass]) == plain)
        #expect(username([outside, pass]) == outside)
        // A field that asks for a code is not a username.
        let code = field(name: "otp", type: "text", form: 1, formHasSubmit: true)
        #expect(username([code, plain, pass]) == plain)
        #expect(username([code, pass]) == nil)
    }

    @Test("With no password field the username is in a form that can be submitted, when that is clear")
    func usernameInASubmittableForm() {
        func decision(_ fields: [ProbedField]) -> SignInRules.Decision {
            SignInRules.decide(page: page(fields), used: [], codeKind: .none)
        }
        let search = field(name: "q", type: "text", form: 0, formHasSubmit: true)
        let plain = field(name: "field1", type: "text", form: 1, formHasSubmit: true)
        let hinted = field(name: "email", type: "email", form: 1, formHasSubmit: true)
        let loose = field(name: "field2", type: "text")
        let unsubmittable = field(name: "field3", type: "text", form: 2, formHasSubmit: false)

        // One candidate in a submittable form.
        #expect(decision([plain]) == .fill([SignInRules.Pick(kind: .username, field: plain)]))
        // A hint decides between two.
        #expect(decision([search, hinted]) == .fill([SignInRules.Pick(kind: .username, field: hinted)]))
        // Two unhinted fields in submittable forms are not guessed between.
        #expect(decision([search, plain]) == .stop(nil))
        // A lone field in no form, or in a form with no submit control, is the username by the
        // lone-field rule.
        #expect(decision([loose]) == .fill([SignInRules.Pick(kind: .username, field: loose)]))
        #expect(decision([unsubmittable]) == .fill([SignInRules.Pick(kind: .username, field: unsubmittable)]))
        // A submittable form is preferred to a loose field.
        #expect(decision([loose, plain]) == .fill([SignInRules.Pick(kind: .username, field: plain)]))
        // A field that asks for a code is not a username; it is the code.
        let code = field(name: "otp", type: "text", form: 3, formHasSubmit: true)
        #expect(
            SignInRules.decide(page: page([code, plain]), used: [], codeKind: .text)
                == .fill([SignInRules.Pick(kind: .code, field: code)])
        )
    }

    // MARK: Signed in

    private func grant(
        start: String = "https://example.com/account",
        steps: [SignInStep] = [],
        signOutSeen: Bool = false
    ) -> SiteGrant {
        SiteGrant(
            username: "u",
            password: "p",
            authenticatorKey: nil,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: start)!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com", "www.example.com"],
            codeKind: .none,
            codeSender: nil,
            signInSteps: steps,
            signOutControlSeen: signOutSeen
        )
    }

    @Test("A page is signed in only when each clause of the rule holds")
    func signedInTable() {
        let recorded = [step(.username, "/login", usernameField), step(.password, "/login", passwordField)]
        let search = field(name: "q", type: "text")
        let plain = grant(steps: recorded)
        let strict = grant(steps: recorded, signOutSeen: true)
        func signedIn(
            _ fields: [ProbedField] = [],
            path: String = "/account",
            origin: String = "https://example.com",
            signOut: Bool = false,
            loginFrame: Bool = false,
            secure: Bool = true,
            challenge: Bool = false,
            grant: SiteGrant
        ) -> Bool {
            let probe = PageProbe(
                origin: origin,
                path: path,
                isSecureTopFrame: secure,
                hasChallenge: challenge,
                fields: fields,
                hasSignOutControl: signOut,
                hasLoginFrame: loginFrame
            )
            return SignInRules.isSignedIn(page: probe, grant: grant)
        }

        // Every clause holds.
        #expect(signedIn([search], signOut: true, grant: strict))
        #expect(signedIn(grant: plain))
        // A public start page with no sign-out control, when one was seen at enrollment.
        #expect(!signedIn(grant: strict))
        #expect(signedIn(grant: plain))
        // A redirect to the login page, another path.
        #expect(!signedIn(path: "/login", signOut: true, grant: strict))
        #expect(!signedIn(path: "/login", grant: plain))
        // Another origin at the start path.
        #expect(!signedIn(origin: "https://www.example.com", signOut: true, grant: strict))
        // A password field, a code field, a recorded step's field, a sign-in frame.
        #expect(!signedIn([field(name: "pw", type: "password")], signOut: true, grant: strict))
        #expect(!signedIn([field(autocomplete: "one-time-code")], signOut: true, grant: strict))
        #expect(!signedIn([field(name: "verification_code")], signOut: true, grant: strict))
        #expect(!signedIn([field(inputMode: "numeric", maxLength: 6)], signOut: true, grant: strict))
        let user = step(.username, "/account", usernameField)
        #expect(!signedIn([field(name: "username", id: "user", autocomplete: "username", type: "text")], signOut: true, grant: grant(steps: [user], signOutSeen: true)))
        #expect(!signedIn(signOut: true, loginFrame: true, grant: strict))
        // A challenge to answer.
        #expect(!signedIn(signOut: true, challenge: true, grant: strict))
        // A page that is not a secure top frame.
        #expect(!signedIn(signOut: true, secure: false, grant: strict))
    }

    @Test("The start page's path is the same when its encodings are, and a bare host is the root")
    func startPagePaths() {
        func isStart(_ path: String, _ start: String, origin: String = "https://example.com") -> Bool {
            SignInRules.isStartPage(
                PageProbe(origin: origin, path: path, isSecureTopFrame: true, hasChallenge: false, fields: []),
                URL(string: start)!
            )
        }

        #expect(isStart("/account", "https://example.com/account"))
        #expect(isStart("/", "https://example.com"))
        #expect(isStart("/", "https://example.com/"))
        #expect(isStart("/my%20account", "https://example.com/my account"))
        #expect(isStart("/my account", "https://example.com/my%20account"))
        #expect(isStart("/account", "https://EXAMPLE.com/account"))
        #expect(!isStart("/account/", "https://example.com/account"))
        #expect(!isStart("/Account", "https://example.com/account"))
        #expect(!isStart("/account", "https://example.com/account", origin: "https://www.example.com"))
        #expect(!isStart("/account", "https://example.com/other"))
    }

    @Test("A failed sign-in counts against the site by what it says about it")
    func attemptOutcomes() {
        #expect(SignInOutcome.signedIn.attemptOutcome == .succeeded)
        #expect(SignInOutcome.interrupted.attemptOutcome == nil)
        for reason in [SignInOutcome.Reason.challenge, .unrecognisedPage, .stillSignedOut, .noRecordedSteps, .tooManySteps] {
            #expect(SignInOutcome.needsPerson(reason).attemptOutcome == .needsPerson, "\(reason)")
        }
        for reason in [SignInOutcome.Reason.noCode, .pageMoved, .loadFailed] {
            #expect(SignInOutcome.needsPerson(reason).attemptOutcome == .transientFailure, "\(reason)")
        }
    }

    // MARK: The probe's result

    private func probeValue(_ overrides: [String: ScriptValue] = [:], inputs: [ScriptValue]? = nil) -> ScriptValue {
        var object: [String: ScriptValue] = [
            "origin": .string("https://example.com"),
            "path": .string("/login"),
            "secure": .bool(true),
            "top": .bool(true),
            "challenge": .bool(false),
            "signOut": .bool(false),
            "loginFrame": .bool(false),
            "inputs": .array(inputs ?? []),
        ]
        for (key, value) in overrides { object[key] = value }
        return .object(object)
    }

    private func inputValue(
        name: String = "n",
        maxlength: ScriptValue = .number(-1)
    ) -> ScriptValue {
        .object([
            "name": .string(name), "id": .string(""), "autocomplete": .string(""),
            "type": .string("text"), "inputmode": .string(""), "maxlength": maxlength,
            "form": .number(-1), "formSubmit": .bool(false),
        ])
    }

    @Test("The probe's result is read when it has the shape the script returns, and refused otherwise")
    func probeParsing() {
        #expect(PageProbe(probeValue(inputs: [inputValue()]))?.fields.count == 1)
        #expect(PageProbe(probeValue(["secure": .bool(false)]))?.isSecureTopFrame == false)
        #expect(PageProbe(probeValue(["top": .bool(false)]))?.isSecureTopFrame == false)
        #expect(PageProbe(probeValue(["challenge": .bool(true)]))?.hasChallenge == true)
        #expect(PageProbe(probeValue(["signOut": .bool(true)]))?.hasSignOutControl == true)
        #expect(PageProbe(probeValue(["loginFrame": .bool(true)]))?.hasLoginFrame == true)
        #expect(PageProbe(probeValue(inputs: [inputValue()]))?.fields.first?.form == nil)

        #expect(PageProbe(.null) == nil)
        #expect(PageProbe(.string("x")) == nil)
        #expect(PageProbe(probeValue(["origin": .number(1)])) == nil)
        #expect(PageProbe(probeValue(["secure": .string("true")])) == nil)
        #expect(PageProbe(probeValue(["signOut": .string("true")])) == nil)
        #expect(PageProbe(probeValue(["loginFrame": .null])) == nil)
        #expect(PageProbe(probeValue(["secure": .number(1)])) == nil)
        #expect(PageProbe(probeValue(["inputs": .string("none")])) == nil)
        #expect(PageProbe(probeValue(inputs: [.object(["name": .string("x")])])) == nil)
        #expect(PageProbe(probeValue(inputs: [inputValue(name: "ok"), .null])) == nil)
    }

    @Test("A probe result is bounded: forty inputs, attribute text cut, odd lengths dropped")
    func probeBounds() throws {
        let many = (0..<100).map { _ in inputValue() }
        #expect(PageProbe(probeValue(inputs: many))?.fields.count == 40)

        let long = String(repeating: "n", count: 5_000)
        let cut = try #require(PageProbe(probeValue(inputs: [inputValue(name: long)])))
        #expect(cut.fields[0].key.name.count == 200)

        let negative = try #require(PageProbe(probeValue(inputs: [inputValue(maxlength: .number(-1))])))
        #expect(negative.fields[0].maxLength == nil)
        let fractional = try #require(PageProbe(probeValue(inputs: [inputValue(maxlength: .number(6.5))])))
        #expect(fractional.fields[0].maxLength == nil)
        let sized = try #require(PageProbe(probeValue(inputs: [inputValue(maxlength: .number(6))])))
        #expect(sized.fields[0].maxLength == 6)
    }
}
