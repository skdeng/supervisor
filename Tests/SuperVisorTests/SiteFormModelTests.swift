import Foundation
import Testing
import WebKit

@testable import SuperVisor

@Suite("Site form", .serialized)
@MainActor
struct SiteFormModelTests {
    private func filled(_ kind: SiteGrant.CodeKind = .none) -> SiteFormModel {
        let model = SiteFormModel()
        model.method = .signsInForMe
        model.address = "example.com/login"
        model.username = "alice@example.com"
        model.password = "correct horse"
        model.codeKind = kind
        return model
    }

    private func savedGrant(
        kind: SiteGrant.CodeKind = .none,
        key: String? = nil,
        sender: String? = nil
    ) -> SiteGrant {
        SiteGrant(
            username: "alice@example.com",
            password: "saved-password",
            authenticatorKey: key,
            signInURL: URL(string: "https://my.example.com/login")!,
            startURL: URL(string: "https://my.example.com/account")!,
            fillHosts: ["my.example.com"],
            browseHosts: ["my.example.com"],
            codeKind: kind,
            codeSender: sender
        )
    }

    private func savedRecord() -> SiteRecord {
        SiteRecord(
            id: "my.example.com",
            name: "Example Club",
            added: Date(timeIntervalSince1970: 1_700_000_000),
            lastSignedIn: Date(timeIntervalSince1970: 1_750_000_000),
            needsPerson: true
        )
    }

    // MARK: Required fields

    @Test("Each code kind requires its own field on top of the address, user name, and password")
    func requiredFieldsPerKind() {
        let model = SiteFormModel()
        model.method = .signsInForMe
        #expect(model.requiredFields == [.address, .username, .password])
        model.codeKind = .authenticator
        #expect(model.requiredFields == [.address, .username, .password, .authenticatorKey])
        model.codeKind = .text
        #expect(model.requiredFields == [.address, .username, .password])
        model.codeKind = .email
        #expect(model.requiredFields == [.address, .username, .password, .codeSender])
    }

    @Test("Signing in again needs no password, nor a key when one is saved")
    func requiredFieldsSigningInAgain() {
        let model = SiteFormModel(
            signingInAgain: savedGrant(kind: .authenticator, key: CodeStub.sampleKey),
            record: savedRecord()
        )
        #expect(model.requiredFields == [.address, .username])

        let withoutKey = SiteFormModel(signingInAgain: savedGrant(), record: savedRecord())
        withoutKey.codeKind = .authenticator
        #expect(withoutKey.requiredFields == [.address, .username, .authenticatorKey])
    }

    @Test("An address from the middle of a sign-in draws advice; a starting address draws none")
    func addressAdvice() {
        let model = SiteFormModel()

        for starting in ["my.example.com", "example.com/account", "www.example.com/login", ""] {
            model.address = starting
            #expect(model.addressAdvice == nil, "\(starting)")
        }
        for midway in [
            "authentication.example.com/enroll/collect",
            "example.com/login?state=abc123",
            "LOGIN.example.com",
            "sso.example.com/start",
        ] {
            model.address = midway
            #expect(model.addressAdvice != nil, "\(midway)")
        }

        // An address that is refused outright shows its problem, never both.
        model.address = "http://login.example.com"
        #expect(model.addressProblem != nil)
        #expect(model.addressAdvice == nil)
    }

    @Test("A saved site's address is fixed, so it draws no advice")
    func addressAdviceSigningInAgain() {
        let model = SiteFormModel(signingInAgain: savedGrant(), record: savedRecord())
        model.address = "login.example.com/start?state=abc"
        #expect(model.addressAdvice == nil)
    }

    // MARK: Sign In and Save

    @Test("Sign In opens up once the address, user name, and password are in")
    func canSignInTransitions() {
        let model = SiteFormModel()
        model.method = .signsInForMe
        #expect(!model.canSignIn)
        model.address = "example.com/login"
        #expect(!model.canSignIn)
        model.username = "alice@example.com"
        #expect(!model.canSignIn)
        model.password = "correct horse"
        #expect(model.canSignIn)

        model.username = "   "
        #expect(!model.canSignIn)
        model.username = "alice@example.com"

        model.isWorking = true
        #expect(!model.canSignIn)
        model.isWorking = false
        #expect(model.canSignIn)
    }

    @Test("An address that is not an https sign-in page blocks Sign In and says so")
    func invalidAddress() {
        let model = filled()
        #expect(model.addressProblem == nil)
        for address in ["http://example.com/login", "example.com:8443/login", "https://user@example.com/", "not an address"] {
            model.address = address
            #expect(!model.canSignIn, "\(address)")
            #expect(model.addressProblem == "Enter the https address of the site's sign-in page.", "\(address)")
        }
        model.address = ""
        #expect(model.addressProblem == nil)
        #expect(!model.canSignIn)
    }

    @Test("An authenticator key that does not parse blocks Sign In; one that does is passed on")
    func authenticatorKey() throws {
        let model = filled(.authenticator)
        #expect(!model.canSignIn)
        #expect(model.authenticatorKeyProblem == nil)

        model.authenticatorKey = "not-a-key"
        #expect(!model.canSignIn)
        #expect(model.authenticatorKeyProblem == "This is not a setup key or otpauth:// link.")
        #expect(!model.isAuthenticatorKeyAccepted)

        model.authenticatorKey = " \(CodeStub.sampleKey) "
        #expect(model.canSignIn)
        #expect(model.authenticatorKeyProblem == nil)
        #expect(model.isAuthenticatorKeyAccepted)
        let request = try #require(model.signInRequest)
        #expect(request.authenticatorKey == CodeStub.sampleKey)
        #expect(request.codeKind == .authenticator)
        #expect(request.codeSender == nil)
    }

    @Test("An emailed code needs a sender address, which is passed on")
    func emailedSender() throws {
        let model = filled(.email)
        #expect(!model.canSignIn)
        model.codeSender = "no reply"
        #expect(!model.canSignIn)
        #expect(model.codeSenderProblem == "Enter the address the code emails come from.")
        model.codeSender = " no-reply@bank.example "
        #expect(model.codeSenderProblem == nil)
        let request = try #require(model.signInRequest)
        #expect(request.codeSender == "no-reply@bank.example")
        #expect(request.authenticatorKey == nil)
    }

    @Test("A texted code needs texts on and readable, and its sender is learned")
    func textedNeedsTexts() throws {
        let model = filled(.text)
        model.textsStatus = .off
        #expect(model.textsBlockSignIn)
        #expect(!model.canSignIn)
        model.textsStatus = .accessDenied
        #expect(!model.canSignIn)
        model.textsStatus = .on
        #expect(model.canSignIn)
        #expect(try #require(model.signInRequest).codeSender == nil)

        // Texts matter only to a texted code.
        model.codeKind = .none
        model.textsStatus = .off
        #expect(model.canSignIn)
    }

    @Test("A key typed for another kind is not passed on")
    func keyOnlyForAuthenticator() throws {
        let model = filled(.authenticator)
        model.authenticatorKey = CodeStub.sampleKey
        model.codeKind = .none
        let request = try #require(model.signInRequest)
        #expect(request.authenticatorKey == nil)
        #expect(request.codeKind == .none)
        #expect(request.address == "https://example.com/login")
    }

    @Test("Save needs a sign-in to have started")
    func canSaveBeforeSignIn() {
        let model = filled()
        #expect(!model.canSave)
    }

    // MARK: Name

    @Test("The name follows the address's host until it is edited")
    func derivedName() {
        let model = SiteFormModel()
        #expect(model.name == "")
        model.address = "my.clearme.com/login"
        #expect(model.name == "clearme.com")
        model.address = "https://www.example.org/signin"
        #expect(model.name == "example.org")
        model.address = "my.com/login"
        #expect(model.name == "my.com")
        model.address = "accounts.example.com"
        #expect(model.name == "accounts.example.com")

        model.name = "Example"
        model.address = "my.clearme.com/login"
        #expect(model.name == "Example")
        #expect(model.resolvedName == "Example")

        // An emptied name stays empty in the field and falls back to the host when saved.
        model.name = ""
        #expect(model.name == "")
        #expect(model.resolvedName == "clearme.com")
    }

    // MARK: Problems

    @Test("Each failure is shown as its fixed sentence")
    func problemSentences() {
        typealias Problem = SiteFormModel.Problem
        #expect(Problem.ofSignIn(SiteEnrollment.Failure.invalidAddress) == .invalidAddress)
        #expect(Problem.ofSignIn(SiteBrowser.Failure.loadFailed) == .pageDidNotLoad)
        #expect(Problem.ofSignIn(SiteBrowser.Failure.timedOut) == .pageDidNotLoad)
        #expect(Problem.ofFinish(SiteEnrollment.Failure.notSignedIn) == .notSignedIn)
        #expect(Problem.ofFinish(SiteEnrollment.Failure.invalidGrant) == .invalidGrant)
        #expect(Problem.ofFinish(SiteEnrollment.Failure.passwordNotConfirmed) == .passwordNotConfirmed)
        #expect(Problem.ofFinish(SiteEnrollment.Failure.passwordNotFilled) == .passwordNotFilled)
        #expect(Problem.ofFinish(SiteEnrollment.Failure.cancelled) == nil)
        #expect(Problem.passwordNotConfirmed.message == "SuperVisor can't tell which password worked. Type the working password in the form here, then press Sign In again.")
        #expect(Problem.passwordNotFilled.message == "SuperVisor didn't fill the sign-in itself, so it couldn't record it. Press Sign In and let it fill the page.")
        #expect(Problem.passwordNotConfirmed.needsNewSignIn)
        #expect(Problem.passwordNotFilled.needsNewSignIn)
        #expect(!Problem.notSignedIn.needsNewSignIn)

        #expect(Problem.invalidAddress.message == "Enter the https address of the site's sign-in page.")
        #expect(Problem.notSignedIn.message == "Finish signing in on the page first, then save.")
        #expect(Problem.invalidGrant.message == "This sign-in could not be recorded. Try again from the sign-in page.")
        #expect(Problem.notSaved.message == "The site could not be saved to the Keychain.")
        #expect(Problem.pageDidNotLoad.message.hasSuffix("."))
    }

    // MARK: Signing in again

    @Test("Signing in again fills in the saved site, and an empty password stands for the saved one")
    func prefilled() throws {
        let model = SiteFormModel(
            signingInAgain: savedGrant(kind: .email, sender: "no-reply@example.com"),
            record: savedRecord()
        )
        #expect(model.mode == .signingInAgain(siteID: "my.example.com"))
        #expect(model.isSigningInAgain)
        #expect(model.address == "https://my.example.com/login")
        #expect(model.name == "Example Club")
        #expect(model.username == "alice@example.com")
        #expect(model.password.isEmpty)
        #expect(model.codeKind == .email)
        #expect(model.codeSender == "no-reply@example.com")
        #expect(model.canSignIn)

        #expect(try #require(model.signInRequest).password == "saved-password")
        model.password = "new-password"
        #expect(try #require(model.signInRequest).password == "new-password")
        model.password = ""
        #expect(try #require(model.signInRequest).password == "saved-password")
    }

    @Test("Signing in again keeps the saved key until another is typed, and the saved texted sender")
    func prefilledCodes() throws {
        let withKey = SiteFormModel(
            signingInAgain: savedGrant(kind: .authenticator, key: CodeStub.sampleKey),
            record: savedRecord()
        )
        #expect(withKey.authenticatorKey.isEmpty)
        #expect(withKey.hasSavedAuthenticatorKey)
        #expect(try #require(withKey.signInRequest).authenticatorKey == CodeStub.sampleKey)
        let other = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        withKey.authenticatorKey = other
        #expect(try #require(withKey.signInRequest).authenticatorKey == other)
        withKey.authenticatorKey = "not-a-key"
        #expect(withKey.signInRequest == nil)

        let texted = SiteFormModel(
            signingInAgain: savedGrant(kind: .text, sender: "24273"),
            record: savedRecord()
        )
        texted.textsStatus = .on
        #expect(texted.codeSender.isEmpty)
        #expect(try #require(texted.signInRequest).codeSender == "24273")
    }

    @Test("Nothing about the form shows the password it holds")
    func redacted() throws {
        let model = SiteFormModel(signingInAgain: savedGrant(), record: savedRecord())
        model.password = "typed-secret"
        var dumped = ""
        dump(model, to: &dumped)
        let request = try #require(model.signInRequest)
        dump(request, to: &dumped)
        dumped += "\(request) \(String(reflecting: request))"
        #expect(!dumped.contains("typed-secret"))
        #expect(!dumped.contains("saved-password"))
    }

    // MARK: The whole flow

    @Test("Signing in on a site and saving it stores the site", .timeLimit(.minutes(1)))
    func signInAndSave() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        defer { enrollment.cancel() }

        let model = SiteFormModel()
        model.method = .signsInForMe
        model.address = "example.com/login"
        model.username = bank.username
        model.password = bank.password
        model.follow(enrollment, center: center)
        #expect(!model.canSave)

        await model.signIn(using: enrollment)
        #expect(model.problem == nil)
        #expect(model.canSave)
        #expect(!model.isWorking)

        #expect(await model.save(using: enrollment, into: center) == .saved)
        #expect(model.problem == nil)
        #expect(center.sites.map(\.id) == ["example.com"])
        #expect(center.sites.first?.name == "example.com")
        #expect(center.storedGrant(for: "example.com")?.password == bank.password)
    }

    @Test("Saving before the page shows a signed-in user says to finish first", .timeLimit(.minutes(1)))
    func saveBeforeSignedIn() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        bank.neverSignsIn = true
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        defer { enrollment.cancel() }

        let model = filled()
        model.username = bank.username
        model.password = bank.password
        await model.signIn(using: enrollment)
        #expect(model.canSave)

        #expect(await model.save(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .notSignedIn)
        #expect(center.sites.isEmpty)
        #expect(model.canSave)
    }

    @Test("Signing in again replaces the grant, keeps when the site was added, and clears needs-you", .timeLimit(.minutes(1)))
    func signInAgainReplaces() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        let original = SiteGrant(
            username: bank.username,
            password: bank.password,
            authenticatorKey: nil,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil
        )
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        try center.save(grant: original, record: SiteRecord(id: "example.com", name: "Bank", added: added))
        var stale = try #require(center.sites.first)
        stale.needsPerson = true
        try SiteRegistry.save([stale], to: fixture.registry)
        center.refresh()
        #expect(center.sites.first?.needsPerson == true)

        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        defer { enrollment.cancel() }
        let model = SiteFormModel(signingInAgain: original, record: try #require(center.sites.first))
        #expect(model.password.isEmpty)

        await model.signIn(using: enrollment)
        #expect(await model.save(using: enrollment, into: center) == .saved)

        let site = try #require(center.sites.first)
        #expect(center.sites.count == 1)
        #expect(site.name == "Bank")
        #expect(site.added == added)
        #expect(!site.needsPerson)
        let grant = try #require(center.storedGrant(for: "example.com"))
        #expect(grant.password == bank.password)
        #expect(!grant.signInSteps.isEmpty)
    }

    // MARK: Save stores what signed in

    /// A center, a fake bank, and an enrollment on it for a flow test.
    private func flow(
        _ configure: (TestBank) -> Void = { _ in }
    ) throws -> (fixture: SiteCenterFixture, center: SiteAccessCenter, bank: TestBank, enrollment: SiteEnrollment) {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        configure(bank)
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast
        )
        return (fixture, center, bank, enrollment)
    }

    private func form(for bank: TestBank, password: String? = nil) -> SiteFormModel {
        let model = SiteFormModel()
        model.method = .signsInForMe
        model.address = "example.com/login"
        model.username = bank.username
        model.password = password ?? bank.password
        return model
    }

    @Test("Editing the sign-in details after signing in closes Save until Sign In is pressed again", .timeLimit(.minutes(1)))
    func editsAfterSignInBlockSave() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = form(for: bank)
        model.follow(enrollment, center: center)
        await model.signIn(using: enrollment)
        #expect(model.canSave)
        #expect(model.saveBlocker == nil)

        model.password = "something else"
        #expect(!model.canSave)
        #expect(model.saveBlocker == "You changed the sign-in details. Press Sign In again before saving.")
        #expect(await model.save(using: enrollment, into: center) == .notSaved)
        #expect(center.sites.isEmpty)

        model.password = bank.password
        #expect(model.canSave)
        model.codeKind = .authenticator
        model.authenticatorKey = CodeStub.sampleKey
        #expect(!model.canSave)
        model.codeKind = .none
        #expect(model.canSave)

        // The display name is not a sign-in detail.
        model.name = "My Bank"
        #expect(model.canSave)
        #expect(await model.save(using: enrollment, into: center) == .saved)
        #expect(center.sites.first?.name == "My Bank")
    }

    @Test("A texts status that changes after signing in is not a changed detail")
    func textsStatusIsNotADetail() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = form(for: bank)
        model.follow(enrollment, center: center)
        model.codeKind = .text
        center.setTextsEnabled(true)
        #expect(model.textsStatus == .on)
        await model.signIn(using: enrollment)
        #expect(model.started != nil)

        center.setTextsEnabled(false)
        #expect(!model.canSignIn)
        #expect(!model.detailsChanged)
        #expect(model.canSave)
    }

    @Test("A password the site rejected and the person then typed in the page is not saved", .timeLimit(.minutes(1)))
    func rejectedPasswordIsNotSaved() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = form(for: bank, password: "an-old-password")
        await model.signIn(using: enrollment)
        #expect(!bank.signedIn)

        _ = try await enrollment.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(bank.signedIn && enrollment.browser.currentURL?.path == "/home"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await enrollment.idle()

        #expect(await model.save(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .passwordNotConfirmed)
        #expect(!model.canSave)
        #expect(center.sites.isEmpty)

        // The working password typed into the form, and a new sign-in, make it savable.
        model.password = bank.password
        bank.signOut()
        await model.signIn(using: enrollment)
        #expect(model.canSave)
        #expect(await model.save(using: enrollment, into: center) == .saved)
        #expect(center.storedGrant(for: "example.com")?.password == bank.password)
    }

    @Test("A failed save is tried again with the same sign-in", .timeLimit(.minutes(1)), .enabled(if: getuid() != 0))
    func failedSaveIsRetried() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = form(for: bank)
        await model.signIn(using: enrollment)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        let first = await model.save(using: enrollment, into: center)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        #expect(first == .notSaved)
        #expect(model.problem == .notSaved)
        #expect(model.canSave)
        #expect(center.sites.isEmpty)

        // The enrollment has handed over its grant and holds nothing more, so only the kept
        // grant can make this save.
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) { _ = try await enrollment.finish(name: "Bank") }
        #expect(await model.save(using: enrollment, into: center) == .saved)
        #expect(center.sites.map(\.id) == ["example.com"])
        #expect(model.problem == nil)
    }

    @Test("Closing the window while a save is under way stores nothing", .timeLimit(.minutes(1)))
    func cancelDuringSaveStoresNothing() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer { withExtendedLifetime(fixture) {} }
        let model = form(for: bank)
        await model.signIn(using: enrollment)
        #expect(model.canSave)

        let saving = Task { @MainActor in await model.save(using: enrollment, into: center) }
        while !model.isSaving {
            await Task.yield()
        }
        enrollment.cancel()

        #expect(await saving.value == .notSaved)
        #expect(model.problem == nil)
        #expect(center.sites.isEmpty)
        #expect(fixture.store.accounts.isEmpty)
    }

    @Test("A texted-code site that asked for no code is saved without one, and the user is told", .timeLimit(.minutes(1)))
    func textedWithoutCodeIsSavedWithNotice() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = form(for: bank)
        model.codeKind = .text
        model.textsStatus = .on
        await model.signIn(using: enrollment)

        let outcome = await model.save(using: enrollment, into: center)
        #expect(outcome == .savedWithNotice(
            "Saved. example.com didn't ask for a code this time, so SuperVisor hasn't learned who texts it. If it asks later, you'll be asked to sign in again."
        ))
        #expect(center.storedGrant(for: "example.com")?.codeKind == SiteGrant.CodeKind.none)
    }

    @Test("Only a texted or emailed site saved with no code gets the notice")
    func noticeDecision() {
        #expect(SiteFormModel.noticeAfterSaving(requested: .text, saved: .none, name: "Bank")?.contains("who texts it") == true)
        #expect(SiteFormModel.noticeAfterSaving(requested: .email, saved: .none, name: "Bank")?.contains("who emails it") == true)
        #expect(SiteFormModel.noticeAfterSaving(requested: .text, saved: .text, name: "Bank") == nil)
        #expect(SiteFormModel.noticeAfterSaving(requested: .none, saved: .none, name: "Bank") == nil)
        #expect(SiteFormModel.noticeAfterSaving(requested: .authenticator, saved: .authenticator, name: "Bank") == nil)
    }

    // MARK: Saved secrets

    @Test("Signing in again sends the saved password and key only to the grant's fill hosts")
    func savedSecretsCarryTheirHosts() throws {
        let model = SiteFormModel(
            signingInAgain: savedGrant(kind: .authenticator, key: CodeStub.sampleKey),
            record: savedRecord()
        )
        let saved = try #require(model.signInRequest)
        #expect(saved.passwordHosts == ["my.example.com"])
        #expect(saved.authenticatorHosts == ["my.example.com"])

        model.password = "typed-now"
        model.authenticatorKey = "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
        let typed = try #require(model.signInRequest)
        #expect(typed.passwordHosts == nil)
        #expect(typed.authenticatorHosts == nil)

        let adding = filled(.authenticator)
        adding.authenticatorKey = CodeStub.sampleKey
        let fresh = try #require(adding.signInRequest)
        #expect(fresh.passwordHosts == nil)
        #expect(fresh.authenticatorHosts == nil)
    }

    @Test("Signing in again keeps the saved site's address whatever is set")
    func addressIsFixedWhenSigningInAgain() throws {
        let model = SiteFormModel(signingInAgain: savedGrant(), record: savedRecord())
        model.address = "evil.example.net/login"
        #expect(model.address == "https://my.example.com/login")
        #expect(try #require(model.signInRequest).address == "https://my.example.com/login")
    }

    @Test("The moved-page sentence names the host and what to type")
    func movedMessages() {
        #expect(SiteFormModel.movedMessage(.init(host: "login.example.net", kind: .password))
            == "This site's sign-in page has moved to login.example.net. Type your password here to continue.")
        #expect(SiteFormModel.movedMessage(.init(host: "login.example.net", kind: .code))
            == "This site's sign-in page has moved to login.example.net. Type your setup key here to continue.")
    }

    // MARK: Keep me signed in

    /// Signs in on the open page the way the person would, and waits for the signed-in page.
    private func signInOnPage(_ enrollment: SiteEnrollment, _ bank: TestBank) async throws {
        _ = try await enrollment.browser.run("""
            document.getElementById('user').value = username;
            document.getElementById('pass').value = password;
            HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);
            """, arguments: ["username": bank.username, "password": bank.password])
        let deadline = ContinuousClock.now + .seconds(5)
        while !(bank.signedIn && enrollment.browser.currentURL?.path == "/home"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        await enrollment.idle()
    }

    private func sessionGrant() -> SiteGrant {
        SiteGrant(
            username: "",
            password: "",
            authenticatorKey: nil,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil,
            remembersPassword: false
        )
    }

    @Test("A new form keeps the site signed in, and asks for the address alone")
    func keepsSessionByDefault() {
        let model = SiteFormModel()
        #expect(model.method == .keepsSession)
        #expect(model.canChooseMethod)
        #expect(model.requiredFields == [.address])
        #expect(!model.canOpenPage)
        #expect(!model.canSignIn)

        model.address = "example.com/login"
        #expect(model.canOpenPage)
        #expect(model.keptSessionAddress == "https://example.com/login")
        #expect(!model.canSignIn)

        model.method = .signsInForMe
        #expect(!model.canOpenPage)
        #expect(model.requiredFields == [.address, .username, .password])
    }

    @Test("The two ways of keeping a site are named and explained")
    func methodSentences() {
        #expect(SiteFormModel.methods == [.keepsSession, .signsInForMe])
        #expect(SiteFormModel.Method.keepsSession.title == "Keep me signed in")
        #expect(SiteFormModel.Method.keepsSession.explanation == "Sign in on the page yourself. SuperVisor saves no password and asks you again when the site signs you out.")
        #expect(SiteFormModel.Method.signsInForMe.title == "Sign in for me")
        #expect(SiteFormModel.Method.signsInForMe.explanation == "SuperVisor saves your user name and password in the Keychain and signs in by itself.")
    }

    @Test("Opening the page and saving stores a site that keeps the session and no password", .timeLimit(.minutes(1)))
    func openPageAndSave() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = SiteFormModel()
        model.address = "example.com/login"
        model.follow(enrollment, center: center)
        #expect(!model.canSave)

        await model.openPage(using: enrollment)
        #expect(model.problem == nil)
        #expect(model.started == .keepingSession(address: "https://example.com/login"))
        #expect(model.canSave)
        try await signInOnPage(enrollment, bank)

        var saved: [SiteRecord] = []
        #expect(await model.save(using: enrollment, into: center) { saved.append($0) } == .saved)
        #expect(saved.map(\.id) == ["example.com"])
        let site = try #require(center.sites.first)
        #expect(site.keepsSessionOnly)
        #expect(SiteAccessCenter.SiteStatus(site) == .signedInKeepingSession(try #require(site.lastSignedIn)))
        let grant = try #require(center.storedGrant(for: "example.com"))
        #expect(!grant.remembersPassword)
        #expect(grant.password.isEmpty)
        #expect(bank.site.posts.count == 1)
    }

    @Test("Saving a public page that never asked for a sign-in says so and stores nothing", .timeLimit(.minutes(1)))
    func keepSessionPublicPage() async throws {
        let (fixture, center, bank, enrollment) = try flow { $0.startPageIsPublic = true }
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = SiteFormModel()
        model.address = "example.com/account"
        await model.openPage(using: enrollment)

        #expect(await model.save(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .signInNotSeen)
        #expect(model.problem?.message == "SuperVisor hasn't seen you sign in yet. Sign in on the page, then save.")
        #expect(model.canSave)
        #expect(center.sites.isEmpty)
    }

    @Test("Saving before the page shows the person signed in stores nothing", .timeLimit(.minutes(1)))
    func keepSessionSaveBeforeSignedIn() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = SiteFormModel()
        model.address = "example.com/login"
        await model.openPage(using: enrollment)

        var saved = 0
        #expect(await model.save(using: enrollment, into: center) { _ in saved += 1 } == .notSaved)
        #expect(model.problem == .notSignedIn)
        #expect(saved == 0)
        #expect(center.sites.isEmpty)
        #expect(model.canSave)
    }

    @Test("Switching how the site is kept after opening the page closes Save until that way's button is pressed", .timeLimit(.minutes(1)))
    func switchingMethodBlocksSave() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let model = SiteFormModel()
        model.address = "example.com/login"
        model.username = bank.username
        model.password = bank.password
        await model.openPage(using: enrollment)
        try await signInOnPage(enrollment, bank)
        #expect(model.canSave)

        model.method = .signsInForMe
        #expect(!model.canSave)
        #expect(model.saveBlocker == SiteFormModel.detailsChangedMessage)
        #expect(await model.save(using: enrollment, into: center) == .notSaved)
        #expect(center.sites.isEmpty)

        model.method = .keepsSession
        #expect(model.canSave)
        model.address = "example.com/account"
        #expect(!model.canSave)
        #expect(model.saveBlocker == "You changed the sign-in details. Press Open Page again before saving.")
        bank.signOut()
        await model.openPage(using: enrollment)
        try await signInOnPage(enrollment, bank)
        #expect(model.canSave)
        #expect(await model.save(using: enrollment, into: center) == .saved)
        #expect(center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("A refused address on Open Page leaves nothing to save")
    func openPageRefusedAddress() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = SiteFormModel()
        model.address = "http://example.com/login"
        #expect(!model.canOpenPage)
        await model.openPage(using: enrollment)
        #expect(model.started == nil)
        #expect(await model.save(using: enrollment, into: center) == .notSaved)
    }

    @Test("Signing in again to a site kept by its session opens in that way with the address fixed", .timeLimit(.minutes(1)))
    func signInAgainKeepingSession() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime(fixture) {}
        }
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        try center.save(grant: sessionGrant(), record: SiteRecord(id: "example.com", name: "Bank", added: added))
        var stale = try #require(center.sites.first)
        stale.needsPerson = true
        try SiteRegistry.save([stale], to: fixture.registry)
        center.refresh()

        let model = SiteFormModel(signingInAgain: sessionGrant(), record: try #require(center.sites.first))
        #expect(model.method == .keepsSession)
        #expect(!model.canChooseMethod)
        model.method = .signsInForMe
        #expect(model.method == .keepsSession)
        #expect(model.address == "https://example.com/login")
        model.address = "evil.example.net/login"
        #expect(model.address == "https://example.com/login")
        #expect(model.requiredFields == [.address])
        #expect(model.request == nil)

        await model.openPage(using: enrollment)
        try await signInOnPage(enrollment, bank)
        #expect(await model.save(using: enrollment, into: center) == .saved)

        let site = try #require(center.sites.first)
        #expect(!site.needsPerson)
        #expect(site.added == added)
        #expect(site.keepsSessionOnly)
        #expect(site.attemptCount == 0)
    }

    @Test("Signing in again to a site that signs in by itself stays that way")
    func signInAgainWithPasswordKeepsMethod() {
        let model = SiteFormModel(signingInAgain: savedGrant(), record: savedRecord())
        #expect(model.method == .signsInForMe)
        model.method = .keepsSession
        #expect(model.method == .signsInForMe)
    }

    @Test("A site kept by its session whose saved sign-in cannot be read is added again the same way")
    func unreadableSessionSite() {
        var record = savedRecord()
        record.keepsSessionOnly = true
        let model = SiteFormModel(unreadableSite: record)
        #expect(model.method == .keepsSession)
        #expect(model.requiredFields == [.address])
        #expect(SiteFormModel(unreadableSite: savedRecord()).method == .signsInForMe)
    }

    // MARK: Requests from ProVisor

    @Test("A request for a host the user has visited fills in the address and says it matched")
    func requestVisited() {
        var asked: [String] = []
        let start = SiteFormModel.requestedStart(host: "example.com", grantedSites: []) { host in
            asked.append(host)
            return true
        }
        #expect(start == .adding(prefilledAddress: "example.com"))
        #expect(asked == ["example.com"])

        let model = SiteFormModel(requestedHost: "example.com", proposalID: "2026-11-17-check", prefilledAddress: "example.com")
        #expect(model.address == "example.com")
        #expect(model.method == .keepsSession)
        #expect(model.mode == .adding)
        #expect(model.canOpenPage)
        #expect(model.request == SiteFormModel.Request(
            proposalID: "2026-11-17-check",
            host: "example.com",
            message: "ProVisor asked for this site. It matches a site in your browser history.",
            isRecognised: true
        ))
    }

    @Test("A request for a host the user has not visited leaves the address empty and says to type it")
    func requestNotVisited() {
        let start = SiteFormModel.requestedStart(host: "examp1e-login.com", grantedSites: []) { _ in false }
        #expect(start == .adding(prefilledAddress: nil))

        let model = SiteFormModel(requestedHost: "examp1e-login.com", proposalID: "2026-11-17-check", prefilledAddress: nil)
        #expect(model.address.isEmpty)
        #expect(model.name.isEmpty)
        #expect(!model.canOpenPage)
        #expect(model.request == SiteFormModel.Request(
            proposalID: "2026-11-17-check",
            host: "examp1e-login.com",
            message: "ProVisor asked for examp1e-login.com. SuperVisor hasn't seen that address in your browser history, so type the site's address yourself.",
            isRecognised: false
        ))
    }

    @Test("A prefilled address other than the requested host is not taken")
    func requestPrefillMustBeTheHost() {
        let model = SiteFormModel(requestedHost: "example.com", proposalID: "p", prefilledAddress: "evil.example.net")
        #expect(model.address.isEmpty)
        #expect(model.request?.isRecognised == false)
    }

    @Test("A request for a granted site signs in to it again, without reading the history")
    func requestGranted() {
        let granted = SiteRecord(id: "example.com", name: "Bank", added: Date(timeIntervalSince1970: 0))
        var asked = 0
        let start = SiteFormModel.requestedStart(host: "example.com", grantedSites: [granted]) { _ in
            asked += 1
            return false
        }
        #expect(start == .signingInAgain(siteID: "example.com"))
        #expect(asked == 0)

        let model = SiteFormModel(signingInAgain: sessionGrant(), record: granted, requestedBy: "p")
        #expect(model.request?.proposalID == "p")
        #expect(model.request?.host == "example.com")
        #expect(model.request?.message == "ProVisor asked you to sign in to Bank again.")
    }

    @Test("A requested host that is not a host name is never filled in")
    func requestInvalidHost() {
        var asked = 0
        let start = SiteFormModel.requestedStart(host: "https://example.com/login", grantedSites: []) { _ in
            asked += 1
            return true
        }
        #expect(start == .adding(prefilledAddress: nil))
        #expect(asked == 0)
    }

    @Test("Closing a requested form without saving reports no save", .timeLimit(.minutes(1)))
    func requestCancelReportsNothing() async throws {
        let (fixture, center, bank, enrollment) = try flow { $0.markSignedIn() }
        defer { withExtendedLifetime((fixture, bank)) {} }
        let model = SiteFormModel(requestedHost: "example.com", proposalID: "p", prefilledAddress: "example.com")
        model.address = "example.com/account"
        await model.openPage(using: enrollment)
        enrollment.cancel()

        var saved = 0
        #expect(await model.save(using: enrollment, into: center) { _ in saved += 1 } == .notSaved)
        #expect(saved == 0)
        #expect(center.sites.isEmpty)
    }

    /// The proposals folder of a request for example.com, and a form opened from it.
    private func requestFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-form-request-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fields: [String: Any] = [
            "title": "Confirm the renewal",
            "action": "Record the answer in followups/x.md.",
            "kind": "confirm",
            "site": "example.com",
        ]
        try JSONSerialization.data(withJSONObject: fields)
            .write(to: directory.appendingPathComponent("2026-11-17-check.json"))
        return directory
    }

    /// What the window hands a save from a requested form, with the center's folder replaced.
    private func settler(
        _ request: SiteFormModel.Request?,
        in directory: URL,
        outcomes: @escaping (SiteRequests.Outcome) -> Void
    ) -> (SiteRecord) -> Void {
        { record in
            guard let request else { return }
            outcomes(SiteRequests.settle(
                proposalID: request.proposalID,
                host: request.host,
                savedSiteID: record.id,
                siteName: record.name,
                in: directory,
                isBusy: false
            ))
        }
    }

    @Test("Saving the requested site from the form settles the request on disk", .timeLimit(.minutes(1)))
    func requestSettledOnSave() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        let directory = try requestFolder()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
            try? FileManager.default.removeItem(at: directory)
        }
        let model = SiteFormModel(requestedHost: "example.com", proposalID: "2026-11-17-check", prefilledAddress: "example.com")
        model.address = "example.com/login"
        model.name = "Example Club"
        await model.openPage(using: enrollment)
        try await signInOnPage(enrollment, bank)

        var outcomes: [SiteRequests.Outcome] = []
        let saved = await model.save(
            using: enrollment,
            into: center,
            onSaved: settler(model.request, in: directory) { outcomes.append($0) }
        )

        #expect(saved == .saved)
        #expect(outcomes == [.settled])
        let proposal = try #require(ProposalStore.load(from: directory).first)
        #expect(proposal.status == .done)
        #expect(proposal.result == "Signed in to Example Club.")
    }

    @Test("Saving a site under another host from a requested form leaves the request open", .timeLimit(.minutes(1)))
    func requestNotSettledForAnotherHost() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        bank.site.route("/login", host: "login.example.com", page: TestPages.redirect(to: "https://example.com/login"))
        let directory = try requestFolder()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
            try? FileManager.default.removeItem(at: directory)
        }
        let model = SiteFormModel(requestedHost: "example.com", proposalID: "2026-11-17-check", prefilledAddress: nil)
        model.address = "login.example.com/login"
        await model.openPage(using: enrollment)
        try await signInOnPage(enrollment, bank)

        var outcomes: [SiteRequests.Outcome] = []
        let saved = await model.save(
            using: enrollment,
            into: center,
            onSaved: settler(model.request, in: directory) { outcomes.append($0) }
        )

        #expect(saved == .saved)
        #expect(center.sites.map(\.id) == ["login.example.com"])
        #expect(outcomes == [.otherSite])
        #expect(ProposalStore.load(from: directory).first?.status == .proposed)
    }

    @Test("A site whose saved sign-in cannot be read opens as a new one, saying so")
    func unreadableSiteForm() {
        let model = SiteFormModel(unreadableSite: savedRecord())
        #expect(model.mode == .adding)
        #expect(!model.isSigningInAgain)
        #expect(model.notice == "Example Club's saved sign-in couldn't be read. Add it again.")
        #expect(model.name == "Example Club")
        #expect(model.requiredFields.contains(.password))
    }
}
