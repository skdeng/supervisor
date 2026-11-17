import Foundation
import Testing
import WebKit

@testable import SuperVisor

/// The sign-in window for a site with a saved password, on the simulated bank: the app fills the
/// saved password while the person watches, and Done saves the refreshed grant, offers the
/// password the person typed in place of the saved one, or records the person's sign-in with
/// the stored grant kept.
///
/// A trusted input event cannot be made from a test, so a test places the values in the page
/// with a script and reports them to the browser as the credential script would
/// (`SiteBrowser.noteCredential`), as `PasswordKeepingTests` does.
@Suite("Signing in to a site with a saved password", .serialized)
@MainActor
struct SavedPasswordSignInTests {
    private let added = Date(timeIntervalSince1970: 1_700_000_000)
    private let loginURL = URL(string: "https://example.com/login")!

    private struct Flow {
        let fixture: SiteCenterFixture
        let center: SiteAccessCenter
        let bank: TestBank
        let enrollment: SiteEnrollment
        let holds: FollowUpHoldsStub
        let codes: CodeStub
        /// The grant stored for the site before the window opened.
        let stored: SiteGrant
    }

    /// Builds the grant a flow stores, from the bank and the password it is to hold.
    private struct MakeGrant {
        let make: (TestBank, String) -> SiteGrant
    }

    private enum StoredPassword {
        /// The bank's own password, which signs in.
        case current
        /// A password the bank no longer takes.
        case changed
    }

    private func field(_ name: String, _ id: String, _ autocomplete: String, _ type: String) -> FieldKey {
        FieldKey(name: name, id: id, autocomplete: autocomplete, type: type)
    }

    private var usernameField: FieldKey { field("username", "user", "username", "text") }
    private var passwordField: FieldKey { field("password", "pass", "current-password", "password") }

    /// A grant that signs in to the bank by itself, as one kept from an earlier sign-in would.
    private func passwordGrant(
        _ bank: TestBank,
        password: String,
        username: String? = nil,
        authenticatorKey: String? = nil,
        codeKind: SiteGrant.CodeKind = .none,
        codeSender: String? = nil
    ) -> SiteGrant {
        let user = username ?? bank.username
        let passwordPath = bank.flow == .twoStep ? "/password" : "/login"
        var steps: [SignInStep] = []
        if !user.isEmpty {
            steps.append(SignInStep(kind: .username, origin: "https://example.com", path: "/login", field: usernameField))
        }
        steps.append(SignInStep(kind: .password, origin: "https://example.com", path: passwordPath, field: passwordField))
        if codeKind != .none {
            steps.append(SignInStep(
                kind: .code,
                origin: "https://example.com",
                path: "/verify",
                field: field("otp", "otp", "one-time-code", "text")
            ))
        }
        return SiteGrant(
            username: user,
            password: password,
            authenticatorKey: authenticatorKey,
            signInURL: loginURL,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: codeKind,
            codeSender: codeSender,
            signInSteps: steps,
            signOutControlSeen: true
        )
    }

    /// A center that reads the bank with a password grant stored for it, the site flagged as
    /// needing the person and awaited, and an enrollment for the sign-in window on the bank that
    /// records what is typed unless `recording` is false. `rejected` marks the saved password
    /// as turned away.
    private func flow(
        stored kind: StoredPassword = .current,
        recording: Bool = true,
        rejected: Bool = false,
        seesVisitors: Bool = false,
        codes: CodeStub = CodeStub(),
        grant makeGrant: MakeGrant? = nil,
        _ configure: (TestBank) -> Void = { _ in }
    ) async throws -> Flow {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        configure(bank)
        let center = fixture.center(simulatedPages: bank.site.answer, settling: .fast)
        let password = kind == .current ? bank.password : "Old-" + UUID().uuidString
        let stored = makeGrant?.make(bank, password) ?? passwordGrant(bank, password: password)
        try center.save(grant: stored, record: SiteRecord(id: "example.com", name: "My Bank", added: added))
        var flagged = try #require(center.access.sites().first)
        flagged.needsPerson = true
        flagged.passwordRejected = rejected
        try SiteRegistry.save([flagged], to: fixture.registry)
        // A run turned away from the flagged site leaves it awaited.
        let turnedAway = await center.access.open(siteID: "example.com", visit: "turned-away")
        center.access.end(visit: "turned-away")
        guard case .failure(.needsPerson) = turnedAway else {
            Issue.record("the flagged site was not turned away: \(turnedAway)")
            throw CancellationError()
        }
        #expect(center.awaitingSignIn == ["example.com"])

        let visitorPages = seesVisitors ? bank.visitorPages : nil
        let enrollment = recording
            ? SiteEnrollment.recordingCredentials(
                dataStore: .nonPersistent(),
                codes: codes.codes,
                simulatedPages: bank.site.answer,
                settling: .fast,
                visitorPages: visitorPages,
                visitorRecheckDelay: .milliseconds(50)
            )
            : SiteEnrollment.watchingSignIn(
                dataStore: .nonPersistent(),
                codes: codes.codes,
                simulatedPages: bank.site.answer,
                settling: .fast,
                visitorPages: visitorPages,
                visitorRecheckDelay: .milliseconds(50)
            )
        return Flow(
            fixture: fixture,
            center: center,
            bank: bank,
            enrollment: enrollment,
            holds: FollowUpHoldsStub(),
            codes: codes,
            stored: stored
        )
    }

    private func model(
        _ flow: Flow,
        offersPasswords: Bool = true,
        offerTimeout: Duration = SiteSignInModel.standardOfferTimeout
    ) throws -> SiteSignInModel {
        let record = try #require(flow.center.sites.first)
        return SiteSignInModel(
            host: "example.com",
            record: record,
            start: .decide(host: "example.com", record: record, grant: flow.center.storedGrant(for: "example.com")) { _ in
                Issue.record("a granted site never reads the history")
                return false
            },
            proposalID: nil,
            needsPerson: true,
            offersPasswords: offersPasswords,
            followUps: flow.holds,
            offerTimeout: offerTimeout
        )
    }

    private func username(_ value: String, path: String = "/login", host: String = "example.com") throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "username", "value": value, "name": "username", "id": "user", "autocomplete": "username",
            "type": "text", "origin": "https://\(host)", "path": path, "actionHost": host,
        ], host: host))
    }

    private func password(
        _ value: String,
        path: String = "/login",
        host: String = "example.com",
        newPassword: Bool = false
    ) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "password", "value": value, "name": "password", "id": "pass",
            "autocomplete": "current-password", "type": "password", "origin": "https://\(host)", "path": path,
            "actionHost": host, "newPassword": newPassword,
        ], host: host))
    }

    /// Puts each value in the field with its id, reports the credentials, and submits the first
    /// form, then waits for the browser to reach `arrival`. A reported password is also reported
    /// as typing into a password field, as a person's typing is.
    private func type(
        _ values: [String: String],
        reporting credentials: [TypedCredential],
        in flow: Flow,
        arrivingAt arrival: String
    ) async throws {
        _ = try await flow.enrollment.browser.run("""
            for (const [id, value] of Object.entries(values)) document.getElementById(id).value = value;
            """, arguments: ["values": values])
        for credential in credentials {
            if credential.kind == .password { flow.enrollment.browser.noteTyped(into: .password) }
            flow.enrollment.browser.noteCredential(credential)
        }
        _ = try await flow.enrollment.browser.run("HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);")
        try await waitFor { flow.enrollment.browser.currentURL?.path == arrival && !flow.enrollment.browser.webView.isLoading }
        await flow.enrollment.idle()
    }

    /// The window opens, the app fills the saved user name and password, which the bank
    /// refuses, and the person signs in on the page with the bank's own password, reporting
    /// what they typed unless `reports` is false. With `retypesUsername` false only the
    /// password is typed, into a form that shows the user name already.
    private func signInByHandAfterRefusal(
        _ flow: Flow,
        model: SiteSignInModel,
        reports: Bool = true,
        retypesUsername: Bool = true,
        arrivingAt arrival: String = "/home"
    ) async throws {
        await model.beginIfTrusted(using: flow.enrollment)
        #expect(flow.bank.site.posts.filter { $0.path == "/session" }.count == 1)
        #expect(!flow.bank.signedIn)
        let path = try #require(flow.enrollment.browser.currentURL?.path)
        var values = ["pass": flow.bank.password]
        var credentials = [try password(flow.bank.password, path: path)]
        if retypesUsername {
            values["user"] = flow.bank.username
            credentials.insert(try username(flow.bank.username, path: path), at: 0)
        }
        try await type(values, reporting: reports ? credentials : [], in: flow, arrivingAt: arrival)
    }

    /// The bank signs out, and a run's open signs in by itself with one POST to `/session` that
    /// carries the saved user name and `password`.
    private func expectSignsInByItself(_ flow: Flow, with password: String) async throws {
        flow.bank.signOut()
        flow.bank.site.forgetRequests()
        defer { flow.center.access.end(visit: "run") }

        let opened = await flow.center.access.open(siteID: "example.com", visit: "run")

        guard case let .success(page) = opened else {
            Issue.record("the site was not opened: \(opened)")
            return
        }
        #expect(page.title == "Account")
        let posts = flow.bank.site.posts.filter { $0.path == "/session" }
        #expect(posts.count == 1)
        #expect(posts.first?.fields["username"] == flow.bank.username)
        #expect(posts.first?.fields["password"] == password)
    }

    /// The bytes of every item in the secret store.
    private func storedBytes(_ flow: Flow) throws -> [String: Data] {
        var items: [String: Data] = [:]
        for account in flow.fixture.store.accounts {
            items[account] = try flow.fixture.store.read(account: account)
        }
        return items
    }

    /// `stored` with its password replaced and nothing else.
    private func expectReplacement(_ grant: SiteGrant?, of stored: SiteGrant, password: String) {
        guard let grant else {
            Issue.record("no grant is stored")
            return
        }
        #expect(grant.password == password)
        #expect(grant.username == stored.username)
        #expect(grant.signInSteps == stored.signInSteps)
        #expect(grant.fillHosts == stored.fillHosts)
        #expect(grant.browseHosts == stored.browseHosts)
        #expect(grant.signInURL == stored.signInURL)
        #expect(grant.startURL == stored.startURL)
        #expect(grant.codeKind == stored.codeKind)
        #expect(grant.codeSender == stored.codeSender)
        #expect(grant.authenticatorKey == stored.authenticatorKey)
        #expect(grant.signOutControlSeen == stored.signOutControlSeen)
        #expect(grant.signInControlAbsent == stored.signInControlAbsent)
        #expect(grant.remembersPassword)
    }

    /// Moves the bank's sign-in to `login.example.com`: `/login` sends the browser there, its
    /// form signs in with the bank's password, and a correct one leads to `landing` on
    /// `example.com`, through a code page when `asksForCode`.
    private func moveSignIn(_ bank: TestBank, landing: String = "/home", asksForCode: Bool = false) {
        let form = TestPages.page("Sign in", """
            <h1>Sign in</h1>
            <form method="post" action="/session">
            <input type="text" id="user" name="username" autocomplete="username" value="\(bank.username)">
            <input type="password" id="pass" name="password" autocomplete="current-password">
            <button type="submit">Sign in</button></form>
            """)
        bank.site.route("/login", page: TestPages.redirect(to: "https://login.example.com/signin"))
        bank.site.route("/signin", host: "login.example.com", page: form)
        bank.site.route("/session", method: "POST", host: "login.example.com") { [unowned bank] request in
            guard request.fields["password"] == bank.password else { return form }
            if asksForCode { return TestPages.redirect(to: "/code") }
            bank.markSignedIn()
            return TestPages.redirect(to: "https://example.com\(landing)")
        }
        bank.site.route("/code", host: "login.example.com", page: TestPages.page("Verify", """
            <h1>Verify</h1>
            <form method="post" action="/code">
            <input type="text" id="otp" name="otp" autocomplete="one-time-code" inputmode="numeric" maxlength="6">
            <button type="submit">Verify</button></form>
            """))
        bank.site.route("/code", method: "POST", host: "login.example.com") { [unowned bank] _ in
            bank.markSignedIn()
            return TestPages.redirect(to: "https://example.com\(landing)")
        }
    }

    // MARK: Where the window starts

    @Test("A readable password grant fills its saved secrets, or withholds a turned-away password; a kept session opens its page; an unreadable one asks for the address")
    func startTable() async throws {
        let flow = try await flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        typealias Start = SiteSignInModel.Start
        typealias Window = ProVisorSiteWindow
        let record = try #require(flow.center.sites.first)
        var rejected = record
        rejected.passwordRejected = true
        let session = SiteGrant(
            username: "",
            password: "",
            authenticatorKey: nil,
            signInURL: loginURL,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil,
            remembersPassword: false
        )

        #expect(Start.decide(host: "example.com", record: record, grant: flow.stored) { _ in true }
            == .fillsSavedPassword(flow.stored))
        #expect(Start.decide(host: "example.com", record: rejected, grant: flow.stored) { _ in true }
            == .withholdsSavedPassword(flow.stored))
        #expect(Start.decide(host: "example.com", record: record, grant: session) { _ in true } == .opensPage(loginURL))
        #expect(Start.decide(host: "example.com", record: record, grant: nil) { _ in true }
            == .asksForAddress(host: "example.com"))

        for route in [Window.SignInRoute.signingIn(host: "example.com", requestedBy: nil),
                      Window.route(forSite: record, requestedBy: nil),
                      Window.route(forRequestedHost: "example.com", proposalID: "p", grantedSites: [record])] {
            #expect(Window.opening(for: route, record: record, grant: flow.stored) == .signIn(host: "example.com", requestedBy: route.requestedBy))
            #expect(Window.opening(for: route, record: record, grant: session) == .signIn(host: "example.com", requestedBy: route.requestedBy))
            #expect(Window.opening(for: route, record: record, grant: nil) == .unreadable(record: record, requestedBy: route.requestedBy))
        }
        let item = SignInDemand.Item(host: "example.com", displayName: "My Bank", kind: .signedOut(keepsSession: false), proposalID: nil)
        #expect(Window.route(for: item) == .signingIn(host: "example.com", requestedBy: nil))
        #expect(ProVisorSignInText.reason(item) == "SuperVisor couldn't sign in by itself")

        let model = try model(flow)
        #expect(model.title == "Sign in to My Bank")
        #expect(model.sentence == "My Bank needs you to sign in again. SuperVisor fills what it has saved; finish anything it can't.")
        #expect(model.recordsCredentials)
        #expect(!model.asksForAddress)
        #expect(!model.readsTextedCodes)
        #expect(String(describing: model.start).contains(flow.stored.password) == false)
    }

    @Test("Sign In Again's saved request carries each saved secret only to the hosts the grant fills on, or withholds the password")
    func savedRequest() {
        let base = TestBank()
        let plain = passwordGrant(base, password: "saved-password")
        let request = SiteFormModel.SignInRequest(saved: plain)
        #expect(request.address == "https://example.com/login")
        #expect(request.username == base.username)
        #expect(request.password == "saved-password")
        #expect(request.passwordHosts == ["example.com"])
        #expect(request.authenticatorKey == nil && request.authenticatorHosts == nil && request.codeSender == nil)
        let withheld = SiteFormModel.SignInRequest(savedWithholdingPassword: plain)
        #expect(withheld.password == nil)
        #expect(withheld.username == base.username)
        #expect(withheld.passwordHosts == ["example.com"])

        let authenticator = passwordGrant(
            base,
            password: "saved-password",
            authenticatorKey: CodeStub.sampleKey,
            codeKind: .authenticator
        )
        let keyed = SiteFormModel.SignInRequest(saved: authenticator)
        #expect(keyed.authenticatorKey == CodeStub.sampleKey)
        #expect(keyed.authenticatorHosts == ["example.com"])

        let texted = passwordGrant(base, password: "saved-password", codeKind: .text, codeSender: "24273")
        let text = SiteFormModel.SignInRequest(saved: texted)
        #expect(text.codeKind == .text)
        #expect(text.codeSender == "24273")
        #expect(text.authenticatorKey == nil && text.authenticatorHosts == nil)
        #expect(!String(describing: request).contains("saved-password"))
    }

    @Test("A site whose codes come by text explains why texts cannot be read, in the form's words")
    func textedCodesExplained() async throws {
        let flow = try await flow(grant: MakeGrant { bank, password in
            passwordGrant(bank, password: password, codeKind: .text, codeSender: "24273")
        })
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        #expect(model.readsTextedCodes)
        #expect(SiteTextsWarning.message(for: .off) == "Texts are off, so SuperVisor can't read the code.")
        #expect(SiteTextsWarning.message(for: .accessDenied) == "Full Disk Access is off, so texts can't be read.")
        #expect(SiteTextsWarning.message(for: .on) == nil)
        #expect(flow.center.textsStatus == .off)
    }

    // MARK: The saved sign-in works

    @Test("The app fills the saved password while the person watches, and Done stores the refreshed grant under the site's own name", .timeLimit(.minutes(1)))
    func savedSignInWorks() async throws {
        let flow = try await flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)

        await model.beginIfTrusted(using: flow.enrollment)
        try await waitFor { flow.bank.signedIn && flow.enrollment.browser.currentURL?.path == "/home" }
        await flow.enrollment.idle()
        // A run marks the password turned away while the window is open.
        var marked = try #require(flow.center.access.sites().first)
        marked.passwordRejected = true
        try SiteRegistry.save([marked], to: flow.fixture.registry)

        let posts = flow.bank.site.posts.filter { $0.path == "/session" }
        #expect(posts.count == 1)
        #expect(posts.first?.fields["username"] == flow.bank.username)
        #expect(posts.first?.fields["password"] == flow.bank.password)
        #expect(model.canPressDone)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
        #expect(model.panel == nil)
        #expect(flow.enrollment.passwordOffer == nil)
        #expect(flow.holds.taken == 0)
        let grant = try #require(flow.center.storedGrant(for: "example.com"))
        #expect(grant.remembersPassword)
        #expect(grant.password == flow.bank.password)
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        let site = try #require(flow.center.sites.first)
        #expect(site.name == "My Bank")
        #expect(site.added == added)
        #expect(!site.needsPerson)
        #expect(!site.passwordRejected)
        #expect(!site.keepsSessionOnly)
        #expect(flow.center.awaitingSignIn.isEmpty)
    }

    @Test("A challenge the person passes by hand, after which the app's fill completes, saves the refreshed grant", .timeLimit(.minutes(1)))
    func challengeThenSavedSignIn() async throws {
        let flow = try await flow {
            $0.flow = .twoStep
            $0.challengeBetweenSteps = true
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)

        await model.beginIfTrusted(using: flow.enrollment)
        #expect(flow.bank.site.posts.map(\.path) == ["/identify"])
        #expect(flow.enrollment.browser.currentURL?.path == "/challenge")
        #expect(model.canPressDone)

        // The person gets past the challenge, and the app fills the password page it leads to.
        _ = try await flow.enrollment.browser.open(URL(string: "https://example.com/password")!)
        await flow.enrollment.idle()
        #expect(flow.bank.site.posts.map(\.path) == ["/identify", "/session"])
        #expect(flow.bank.signedIn)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
        let grant = try #require(flow.center.storedGrant(for: "example.com"))
        #expect(grant.password == flow.bank.password)
        #expect(grant.signInSteps.map(\.path) == ["/login", "/password"])
        #expect(flow.center.sites.first?.name == "My Bank")
        #expect(flow.center.sites.first?.added == added)
    }

    @Test("Typing into the password field before the app fills it does not count: the filled password that worked is saved", .timeLimit(.minutes(1)))
    func typingBeforeTheFill() async throws {
        let flow = try await flow {
            $0.flow = .twoStep
            $0.challengeBetweenSteps = true
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        #expect(flow.enrollment.browser.currentURL?.path == "/challenge")

        // The person types into the password page's field before the app reaches it.
        flow.enrollment.browser.noteTyped(into: .password)
        flow.enrollment.browser.noteCredential(try password("typed-before-the-fill", path: "/password"))
        _ = try await flow.enrollment.browser.open(URL(string: "https://example.com/password")!)
        await flow.enrollment.idle()
        #expect(flow.bank.signedIn)
        #expect(flow.enrollment.passwordIsConfirmed)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
        #expect(model.panel == nil)
        #expect(flow.center.storedGrant(for: "example.com")?.password == flow.bank.password)
    }

    @Test("A saved grant with no user name fills the password alone, leaving the user name the site shows", .timeLimit(.minutes(1)))
    func savedGrantWithoutUsername() async throws {
        let flow = try await flow(grant: MakeGrant { bank, password in passwordGrant(bank, password: password, username: "") }) {
            $0.prefillsUsername = true
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)

        await model.beginIfTrusted(using: flow.enrollment)
        try await waitFor { flow.bank.signedIn && flow.enrollment.browser.currentURL?.path == "/home" }
        await flow.enrollment.idle()

        let posts = flow.bank.site.posts.filter { $0.path == "/session" }
        #expect(posts.count == 1)
        #expect(posts.first?.fields["username"] == flow.bank.username)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
        let grant = try #require(flow.center.storedGrant(for: "example.com"))
        #expect(grant.username.isEmpty)
        #expect(grant.signInSteps.map(\.kind) == [.password])
    }

    // MARK: The person types a new password

    @Test("A password retyped on the sign-in page replaces the saved one and nothing else, and the app then signs in with it", .timeLimit(.minutes(1)))
    func keepTypedPassword() async throws {
        let flow = try await flow(stored: .changed) { $0.prefillsUsername = true }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        try await signInByHandAfterRefusal(flow, model: model, retypesUsername: false)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(model.panel == .replacement(siteName: "My Bank", username: flow.bank.username, host: "example.com"))
        #expect(flow.holds.isHeld)
        #expect(flow.center.storedGrant(for: "example.com") == flow.stored)
        #expect(flow.center.sites.first?.needsPerson == true)

        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .kept)
        expectReplacement(flow.center.storedGrant(for: "example.com"), of: flow.stored, password: flow.bank.password)
        let site = try #require(flow.center.sites.first)
        #expect(site.name == "My Bank")
        #expect(site.added == added)
        #expect(!site.needsPerson)
        #expect(!site.keepsSessionOnly)
        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .notKept)

        try await expectSignsInByItself(flow, with: flow.bank.password)
    }

    @Test("A password retyped on an error page at another path replaces the saved one, whose steps stay those of the sign-in page", .timeLimit(.minutes(1)))
    func keepPasswordTypedOnAnErrorPage() async throws {
        let flow = try await flow(stored: .changed) {
            $0.prefillsUsername = true
            $0.rendersFailureInPlace = true
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        try await signInByHandAfterRefusal(flow, model: model, retypesUsername: false)
        #expect(flow.bank.site.posts.filter { $0.path == "/session" }.count == 2)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .kept)
        expectReplacement(flow.center.storedGrant(for: "example.com"), of: flow.stored, password: flow.bank.password)

        try await expectSignsInByItself(flow, with: flow.bank.password)
    }

    @Test("A grant with an authenticator key and a code step keeps both, and is offered although a code field was seen", .timeLimit(.minutes(1)))
    func replacementKeepsTheCodeStep() async throws {
        let flow = try await flow(stored: .changed, grant: MakeGrant { bank, password in
            passwordGrant(bank, password: password, authenticatorKey: CodeStub.sampleKey, codeKind: .authenticator)
        }) {
            $0.prefillsUsername = true
            $0.requiresCode = true
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        // The app fills the code page the person's password leads to.
        try await signInByHandAfterRefusal(flow, model: model, retypesUsername: false)
        #expect(flow.bank.site.posts.filter { $0.path == "/verify" }.count == 1)
        #expect(flow.bank.signedIn)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .kept)
        let grant = flow.center.storedGrant(for: "example.com")
        expectReplacement(grant, of: flow.stored, password: flow.bank.password)
        #expect(grant?.signInSteps.map(\.kind) == [.username, .password, .code])
    }

    @Test("A password typed on a host the grant does not fill on is kept as a sign-in recorded afresh, with the saved user name", .timeLimit(.minutes(1)))
    func movedSignInFallsBack() async throws {
        let flow = try await flow(stored: .changed) { moveSignIn($0) }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        // The saved user name is held to the saved password's hosts, and is the first fill refused.
        #expect(flow.enrollment.unvettedFill == AssistedSignInSession.UnvettedFill(host: "login.example.com", kind: .username))
        #expect(flow.bank.site.posts.isEmpty)
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password, path: "/signin", host: "login.example.com")],
            in: flow,
            arrivingAt: "/home"
        )
        #expect(flow.bank.signedIn)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(model.panel == .replacement(siteName: "My Bank", username: flow.bank.username, host: "login.example.com"))
        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .kept)
        let grant = try #require(flow.center.storedGrant(for: "example.com"))
        #expect(grant.password == flow.bank.password)
        #expect(grant.username == flow.bank.username)
        #expect(grant.signInSteps.map(\.kind) == [.password])
        #expect(grant.signInSteps.first?.origin == "https://login.example.com")
        #expect(grant.fillHosts == ["example.com", "login.example.com"])
    }

    @Test("A password typed on a host the grant does not fill on keeps every refusal of a sign-in recorded afresh", .timeLimit(.minutes(1)))
    func movedSignInKeepsItsRefusals() async throws {
        let flow = try await flow(stored: .changed) { moveSignIn($0, asksForCode: true) }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password, path: "/signin", host: "login.example.com")],
            in: flow,
            arrivingAt: "/code"
        )
        flow.enrollment.browser.noteTyped(into: .other)
        await flow.enrollment.idle()
        try await type(["otp": flow.bank.code], reporting: [], in: flow, arrivingAt: "/home")
        let before = try storedBytes(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)
        #expect(model.panel == .savedPasswordTurnedAway(.codeAsked))
        #expect(try storedBytes(flow) == before)
    }

    @Test("A typed password whose page a visitor sees the same way is not dropped: Done says why, and Save Anyway offers it", .timeLimit(.minutes(1)))
    func movedSignInOnAPublicPage() async throws {
        let flow = try await flow(stored: .changed, seesVisitors: true) { bank in
            moveSignIn(bank, landing: "/welcome")
            bank.routeForEveryone("/welcome", page: TestPages.page("Welcome", "<p>Welcome to the bank</p>"))
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password, path: "/signin", host: "login.example.com")],
            in: flow,
            arrivingAt: "/welcome"
        )
        let before = try storedBytes(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .notSaved)
        #expect(model.problem == .pageLooksPublic)
        #expect(model.panel == nil)
        #expect(model.offersSaveAnyway)
        #expect(try storedBytes(flow) == before)
        #expect(flow.center.sites.first?.needsPerson == true)

        #expect(await model.done(using: flow.enrollment, into: flow.center, confirmingSignIn: true) == .asking)
        #expect(model.panel == .replacement(siteName: "My Bank", username: flow.bank.username, host: "login.example.com"))
    }

    @Test("Leave As Is keeps the saved password exactly as stored and records the sign-in with the password marked turned away", .timeLimit(.minutes(1)))
    func leaveAsIs() async throws {
        let flow = try await flow(stored: .changed)
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        try await signInByHandAfterRefusal(flow, model: model)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        let before = try storedBytes(flow)

        #expect(await model.leaveAsIs(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)

        #expect(model.panel == .savedPasswordTurnedAway(nil))
        #expect(try storedBytes(flow) == before)
        #expect(!flow.holds.isHeld)
        #expect(flow.enrollment.passwordOffer == nil)
        let site = try #require(flow.center.sites.first)
        #expect(!site.needsPerson)
        #expect(site.passwordRejected)
        #expect(site.name == "My Bank")
        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .notKept)
    }

    // MARK: Signed in by a route the capture cannot keep

    @Test("A typed password from a form for a new password is not kept; the stored grant is untouched and the sign-in recorded", .timeLimit(.minutes(1)))
    func refusedTypingKeepsTheSavedPassword() async throws {
        let flow = try await flow(stored: .changed) { $0.prefillsUsername = true }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password, newPassword: true)],
            in: flow,
            arrivingAt: "/home"
        )
        let before = try storedBytes(flow)
        let lastSignedIn = flow.center.sites.first?.lastSignedIn
        var saves: [(SiteRecord, Bool)] = []
        flow.center.onSiteSaved = { saves.append(($0, $1)) }

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)

        #expect(model.panel == .savedPasswordTurnedAway(.newPasswordForm))
        #expect(OfferRefusal.newPasswordForm.sentenceBesideSavedPassword?.contains("session") == false)
        #expect(flow.holds.taken == 0)
        #expect(try storedBytes(flow) == before)
        let site = try #require(flow.center.sites.first)
        #expect(!site.needsPerson)
        #expect(site.passwordRejected)
        #expect(site.lastSignedIn != nil && site.lastSignedIn != lastSignedIn)
        #expect(site.attemptCount == 0)
        #expect(flow.center.awaitingSignIn.isEmpty)
        #expect(saves.map(\.0.id) == ["example.com"])
        #expect(saves.map(\.1) == [true])

        flow.bank.site.forgetRequests()
        defer { flow.center.access.end(visit: "run") }
        let opened = await flow.center.access.open(siteID: "example.com", visit: "run")
        #expect((try? opened.get())?.title == "Account")
        #expect(flow.bank.site.posts.isEmpty)
    }

    @Test("A sign-in with nothing typed records the sign-in and shows no refusal", .timeLimit(.minutes(1)))
    func nothingTypedKeepsTheSavedPassword() async throws {
        let flow = try await flow(stored: .changed)
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        try await signInByHandAfterRefusal(flow, model: model, reports: false)
        let before = try storedBytes(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)

        #expect(model.panel == .savedPasswordTurnedAway(nil))
        #expect(try storedBytes(flow) == before)
        #expect(flow.center.sites.first?.needsPerson == false)
        #expect(flow.center.sites.first?.passwordRejected == true)
        #expect(flow.holds.taken == 0)
        #expect(!model.canPressDone)
    }

    @Test("A saved password the site accepted, followed by typing in a password field, is recorded as good", .timeLimit(.minutes(1)))
    func acceptedFillThenTyping() async throws {
        let flow = try await flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await waitFor { flow.bank.signedIn && flow.enrollment.browser.currentURL?.path == "/home" }
        await flow.enrollment.idle()
        flow.enrollment.browser.noteTyped(into: .password)
        #expect(!flow.enrollment.passwordIsConfirmed)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)
        #expect(model.panel == .savedPasswordKept(nil))
        #expect(flow.center.sites.first?.passwordRejected == false)
    }

    @Test("With the setting off nothing is recorded, the page is still probed, and a failed sign-in ends with the saved password kept and no offer", .timeLimit(.minutes(1)))
    func settingOff() async throws {
        let flow = try await flow(stored: .changed, recording: false)
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        flow.fixture.settings.provisorOffersPasswords = false
        #expect(!SiteSignInModel.recordsCredentials(start: .fillsSavedPassword(flow.stored), offersPasswords: false))
        #expect(SiteSignInModel.recordsCredentials(start: .fillsSavedPassword(flow.stored), offersPasswords: true))
        let model = try model(flow, offersPasswords: false)
        #expect(!model.recordsCredentials)
        let windowEnrollment = ProVisorSiteWindow.signInEnrollment(for: model, center: flow.center)
        #expect(!windowEnrollment.recordsCredentials)
        #expect(windowEnrollment.watchesAssistedSignIn)
        windowEnrollment.cancel()

        try await signInByHandAfterRefusal(flow, model: model)
        try await waitFor { flow.enrollment.appearsSignedIn }
        let before = try storedBytes(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)
        #expect(model.panel == .savedPasswordTurnedAway(nil))
        #expect(flow.enrollment.passwordOffer == nil)
        #expect(flow.holds.taken == 0)
        #expect(try storedBytes(flow) == before)
    }

    @Test("Done on a page that is not signed in records nothing and leaves Done open", .timeLimit(.minutes(1)))
    func notSignedInYet() async throws {
        let flow = try await flow(stored: .changed)
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        let before = try storedBytes(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .notSaved)
        #expect(model.problem == .notSignedIn)
        #expect(model.panel == nil)
        #expect(model.canPressDone)
        #expect(try storedBytes(flow) == before)
        #expect(flow.center.sites.first?.needsPerson == true)
    }

    // MARK: A password the site turned away

    @Test("An unattended sign-in the site turns away marks the saved password, and no attempt is made while it is marked", .timeLimit(.minutes(1)))
    func unattendedRejection() async throws {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        let center = fixture.center(simulatedPages: bank.site.answer, settling: .fast)
        try center.save(
            grant: passwordGrant(bank, password: "Old-" + UUID().uuidString),
            record: SiteRecord(id: "example.com", name: "My Bank", added: added)
        )
        defer { center.access.end(visit: "run") }

        let first = await center.access.open(siteID: "example.com", visit: "run")
        guard case .failure(.needsPerson) = first else {
            Issue.record("the refused sign-in was not answered as needing the person: \(first)")
            return
        }
        #expect(bank.site.posts.filter { $0.path == "/session" }.count == 1)
        var site = try #require(center.access.sites().first)
        #expect(site.passwordRejected)
        #expect(site.needsPerson)
        #expect(site.attemptCount == 1)

        // The person signs in on the site's own session only, leaving the password marked.
        site.needsPerson = false
        try SiteRegistry.save([site], to: fixture.registry)
        var needed: [String] = []
        center.onPersonNeeded = { needed.append($0) }
        bank.site.forgetRequests()

        let second = await center.access.open(siteID: "example.com", visit: "run")
        guard case .failure(.needsPerson) = second else {
            Issue.record("a site with a turned-away password was signed in to: \(second)")
            return
        }
        #expect(bank.site.posts.isEmpty)
        let after = try #require(center.access.sites().first)
        #expect(after.attemptCount == 1)
        #expect(after.needsPerson)
        #expect(after.passwordRejected)
        #expect(needed == ["example.com"])
    }

    @Test("The window for a turned-away password leaves the password field to the person, and keeping the typed one clears the mark", .timeLimit(.minutes(1)))
    func withheldPassword() async throws {
        let flow = try await flow(stored: .changed, rejected: true) { $0.flow = .twoStep }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        #expect(model.start == .withholdsSavedPassword(flow.stored))
        #expect(model.sentence == "My Bank didn't accept the saved password. Sign in on the page; SuperVisor can keep the password you type.")

        await model.beginIfTrusted(using: flow.enrollment)
        // The app fills the user name page, and leaves the password page alone.
        #expect(flow.bank.site.posts.map(\.path) == ["/identify"])
        #expect(flow.enrollment.browser.currentURL?.path == "/password")
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password, path: "/password")],
            in: flow,
            arrivingAt: "/home"
        )
        #expect(flow.bank.site.posts.map(\.path) == ["/identify", "/session"])

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .kept)
        expectReplacement(flow.center.storedGrant(for: "example.com"), of: flow.stored, password: flow.bank.password)
        #expect(flow.center.sites.first?.passwordRejected == false)
        #expect(flow.center.sites.first?.needsPerson == false)
    }

    @Test("A sign-in with the password withheld and nothing kept leaves the password marked", .timeLimit(.minutes(1)))
    func withheldPasswordStaysMarked() async throws {
        let flow = try await flow(stored: .changed, rejected: true) { $0.flow = .twoStep }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(["pass": flow.bank.password], reporting: [], in: flow, arrivingAt: "/home")

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)
        #expect(model.panel == .savedPasswordTurnedAway(nil))
        #expect(flow.center.sites.first?.passwordRejected == true)
        #expect(flow.center.sites.first?.needsPerson == false)
    }

    // MARK: When the app fills

    @Test("Once Done reaches a panel the app fills nothing more, even after a later Done is refused", .timeLimit(.minutes(1)))
    func noFillsAfterAPanel() async throws {
        let flow = try await flow(stored: .changed, grant: MakeGrant { bank, password in
            let keyed = passwordGrant(bank, password: password, authenticatorKey: CodeStub.sampleKey, codeKind: .authenticator)
            // No code step is recorded, so only the app's watched fill would answer a code page.
            return SiteGrant(
                username: keyed.username,
                password: keyed.password,
                authenticatorKey: keyed.authenticatorKey,
                signInURL: keyed.signInURL,
                startURL: keyed.startURL,
                fillHosts: keyed.fillHosts,
                browseHosts: keyed.browseHosts,
                codeKind: keyed.codeKind,
                codeSender: nil,
                signInSteps: keyed.signInSteps.filter { $0.kind != .code },
                signOutControlSeen: true
            )
        }) {
            $0.prefillsUsername = true
            // The stored grant's start page never shows signed in, so Leave As Is is refused.
            $0.startPageIgnoresSession = true
        }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        try await signInByHandAfterRefusal(flow, model: model, retypesUsername: false)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(await model.leaveAsIs(using: flow.enrollment, into: flow.center) == .notSaved)
        #expect(model.problem == .signInNotConfirmed)
        #expect(model.panel == nil)

        // A code page the app could answer, and a Done it refuses there.
        _ = try await flow.enrollment.browser.open(URL(string: "https://example.com/verify")!)
        await flow.enrollment.idle()
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .notSaved)
        #expect(model.problem == .notSignedIn)
        await flow.enrollment.idle()

        #expect(flow.bank.site.posts.filter { $0.path == "/verify" }.isEmpty)
    }

    @Test("A Done refused while the app waits for a code has it look at the page again at once", .timeLimit(.minutes(1)))
    func refusedDoneLooksAgain() async throws {
        let gate = TestGate()
        let codes = CodeStub(textedGate: gate)
        let flow = try await flow(codes: codes, grant: MakeGrant { bank, password in
            passwordGrant(bank, password: password, codeKind: .text, codeSender: "24273")
        }) { $0.requiresCode = true }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        let opening = Task { await model.beginIfTrusted(using: flow.enrollment) }
        try await waitFor { codes.calls.filter { $0.hasPrefix("texted") }.count == 1 }
        #expect(flow.enrollment.browser.currentURL?.path == "/verify")

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .notSaved)
        #expect(model.problem == .notSignedIn)
        try await waitFor { codes.calls.filter { $0.hasPrefix("texted") }.count == 2 }

        await gate.open()
        try await waitFor { flow.bank.signedIn && flow.enrollment.browser.currentURL?.path == "/home" }
        await opening.value
        await flow.enrollment.idle()
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
    }

    @Test("With a saved password the user name is filled only on the hosts the password may go to", .timeLimit(.minutes(1)))
    func usernameHeldToPasswordHosts() async throws {
        let usernamePage = TestPages.page("Who", """
            <form method="post" action="/next">
            <input type="text" id="user" name="username" autocomplete="username">
            <button type="submit">Next</button></form>
            """)
        func site() -> TestSite {
            let site = TestSite()
            site.route("/go", page: TestPages.redirect(to: "https://id.example.net/who"))
            site.route("/who", host: "id.example.net", page: usernamePage)
            site.route("/next", method: "POST", host: "id.example.net", page: TestPages.page("Next", "<p>Next</p>"))
            return site
        }
        let saved = site()
        let watched = SiteEnrollment.recordingCredentials(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: saved.answer,
            settling: .fast
        )
        defer { watched.cancel() }
        try await watched.begin(
            signInAddress: "https://example.com/go",
            username: "alice@example.com",
            password: "saved-password",
            authenticatorKey: nil,
            codeKind: .none,
            codeSender: nil,
            passwordHosts: ["example.com"]
        )
        try await waitFor { watched.unvettedFill != nil }
        await watched.idle()
        #expect(saved.posts.isEmpty)
        #expect(watched.unvettedFill == AssistedSignInSession.UnvettedFill(host: "id.example.net", kind: .username))

        // The Add Site form's first sign-in, with nothing saved, fills it.
        let typed = site()
        let adding = SiteEnrollment(dataStore: .nonPersistent(), codes: CodeStub().codes, simulatedPages: typed.answer, settling: .fast)
        defer { adding.cancel() }
        try await adding.begin(
            signInAddress: "https://example.com/go",
            username: "alice@example.com",
            password: "typed-password",
            authenticatorKey: nil,
            codeKind: .none,
            codeSender: nil
        )
        try await waitFor { !typed.posts.isEmpty }
        #expect(typed.posts.map(\.path) == ["/next"])
        #expect(typed.posts.first?.fields["username"] == "alice@example.com")
    }

    // MARK: Recording the person's sign-in

    @Test("personSignedIn records nothing unless a hidden read shows the stored grant signed in, and leaves visits open", .timeLimit(.minutes(1)))
    func personSignedInNeedsASignedInRead() async throws {
        let flow = try await flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        var saves = 0
        flow.center.onSiteSaved = { _, _ in saves += 1 }
        #expect(!flow.bank.signedIn)

        #expect(await flow.center.personSignedIn(siteID: "example.com", storedPasswordWorked: true) == nil)
        #expect(flow.center.sites.first?.needsPerson == true)
        #expect(flow.center.awaitingSignIn == ["example.com"])
        #expect(saves == 0)
        #expect(await flow.center.personSignedIn(siteID: "other.example", storedPasswordWorked: true) == nil)

        flow.bank.markSignedIn()
        var unflagged = try #require(flow.center.access.sites().first)
        unflagged.needsPerson = false
        try SiteRegistry.save([unflagged], to: flow.fixture.registry)
        defer { flow.center.access.end(visit: "run") }
        #expect((try? await flow.center.access.open(siteID: "example.com", visit: "run").get())?.title == "Account")

        let recorded = try #require(await flow.center.personSignedIn(siteID: "example.com", storedPasswordWorked: true))
        #expect(!recorded.needsPerson)
        #expect(!recorded.passwordRejected)
        #expect(flow.center.sites.first?.needsPerson == false)
        #expect(flow.center.awaitingSignIn.isEmpty)
        #expect(saves == 1)
        #expect(flow.center.access.siteID(visit: "run") == "example.com")
        #expect(flow.center.access.currentPage(visit: "run") != nil)

        let turnedAway = try #require(await flow.center.personSignedIn(siteID: "example.com", storedPasswordWorked: false))
        #expect(turnedAway.passwordRejected)
    }

    @Test("The hidden read of personSignedIn sees the session the window's browser signed in to", .timeLimit(.minutes(1)))
    func personSignedInSeesTheWindowsSession() async throws {
        let fixture = try SiteCenterFixture()
        let site = TestSite()
        let password = "Pw-" + UUID().uuidString
        site.route("/login", page: TestPages.page("Sign in", """
            <form method="post" action="/session">
            <input type="text" id="user" name="username" autocomplete="username">
            <input type="password" id="pass" name="password" autocomplete="current-password">
            <button type="submit">Sign in</button></form>
            """))
        site.route("/session", method: "POST") { request in
            guard request.fields["password"] == password else { return TestPages.redirect(to: "/login") }
            return TestPages.page("Welcome", "<p>Signing in</p>", script: """
                document.cookie = 'sid=ok; path=/';
                location.replace('/account');
                """)
        }
        site.route("/account", page: TestPages.page("Account", "<p>Loading</p>", script: """
            if (document.cookie.includes('sid=ok')) {
              document.body.insertAdjacentHTML('beforeend', '<h1>Account</h1><a href="/logout">Sign out</a>');
            } else {
              location.replace('/login');
            }
            """))
        let store = WKWebsiteDataStore.nonPersistent()
        let center = fixture.center(simulatedPages: site.answer, settling: .fast, dataStore: store)
        let elsewhere = fixture.center(simulatedPages: site.answer, settling: .fast)
        let stored = SiteGrant(
            username: "alice@example.com",
            password: "Old-" + UUID().uuidString,
            authenticatorKey: nil,
            signInURL: loginURL,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil,
            signInSteps: [
                SignInStep(kind: .username, origin: "https://example.com", path: "/login", field: usernameField),
                SignInStep(kind: .password, origin: "https://example.com", path: "/login", field: passwordField),
            ],
            signOutControlSeen: true
        )
        var record = SiteRecord(id: "example.com", name: "My Bank", added: added)
        try center.save(grant: stored, record: record)
        record = try #require(center.access.sites().first)
        record.passwordRejected = true
        try SiteRegistry.save([record], to: fixture.registry)
        center.refresh()
        let enrollment = SiteEnrollment.recordingCredentials(
            dataStore: store,
            codes: CodeStub().codes,
            simulatedPages: site.answer,
            settling: .fast
        )
        defer { enrollment.cancel() }
        let model = SiteSignInModel(
            host: "example.com",
            record: record,
            start: .decide(host: "example.com", record: record, grant: center.storedGrant(for: "example.com")) { _ in false },
            proposalID: nil,
            needsPerson: false,
            offersPasswords: true,
            followUps: FollowUpHoldsStub()
        )
        await model.beginIfTrusted(using: enrollment)
        #expect(site.posts.isEmpty)
        _ = try await enrollment.browser.run("""
            document.getElementById('user').value = 'alice@example.com';
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["password": password])
        try await waitFor { enrollment.browser.currentURL?.path == "/account" && !enrollment.browser.webView.isLoading }
        await enrollment.idle()

        // A read on another data store does not see the session.
        #expect(await elsewhere.personSignedIn(siteID: "example.com", storedPasswordWorked: false) == nil)

        #expect(await model.done(using: enrollment, into: center) == .signedInKeepingSavedPassword)
        #expect(model.panel == .savedPasswordTurnedAway(nil))
        #expect(center.sites.first?.needsPerson == false)
    }

    @Test("A model whose sign-in the hidden read cannot confirm says so and leaves Done open", .timeLimit(.minutes(1)))
    func unconfirmedSignInLeavesDoneOpen() async throws {
        let flow = try await flow(stored: .changed) { $0.startPageIgnoresSession = true }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = try model(flow)
        try await signInByHandAfterRefusal(flow, model: model, reports: false)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .notSaved)
        #expect(model.problem == .signInNotConfirmed)
        #expect(model.problem?.signInWindowMessage == "SuperVisor couldn't confirm you're signed in. Finish signing in on the page, then press Done.")
        #expect(model.panel == nil)
        #expect(model.canPressDone)
        #expect(flow.center.sites.first?.needsPerson == true)
    }

    @Test("personSignedIn leaves alone a site saved again while its read ran", .timeLimit(.minutes(1)))
    func personSignedInRespectsTheEpoch() async throws {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        bank.markSignedIn()
        final class Hook {
            var onAccount: (@MainActor () -> Void)?
        }
        let hook = Hook()
        let center = fixture.center(
            simulatedPages: { request in
                if request.url?.path == "/account", let action = hook.onAccount {
                    hook.onAccount = nil
                    action()
                }
                return bank.site.answer(request)
            },
            settling: .fast
        )
        let stored = passwordGrant(bank, password: bank.password)
        try center.save(grant: stored, record: SiteRecord(id: "example.com", name: "My Bank", added: added))
        hook.onAccount = {
            // The same grant saved again, then flagged, while the read is under way.
            try? center.save(grant: stored, record: SiteRecord(id: "example.com", name: "Saved Again", added: self.added))
            if var record = center.access.sites().first {
                record.needsPerson = true
                try? SiteRegistry.save([record], to: fixture.registry)
            }
        }

        #expect(await center.personSignedIn(siteID: "example.com", storedPasswordWorked: true) == nil)
        let site = try #require(center.access.sites().first)
        #expect(site.name == "Saved Again")
        #expect(site.needsPerson)
        withExtendedLifetime(bank) {}
    }

    // MARK: The follow-up hold

    /// A flow with the offer to keep the typed password on screen, and the saves the center
    /// reports, each with whether it owes a pass.
    private func offered(timeout: Duration = SiteSignInModel.standardOfferTimeout) async throws
        -> (flow: Flow, model: SiteSignInModel, owes: Box<[Bool]>) {
        let flow = try await flow(stored: .changed)
        let owes = Box<[Bool]>([])
        flow.center.onSiteSaved = { record, wasAwaited in
            owes.value.append(SignInDemand.effectOfSaving(record.id, proposals: [], now: Date(), wasAwaited: wasAwaited).owesPass)
        }
        let model = try model(flow, offerTimeout: timeout)
        try await signInByHandAfterRefusal(flow, model: model)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .asking)
        #expect(flow.holds.taken == 1)
        #expect(flow.holds.isHeld)
        #expect(owes.value.isEmpty)
        return (flow, model, owes)
    }

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @Test("Keep Typed Password owes one pass, and the hold lasts until the window closes", .timeLimit(.minutes(1)))
    func holdOnKeep() async throws {
        let (flow, model, owes) = try await offered()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }

        #expect(model.keepTypedPassword(using: flow.enrollment, into: flow.center) == .kept)
        #expect(flow.holds.isHeld)
        flow.enrollment.cancel()

        #expect(!flow.holds.isHeld)
        #expect(model.recordingAfterClose == nil)
        #expect(owes.value == [true])
        #expect(flow.center.storedGrant(for: "example.com")?.password == flow.bank.password)
    }

    @Test("Leave As Is owes one pass and lifts the hold at once", .timeLimit(.minutes(1)))
    func holdOnLeave() async throws {
        let (flow, model, owes) = try await offered()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }

        #expect(await model.leaveAsIs(using: flow.enrollment, into: flow.center) == .signedInKeepingSavedPassword)
        #expect(!flow.holds.isHeld)
        flow.enrollment.cancel()
        #expect(model.recordingAfterClose == nil)
        #expect(owes.value == [true])
        #expect(flow.holds.taken == 1)
    }

    @Test("Closing the window on the offer ends as Leave As Is: the hold lifts, the sign-in is recorded once, the grant kept", .timeLimit(.minutes(1)))
    func holdOnClose() async throws {
        let (flow, model, owes) = try await offered()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let before = try storedBytes(flow)

        flow.enrollment.cancel()

        #expect(!flow.holds.isHeld)
        let recording = try #require(model.recordingAfterClose)
        await recording.value
        #expect(owes.value == [true])
        #expect(flow.center.sites.first?.needsPerson == false)
        #expect(flow.center.sites.first?.passwordRejected == true)
        #expect(try storedBytes(flow) == before)
    }

    @Test("An offer left unanswered ends as Leave As Is and closes", .timeLimit(.minutes(1)))
    func holdOnTimeout() async throws {
        let (flow, model, owes) = try await offered(timeout: .milliseconds(200))
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let before = try storedBytes(flow)

        try await waitFor { flow.enrollment.isCancelled }

        #expect(!flow.holds.isHeld)
        #expect(model.recordingAfterClose == nil)
        #expect(owes.value == [true])
        #expect(model.panel == .savedPasswordTurnedAway(nil))
        #expect(flow.center.sites.first?.needsPerson == false)
        #expect(try storedBytes(flow) == before)
    }

    // MARK: Helpers

    /// Waits up to five seconds for `condition`.
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the expected state never came")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
