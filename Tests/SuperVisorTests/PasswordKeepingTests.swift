import Foundation
import Testing
import WebKit

@testable import SuperVisor

/// The sign-in window's offer to keep a password, on the simulated bank.
///
/// A trusted input event cannot be made from a test, so a test places the values in the page
/// with a script, which the credential script ignores, reports the same values to the browser
/// as the credential script would (`SiteBrowser.noteCredential`, with values built through
/// `TypedCredential`'s checks), and submits the form.
@Suite("Keeping a typed password", .serialized)
@MainActor
struct PasswordKeepingTests {
    private let loginURL = URL(string: "https://example.com/login")!

    private struct Flow {
        let fixture: SiteCenterFixture
        let center: SiteAccessCenter
        let bank: TestBank
        let enrollment: SiteEnrollment
        let holds: FollowUpHoldsStub
    }

    /// A center that reads the bank, and a recording enrollment on it unless `recording` is false.
    private func flow(recording: Bool = true, _ configure: (TestBank) -> Void = { _ in }) throws -> Flow {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        configure(bank)
        let center = fixture.center(simulatedPages: bank.site.answer, settling: .fast)
        let enrollment = recording
            ? SiteEnrollment.recordingCredentials(
                dataStore: .nonPersistent(),
                codes: CodeStub().codes,
                simulatedPages: bank.site.answer,
                settling: .fast
            )
            : SiteEnrollment(
                dataStore: .nonPersistent(),
                codes: CodeStub().codes,
                simulatedPages: bank.site.answer,
                settling: .fast
            )
        return Flow(fixture: fixture, center: center, bank: bank, enrollment: enrollment, holds: FollowUpHoldsStub())
    }

    private func model(
        _ flow: Flow,
        offersPasswords: Bool = true,
        start: SiteSignInModel.Start? = nil,
        offerTimeout: Duration = SiteSignInModel.standardOfferTimeout
    ) -> SiteSignInModel {
        SiteSignInModel(
            host: "example.com",
            record: nil,
            start: start ?? .opensPage(loginURL),
            proposalID: nil,
            needsPerson: false,
            offersPasswords: offersPasswords,
            followUps: flow.holds,
            offerTimeout: offerTimeout
        )
    }

    private func username(_ value: String, path: String = "/login", passwordFields: Int = 1) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "username", "value": value, "name": "username", "id": "user", "autocomplete": "username",
            "type": "text", "path": path, "actionHost": "example.com", "passwordFields": passwordFields,
        ]))
    }

    private func password(_ value: String, path: String = "/login", newPassword: Bool = false) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "password", "value": value, "name": "password", "id": "pass",
            "autocomplete": "current-password", "type": "password", "path": path, "actionHost": "example.com",
            "newPassword": newPassword,
        ]))
    }

    /// Puts each value in the field with its id, reports the credentials, and submits the first
    /// form, then waits for the browser to reach `arrival`.
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
            flow.enrollment.browser.noteCredential(credential)
        }
        _ = try await flow.enrollment.browser.run("HTMLFormElement.prototype.requestSubmit.call(document.forms[0]);")
        try await waitFor { flow.enrollment.browser.currentURL?.path == arrival && !flow.enrollment.browser.webView.isLoading }
        await flow.enrollment.idle()
    }

    /// Signs in on the one-page form by hand, reporting both values.
    private func signInByHand(_ flow: Flow, newPassword: Bool = false) async throws {
        try await type(
            ["user": flow.bank.username, "pass": flow.bank.password],
            reporting: [try username(flow.bank.username), try password(flow.bank.password, newPassword: newPassword)],
            in: flow,
            arrivingAt: "/home"
        )
        #expect(flow.bank.signedIn)
    }

    /// After the session is kept and the password too: the bank signs out, and a run's open signs
    /// in by itself with one POST of `expectedFields` to the form's address.
    private func expectSignsInByItself(_ flow: Flow, posting expectedFields: [String: String]) async throws {
        flow.bank.signOut()
        flow.bank.site.forgetRequests()
        defer { flow.center.access.end(visit: "run") }

        let opened = await flow.center.access.open(siteID: "example.com", visit: "run")

        guard case let .success(page) = opened else {
            Issue.record("the site was not opened: \(opened)")
            return
        }
        #expect(page.title == "Account")
        #expect(flow.bank.signedIn)
        let posts = flow.bank.site.posts.filter { $0.path == "/session" }
        #expect(posts.count == 1)
        for (name, value) in expectedFields {
            #expect(posts.first?.fields[name] == value, "\(name)")
        }
        #expect(flow.center.sites.first?.needsPerson == false)
    }

    // MARK: End to end

    @Test("A one-page sign-in by hand is saved as a session, then kept as a password the app signs in with", .timeLimit(.minutes(1)))
    func onePage() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        #expect(model.recordsCredentials)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(model.panel == .offer(siteName: "example.com", username: flow.bank.username, host: "example.com"))
        #expect(!model.canPressDone)
        let session = try #require(flow.center.storedGrant(for: "example.com"))
        #expect(!session.remembersPassword)
        #expect(flow.center.sites.first?.keepsSessionOnly == true)

        let grant = try flow.enrollment.passwordGrant(upgrading: session)
        #expect(grant.remembersPassword)
        #expect(grant.username == flow.bank.username)
        #expect(grant.password == flow.bank.password)
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        #expect(grant.signInSteps.allSatisfy { $0.origin == "https://example.com" && $0.path == "/login" })
        #expect(grant.signInSteps.last?.field == FieldKey(name: "password", id: "pass", autocomplete: "current-password", type: "password"))
        #expect(grant.fillHosts == ["example.com"])
        #expect(grant.browseHosts == session.browseHosts)
        #expect(grant.signInURL == session.signInURL)
        #expect(grant.startURL == session.startURL)
        #expect(grant.codeKind == .none && grant.authenticatorKey == nil)
        #expect(grant.isValid(for: "example.com"))

        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .kept)
        #expect(flow.center.storedGrant(for: "example.com") == grant)
        #expect(flow.center.sites.first?.keepsSessionOnly == false)

        try await expectSignsInByItself(flow, posting: ["username": flow.bank.username, "password": flow.bank.password])
    }

    @Test("A two-step sign-in keeps the user name of the first page and the password of the second", .timeLimit(.minutes(1)))
    func twoStep() async throws {
        let flow = try flow { $0.flow = .twoStep }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(
            ["user": flow.bank.username],
            reporting: [try username(flow.bank.username, passwordFields: 0)],
            in: flow,
            arrivingAt: "/password"
        )
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password, path: "/password")],
            in: flow,
            arrivingAt: "/home"
        )

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        let session = try #require(flow.center.storedGrant(for: "example.com"))
        let grant = try flow.enrollment.passwordGrant(upgrading: session)
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        #expect(grant.signInSteps.map(\.path) == ["/login", "/password"])
        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .kept)

        try await expectSignsInByItself(flow, posting: ["password": flow.bank.password])
        #expect(flow.bank.site.posts.filter { $0.path == "/identify" }.first?.fields["username"] == flow.bank.username)
    }

    @Test("A site that fills in the user name itself is kept with the password alone, and signs in with it", .timeLimit(.minutes(1)))
    func prefilledUsername() async throws {
        let flow = try flow { $0.prefillsUsername = true }
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(
            ["pass": flow.bank.password],
            reporting: [try password(flow.bank.password)],
            in: flow,
            arrivingAt: "/home"
        )

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(model.panel == .offer(siteName: "example.com", username: nil, host: "example.com"))
        let session = try #require(flow.center.storedGrant(for: "example.com"))
        let grant = try flow.enrollment.passwordGrant(upgrading: session)
        #expect(grant.username.isEmpty)
        #expect(grant.signInSteps.map(\.kind) == [.password])
        #expect(grant.isValid(for: "example.com"))
        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .kept)

        try await expectSignsInByItself(flow, posting: ["username": flow.bank.username, "password": flow.bank.password])
    }

    // MARK: The enrollment's guards

    @Test("A password grant is built only on the session the save returned, and not once the enrollment ends", .timeLimit(.minutes(1)))
    func passwordGrantGuards() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        let session = try #require(flow.center.storedGrant(for: "example.com"))

        let other = SiteGrant(
            username: "",
            password: "",
            authenticatorKey: nil,
            signInURL: session.signInURL,
            startURL: URL(string: "https://example.com/elsewhere")!,
            fillHosts: session.fillHosts,
            browseHosts: session.browseHosts,
            codeKind: .none,
            codeSender: nil,
            remembersPassword: false
        )
        #expect(throws: SiteEnrollment.Failure.invalidGrant) { try flow.enrollment.passwordGrant(upgrading: other) }

        flow.enrollment.cancel()
        #expect(flow.enrollment.passwordOffer == nil)
        #expect(flow.enrollment.offerRefusal == nil)
        #expect(throws: SiteEnrollment.Failure.cancelled) { try flow.enrollment.passwordGrant(upgrading: session) }
    }

    @Test("An enrollment that records nothing never has an offer, whatever is reported to its browser", .timeLimit(.minutes(1)))
    func nonRecordingEnrollment() async throws {
        let flow = try flow(recording: false)
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        #expect(!flow.enrollment.recordsCredentials)
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
        #expect(model.panel == nil)
        #expect(flow.enrollment.passwordOffer == nil)
        #expect(flow.enrollment.offerRefusal == nil)
        #expect(flow.holds.taken == 0)
    }

    // MARK: The window's model

    @Test("A window that may not record never asks the recording factory and never shows a panel", .timeLimit(.minutes(1)))
    func recordingOff() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        #expect(SiteSignInModel.recordsCredentials(start: .opensPage(loginURL), offersPasswords: true))
        #expect(!SiteSignInModel.recordsCredentials(start: .opensPage(loginURL), offersPasswords: false))
        #expect(!SiteSignInModel.recordsCredentials(start: .asksForAddress(host: "example.com"), offersPasswords: true))
        #expect(!SiteSignInModel.recordsCredentials(start: .asksForAddress(host: "example.com"), offersPasswords: false))

        let settingOff = model(flow, offersPasswords: false)
        let typedAddress = model(flow, start: .asksForAddress(host: "example.com"))
        let on = model(flow)
        for (model, records) in [(settingOff, false), (typedAddress, false), (on, true)] {
            let enrollment = ProVisorSiteWindow.signInEnrollment(for: model, center: flow.center)
            #expect(enrollment.recordsCredentials == records)
            enrollment.cancel()
        }

        // A model that may not record shows no panel even on an enrollment that recorded.
        await settingOff.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)
        #expect(await settingOff.done(using: flow.enrollment, into: flow.center) == .saved)
        #expect(settingOff.panel == nil)
        #expect(flow.holds.taken == 0)
    }

    @Test("Nothing typed: Done saves the session and closes, with no panel and no hold", .timeLimit(.minutes(1)))
    func nothingTypedCloses() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await type(
            ["user": flow.bank.username, "pass": flow.bank.password],
            reporting: [],
            in: flow,
            arrivingAt: "/home"
        )

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)
        #expect(model.panel == nil)
        #expect(flow.enrollment.offerRefusal == nil)
        #expect(flow.holds.taken == 0)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("A refusal shows its sentence, holds no follow-up pass, and keeps nothing of what was typed", .timeLimit(.minutes(1)))
    func refusalPanel() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow, newPassword: true)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(model.panel == .refused(.newPasswordForm))
        #expect(flow.holds.taken == 0)
        #expect(flow.enrollment.offerRefusal == nil)
        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .notKept)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("The setting turned off before Done closes the window as when nothing was typed, and forgets the offer", .timeLimit(.minutes(1)))
    func settingOffBeforeThePanel() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        #expect(model.recordsCredentials)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)

        flow.fixture.settings.provisorOffersPasswords = false
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .saved)

        #expect(model.panel == nil)
        #expect(flow.enrollment.passwordOffer == nil)
        #expect(flow.enrollment.offerRefusal == nil)
        #expect(flow.holds.taken == 0)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("An offer left unanswered ends as Session Only: the enrollment ends, the offer is forgotten, the hold lifted", .timeLimit(.minutes(1)))
    func unansweredOfferExpires() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow, offerTimeout: .milliseconds(200))
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(flow.holds.isHeld)

        try await waitFor { flow.enrollment.isCancelled }

        #expect(flow.enrollment.passwordOffer == nil)
        #expect(!flow.holds.isHeld)
        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .notKept)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("An offer answered in time is not ended later by its expiry", .timeLimit(.minutes(1)))
    func answeredOfferDoesNotExpire() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow, offerTimeout: .milliseconds(300))
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)

        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .kept)
        try await Task.sleep(for: .milliseconds(600))

        // Keep Password closes the window, which is what ends the enrollment; the expiry did not.
        #expect(!flow.enrollment.isCancelled)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == true)
    }

    @Test("An enrollment freed without being cancelled still ends, so no hold is left standing", .timeLimit(.minutes(1)))
    func freedEnrollmentEnds() async throws {
        let holds = FollowUpHoldsStub()
        var ended = 0
        var enrollment: SiteEnrollment? = SiteEnrollment.recordingCredentials(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: { _ in nil },
            settling: .fast
        )
        let token = holds.holdFollowUps()
        enrollment?.whenEnded {
            ended += 1
            holds.releaseFollowUps(token)
        }
        weak let freed = enrollment
        #expect(holds.isHeld)

        enrollment = nil
        try await waitFor { freed == nil && ended > 0 }

        #expect(freed == nil)
        #expect(ended == 1)
        #expect(!holds.isHeld)
    }

    @Test("Session Only ends the enrollment: the session stays, what was typed is forgotten, and the hold is lifted", .timeLimit(.minutes(1)))
    func sessionOnly() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(flow.holds.isHeld)
        #expect(flow.enrollment.passwordOffer != nil)

        // Session Only, Close, Cancel, and the close button all close the window, which cancels.
        flow.enrollment.cancel()

        #expect(flow.enrollment.passwordOffer == nil)
        #expect(!flow.holds.isHeld)
        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .notKept)
        let grant = try #require(flow.center.storedGrant(for: "example.com"))
        #expect(!grant.remembersPassword)
        #expect(grant.password.isEmpty)
    }

    @Test("Keep Password stores the password grant, and the second save owes no second pass", .timeLimit(.minutes(1)))
    func keepPasswordOwesOnePass() async throws {
        let flow = try flow()
        let directory = try requestFolder()
        defer {
            withExtendedLifetime(flow) { flow.enrollment.cancel() }
            try? FileManager.default.removeItem(at: directory)
        }
        var effects: [SignInDemand.SaveEffect] = []
        var settled: [SiteRequests.Outcome] = []
        flow.center.onSiteSaved = { record, wasAwaited in
            let effect = SignInDemand.effectOfSaving(
                record.id,
                proposals: ProposalStore.load(from: directory),
                now: Date(),
                wasAwaited: wasAwaited
            )
            effects.append(effect)
            if let proposalID = effect.settles {
                settled.append(SiteRequests.settle(
                    proposalID: proposalID,
                    host: record.id,
                    savedSiteID: record.id,
                    siteName: record.name,
                    in: directory,
                    isBusy: false
                ))
            }
        }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .kept)

        #expect(effects.map(\.owesPass) == [true, false])
        #expect(effects.last?.settles == nil)
        #expect(settled == [.settled])
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == true)
        // The window closes on Keep Password, which ends the enrollment and lifts the hold.
        #expect(flow.holds.isHeld)
        flow.enrollment.cancel()
        #expect(!flow.holds.isHeld)
    }

    @Test("A Keep Password whose save fails keeps the panel and the session, and can be tried again", .timeLimit(.minutes(1)), .enabled(if: getuid() != 0))
    func failedKeepKeepsThePanel() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)
        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        let panel = model.panel

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: flow.fixture.directory.path)
        let first = model.keepPassword(using: flow.enrollment, into: flow.center)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: flow.fixture.directory.path)

        #expect(first == .notKept)
        #expect(model.problem == .notSaved)
        #expect(model.panel == panel)
        #expect(flow.holds.isHeld)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == false)

        #expect(model.keepPassword(using: flow.enrollment, into: flow.center) == .kept)
        #expect(model.problem == nil)
        #expect(flow.center.storedGrant(for: "example.com")?.remembersPassword == true)
    }

    @Test("A Done whose save fails takes no hold that outlives it", .timeLimit(.minutes(1)), .enabled(if: getuid() != 0))
    func failedDoneReleasesTheHold() async throws {
        let flow = try flow()
        defer { withExtendedLifetime(flow) { flow.enrollment.cancel() } }
        let model = model(flow)
        await model.beginIfTrusted(using: flow.enrollment)
        try await signInByHand(flow)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: flow.fixture.directory.path)
        let first = await model.done(using: flow.enrollment, into: flow.center)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: flow.fixture.directory.path)

        #expect(first == .notSaved)
        #expect(model.panel == nil)
        #expect(flow.holds.taken == 1)
        #expect(!flow.holds.isHeld)

        #expect(await model.done(using: flow.enrollment, into: flow.center) == .savedAndAsking)
        #expect(flow.holds.isHeld)
    }

    // MARK: Helpers

    /// A proposals folder holding one open request for example.com.
    private func requestFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("password-keeping-request-\(UUID().uuidString)", isDirectory: true)
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

    /// Waits up to five seconds for `condition`.
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
}
