import Foundation
import Testing
import WebKit

@testable import SuperVisor

@Suite("Site sign-in window", .serialized)
@MainActor
struct SiteSignInModelTests {
    private typealias Start = SiteSignInModel.Start

    private let added = Date(timeIntervalSince1970: 1_700_000_000)
    private let loginURL = URL(string: "https://example.com/login")!

    private func record(_ id: String = "example.com", name: String = "Bank", needsPerson: Bool = false) -> SiteRecord {
        var record = SiteRecord(id: id, name: name, added: added, lastSignedIn: added, needsPerson: needsPerson)
        record.keepsSessionOnly = true
        return record
    }

    private func sessionGrant() -> SiteGrant {
        SiteGrant(
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
    }

    // MARK: Where the window starts

    @Test("A granted site opens its saved sign-in address without reading the history")
    func startGranted() {
        var asked = 0
        let start = Start.decide(host: "example.com", record: record(), grant: sessionGrant()) { _ in
            asked += 1
            return false
        }
        #expect(start == .opensPage(loginURL))
        #expect(asked == 0)
    }

    @Test("A granted site with no readable grant never opens a page by itself, and one with a saved password fills it")
    func startUntrustedGrant() {
        var asked = 0
        let visited: (String) -> Bool = { _ in
            asked += 1
            return true
        }
        #expect(Start.decide(host: "example.com", record: record(), grant: nil, hasVisited: visited)
            == .asksForAddress(host: "example.com"))
        var password = sessionGrant()
        password = SiteGrant(
            username: "alice@example.com",
            password: "saved-password",
            authenticatorKey: nil,
            signInURL: loginURL,
            startURL: password.startURL,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil
        )
        #expect(Start.decide(host: "example.com", record: record(), grant: password, hasVisited: visited)
            == .fillsSavedPassword(password))
        // The grant alone decides: a request for a host that is not granted never fills.
        #expect(Start.decide(host: "example.com", record: nil, grant: password) { _ in false }
            == .asksForAddress(host: "example.com"))
        #expect(asked == 0)
    }

    @Test("A window started for a granted site with no readable grant loads nothing", .timeLimit(.minutes(1)))
    func untrustedGrantLoadsNothing() async throws {
        let (fixture, _, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = SiteSignInModel(
            host: "example.com",
            record: record(),
            start: Start.decide(host: "example.com", record: record(), grant: nil) { _ in true },
            proposalID: "p",
            needsPerson: true,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )

        await model.beginIfTrusted(using: enrollment)
        await model.retry(using: enrollment)

        #expect(!model.hasOpenedPage)
        #expect(model.address.isEmpty)
        #expect(bank.site.requests.isEmpty)
        #expect(enrollment.currentHost == nil)
    }

    @Test("A requested host the history recognises opens at that host and nowhere else")
    func startRecognised() {
        var asked: [String] = []
        let start = Start.decide(host: "example.com", record: nil, grant: nil) { host in
            asked.append(host)
            return true
        }
        #expect(start == .opensPage(URL(string: "https://example.com")!))
        #expect(asked == ["example.com"])
    }

    @Test("A requested host the history does not recognise asks for the address")
    func startUnrecognised() {
        let start = Start.decide(host: "examp1e-login.com", record: nil, grant: nil) { _ in false }
        #expect(start == .asksForAddress(host: "examp1e-login.com"))
    }

    @Test("A requested host that is not a host name asks for the address without reading the history")
    func startInvalidHost() {
        var asked = 0
        for host in ["https://example.com/login", "example.com:8443", "", "exa mple.com"] {
            let start = Start.decide(host: host, record: nil, grant: nil) { _ in
                asked += 1
                return true
            }
            #expect(start == .asksForAddress(host: host))
        }
        #expect(asked == 0)
    }

    // MARK: What the window says

    @Test("A granted site is named; the sentence says it signed the person out, or that ProVisor asked")
    func grantedSentences() {
        let signedOut = SiteSignInModel(
            host: "example.com",
            record: record(),
            start: .opensPage(loginURL),
            proposalID: "p",
            needsPerson: true,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        #expect(signedOut.title == "Sign in to Bank")
        #expect(signedOut.sentence == "Bank needs you to sign in again.")
        #expect(!signedOut.sentenceIsCaution)
        #expect(!signedOut.asksForAddress)

        let asked = SiteSignInModel(host: "example.com", record: record(), start: .opensPage(loginURL), proposalID: "p", needsPerson: false, offersPasswords: false, followUps: FollowUpHoldsStub())
        #expect(asked.sentence == "ProVisor asked you to sign in to Bank again.")

        let own = SiteSignInModel(host: "example.com", record: record(), start: .opensPage(loginURL), proposalID: nil, needsPerson: false, offersPasswords: false, followUps: FollowUpHoldsStub())
        #expect(own.sentence == nil)
    }

    @Test("A recognised request names its host and says it matched the history")
    func recognisedSentence() {
        let model = SiteSignInModel(
            host: "example.com",
            record: nil,
            start: .opensPage(URL(string: "https://example.com")!),
            proposalID: "2026-11-17-check",
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        #expect(model.title == "Sign in to example.com")
        #expect(model.sentence == "ProVisor asked for this site. It matches a site in your browser history.")
        #expect(!model.sentenceIsCaution)
        #expect(model.proposalID == "2026-11-17-check")
    }

    @Test("An unrecognised request names its host only in a cautioning sentence, and the address field starts empty")
    func unrecognisedSentence() {
        let model = SiteSignInModel(
            host: "examp1e-login.com",
            record: nil,
            start: .asksForAddress(host: "examp1e-login.com"),
            proposalID: "2026-11-17-check",
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        #expect(model.title == "Sign in")
        #expect(model.sentence == "ProVisor asked for examp1e-login.com. SuperVisor hasn't seen that address in your browser history, so type the site's address yourself.")
        #expect(model.sentenceIsCaution)
        #expect(model.asksForAddress)
        #expect(model.address.isEmpty)
        #expect(!model.canOpenTypedAddress)
        #expect(!model.canPressDone)
    }

    // MARK: Signing in

    /// `seesVisitors` gives the enrollment the bank's visitor site, so a page that shows no
    /// sign-out control is also loaded as a visitor would load it.
    private func flow(
        seesVisitors: Bool = false,
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
            settling: .fast,
            visitorPages: seesVisitors ? bank.visitorPages : nil,
            visitorRecheckDelay: .milliseconds(50)
        )
        return (fixture, center, bank, enrollment)
    }

    /// A model for a new site whose page opens at `url` by itself.
    private func trusted(_ url: URL, proposalID: String? = "2026-11-17-check") -> SiteSignInModel {
        SiteSignInModel(
            host: url.host(percentEncoded: false) ?? "",
            record: nil,
            start: .opensPage(url),
            proposalID: proposalID,
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
    }

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

    @Test("A trusted start opens the page by itself, and Done is pressable before the sign-in", .timeLimit(.minutes(1)))
    func trustedStartOpens() async throws {
        let (fixture, _, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(loginURL)
        #expect(!model.canPressDone)

        await model.beginIfTrusted(using: enrollment)

        #expect(model.hasOpenedPage)
        #expect(model.problem == nil)
        #expect(model.canPressDone)
        #expect(enrollment.currentHost == "example.com")
        #expect(bank.site.requests(to: "/login").count == 1)
        #expect(bank.site.posts.isEmpty)

        // A second call opens nothing more.
        await model.beginIfTrusted(using: enrollment)
        #expect(bank.site.requests(to: "/login").count == 1)
    }

    @Test("An unrecognised request opens nothing by itself, and opens only the address the person typed", .timeLimit(.minutes(1)))
    func unrecognisedOpensOnlyTheTypedAddress() async throws {
        let (fixture, _, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = SiteSignInModel(
            host: "examp1e-login.com",
            record: nil,
            start: .asksForAddress(host: "examp1e-login.com"),
            proposalID: "p",
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )

        await model.beginIfTrusted(using: enrollment)
        #expect(!model.hasOpenedPage)
        #expect(bank.site.requests.isEmpty)
        #expect(enrollment.currentHost == nil)

        model.address = "http://example.com/login"
        #expect(!model.canOpenTypedAddress)
        #expect(model.addressProblem == SiteSaveProblem.invalidAddress.message)
        await model.openTypedAddress(using: enrollment)
        #expect(bank.site.requests.isEmpty)

        model.address = "example.com/login"
        #expect(model.addressProblem == nil)
        #expect(model.canOpenTypedAddress)
        await model.openTypedAddress(using: enrollment)

        #expect(model.hasOpenedPage)
        #expect(bank.site.requests.map(\.host) == ["example.com"])
        #expect(bank.site.requests(to: "/login").count == 1)
        #expect(enrollment.currentHost == "example.com")
    }

    @Test("Done after a sign-in by hand saves a kept session and reports it saved", .timeLimit(.minutes(1)))
    func doneSavesKeptSession() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        var heard: [(String, Bool)] = []
        center.onSiteSaved = { record, wasAwaited in heard.append((record.id, wasAwaited)) }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .saved)

        #expect(model.problem == nil)
        #expect(heard.map(\.0) == ["example.com"])
        let site = try #require(center.sites.first)
        #expect(site.name == "example.com")
        #expect(site.keepsSessionOnly)
        let grant = try #require(center.storedGrant(for: "example.com"))
        #expect(!grant.remembersPassword)
        #expect(grant.password.isEmpty && grant.username.isEmpty)
        #expect(grant.signInURL == loginURL)
        #expect(bank.site.posts.count == 1)
    }

    @Test("Done on a page that still asks for a sign-in refuses and stores nothing", .timeLimit(.minutes(1)))
    func doneBeforeSignIn() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)

        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .notSignedIn)
        #expect(model.problem?.signInWindowMessage == "Finish signing in on the page first, then press Done.")
        #expect(!model.offersSaveAnyway)
        #expect(model.canPressDone)
        #expect(center.sites.isEmpty)
    }

    @Test("Done with no sign-in seen refuses and offers Save Anyway, which saves", .timeLimit(.minutes(1)))
    func doneWithNoSignInSeen() async throws {
        let (fixture, center, bank, enrollment) = try flow { $0.startPageIsPublic = true }
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(URL(string: "https://example.com/account")!)
        await model.beginIfTrusted(using: enrollment)

        // An answer given before the question was put counts for nothing.
        #expect(await model.done(using: enrollment, into: center, confirmingSignIn: true) == .notSaved)
        #expect(model.problem == .signInNotSeen)
        #expect(model.problem?.signInWindowMessage == "SuperVisor didn't see a sign-in here. If the page shows your account, press Save Anyway. If it doesn't, sign in on the page first.")
        #expect(model.offersSaveAnyway)
        #expect(center.sites.isEmpty)

        // Done asks again; it never stands for the confirmation.
        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.offersSaveAnyway)
        #expect(center.sites.isEmpty)

        #expect(await model.done(using: enrollment, into: center, confirmingSignIn: true) == .saved)
        #expect(model.problem == nil)
        #expect(!model.offersSaveAnyway)
        #expect(try #require(center.sites.first).keepsSessionOnly)
        #expect(center.storedGrant(for: "example.com")?.remembersPassword == false)
    }

    @Test("Done on a page a visitor sees the same way refuses and offers Save Anyway, which saves", .timeLimit(.minutes(1)))
    func donePageLooksPublic() async throws {
        let (fixture, center, bank, enrollment) = try flow(seesVisitors: true) { $0.startPageIsPublic = true }
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(URL(string: "https://example.com/account")!)
        await model.beginIfTrusted(using: enrollment)

        // An answer given before the question was put counts for nothing.
        #expect(await model.done(using: enrollment, into: center, confirmingSignIn: true) == .notSaved)
        #expect(model.problem == .pageLooksPublic)
        #expect(model.problem?.signInWindowMessage == "SuperVisor can't tell this page from what a visitor sees, so it wouldn't notice if the site signed you out. Open a page only you can see, such as your account page, then press Done. Or press Save Anyway.")
        #expect(model.offersSaveAnyway)
        #expect(center.sites.isEmpty)

        // Done asks again; it never stands for the confirmation.
        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.offersSaveAnyway)
        #expect(center.sites.isEmpty)

        #expect(await model.done(using: enrollment, into: center, confirmingSignIn: true) == .saved)
        #expect(model.problem == nil)
        #expect(!model.offersSaveAnyway)
        #expect(try #require(center.sites.first).keepsSessionOnly)
        let grant = try #require(center.storedGrant(for: "example.com"))
        #expect(!grant.remembersPassword)
        #expect(!grant.signInControlAbsent)
    }

    @Test("Save Anyway answers the refusal on screen, so a page that has since come to look the same is refused for that", .timeLimit(.minutes(1)))
    func saveAnywayAnswersTheRefusalShown() async throws {
        @MainActor
        final class VisitorSwitch {
            var answers = false
        }
        let visitor = VisitorSwitch()
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        bank.startPageIsPublic = true
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast,
            visitorPages: { request in visitor.answers ? bank.visitorSite.answer(request) : nil },
            visitorRecheckDelay: .milliseconds(50)
        )
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(URL(string: "https://example.com/account")!)
        await model.beginIfTrusted(using: enrollment)
        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .signInNotSeen)

        visitor.answers = true
        #expect(await model.done(using: enrollment, into: center, confirmingSignIn: true) == .notSaved)
        #expect(model.problem == .pageLooksPublic)
        #expect(model.offersSaveAnyway)
        #expect(center.sites.isEmpty)

        #expect(await model.done(using: enrollment, into: center, confirmingSignIn: true) == .saved)
        #expect(center.sites.count == 1)
    }

    @Test("A page begun afresh while Done reads the page stores nothing, and says nothing", .timeLimit(.minutes(1)))
    func beginDuringDoneStoresNothing() async throws {
        @MainActor
        final class Watch {
            var enrollment: SiteEnrollment?
            var begun: Task<Void, any Error>?
        }
        let watch = Watch()
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let bank = TestBank()
        bank.markSignedIn()
        bank.accountPageShowsSignOutControl = false
        let enrollment = SiteEnrollment(
            dataStore: .nonPersistent(),
            codes: CodeStub().codes,
            simulatedPages: bank.site.answer,
            settling: .fast,
            visitorPages: { request in
                if watch.begun == nil {
                    watch.begun = Task { @MainActor in
                        try await watch.enrollment?.beginKeepingSession(signInAddress: "example.com/home")
                    }
                }
                return bank.visitorSite.answer(request)
            },
            visitorRecheckDelay: .milliseconds(50)
        )
        watch.enrollment = enrollment
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(URL(string: "https://example.com/home")!)
        await model.beginIfTrusted(using: enrollment)

        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == nil)
        #expect(center.sites.isEmpty)
        #expect(fixture.store.accounts.isEmpty)
        try await watch.begun?.value
    }

    @Test("A granted site keeps its name and the date it was added, and stops needing the person", .timeLimit(.minutes(1)))
    func grantedSiteKeepsItsRecord() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        try center.save(grant: sessionGrant(), record: record(name: "My Bank"))
        var stale = try #require(center.sites.first)
        stale.needsPerson = true
        try SiteRegistry.save([stale], to: fixture.registry)
        center.refresh()
        let granted = try #require(center.sites.first)

        let model = SiteSignInModel(
            host: "example.com",
            record: granted,
            start: .decide(host: "example.com", record: granted, grant: center.storedGrant(for: "example.com")) { _ in false },
            proposalID: nil,
            needsPerson: granted.needsPerson,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        #expect(model.sentence == "My Bank needs you to sign in again.")
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .saved)
        let site = try #require(center.sites.first)
        #expect(site.name == "My Bank")
        #expect(site.added == added)
        #expect(!site.needsPerson)
        #expect(site.keepsSessionOnly)
    }

    @Test("Nothing is stored once the enrollment is cancelled", .timeLimit(.minutes(1)))
    func nothingStoredAfterCancel() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer { withExtendedLifetime((fixture, bank)) {} }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)
        enrollment.cancel()

        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(center.sites.isEmpty)
        #expect(fixture.store.accounts.isEmpty)
    }

    @Test("Cancelling while Done is under way stores nothing", .timeLimit(.minutes(1)))
    func cancelDuringDone() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer { withExtendedLifetime((fixture, bank)) {} }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        let saving = Task { @MainActor in await model.done(using: enrollment, into: center) }
        while !model.isWorking {
            await Task.yield()
        }
        enrollment.cancel()

        #expect(await saving.value == .notSaved)
        #expect(center.sites.isEmpty)
        #expect(fixture.store.accounts.isEmpty)
    }

    private func passwordGrant() -> SiteGrant {
        SiteGrant(
            username: "alice@example.com",
            password: "saved-password",
            authenticatorKey: nil,
            signInURL: loginURL,
            startURL: URL(string: "https://example.com/account")!,
            fillHosts: ["example.com"],
            browseHosts: ["example.com"],
            codeKind: .none,
            codeSender: nil
        )
    }

    /// A model that asks for the address, with `address` typed into it.
    private func typed(_ address: String) -> SiteSignInModel {
        let model = SiteSignInModel(
            host: "examp1e-login.com",
            record: nil,
            start: .asksForAddress(host: "examp1e-login.com"),
            proposalID: "p",
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        model.address = address
        return model
    }

    @Test("A save lands on a new site, a kept session, or a saved password, judged by the stored grant first")
    func destinationTable() {
        typealias Destination = SiteSignInModel.Destination
        let session = record()
        var password = record(name: "Club")
        password.keepsSessionOnly = false
        var grants: [String: SiteGrant] = [:]
        func destination(_ sites: [SiteRecord]) -> Destination {
            Destination.of("example.com", sites: sites) { grants[$0] }
        }

        // With no readable grant, the record says how the site is kept.
        #expect(destination([]) == .newSite)
        #expect(destination([record("other.example")]) == .newSite)
        #expect(destination([session]) == .keptSession(session))
        #expect(destination([password]) == .savedPassword)

        // A readable grant overrides what the record says.
        grants["example.com"] = sessionGrant()
        #expect(destination([password]) == .keptSession(password))
        grants["example.com"] = passwordGrant()
        #expect(destination([session]) == .savedPassword)

        // Only the window opened for that same site with a saved password may land on it.
        #expect(Destination.of("example.com", sites: [password], grant: { grants[$0] }, savedPasswordSite: "example.com")
            == .ownSavedPassword(password))
        #expect(Destination.of("example.com", sites: [password], grant: { grants[$0] }, savedPasswordSite: "other.example")
            == .savedPassword)
        grants["example.com"] = nil
        #expect(Destination.of("example.com", sites: [password], grant: { grants[$0] }, savedPasswordSite: "example.com")
            == .savedPassword)
    }

    @Test("Typing the address of a saved-password site and pressing Done stores nothing and keeps the password", .timeLimit(.minutes(1)))
    func doneRefusesASavedPasswordSite() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        try center.save(grant: passwordGrant(), record: SiteRecord(id: "example.com", name: "Club", added: added))
        var saves = 0
        center.onSiteSaved = { _, _ in saves += 1 }
        let model = typed("example.com/login")
        await model.openTypedAddress(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .hasSavedPassword)
        #expect(model.problem?.signInWindowMessage == "This site has a saved password. Use Sign In Again in Settings to sign in to it.")
        #expect(model.canPressDone)
        #expect(saves == 0)
        let grant = try #require(center.storedGrant(for: "example.com"))
        #expect(grant.remembersPassword)
        #expect(grant.password == "saved-password")
        #expect(center.sites.first?.name == "Club")

        // Pressing Done again refuses again.
        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(center.storedGrant(for: "example.com")?.remembersPassword == true)
    }

    @Test("A granted site whose grant cannot be read and whose record does not say it keeps a session is refused", .timeLimit(.minutes(1)))
    func doneRefusesAnUnreadablePasswordSite() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        try SiteRegistry.save([SiteRecord(id: "example.com", name: "Club", added: added)], to: fixture.registry)
        center.refresh()
        let model = typed("example.com/login")
        await model.openTypedAddress(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(model.problem == .hasSavedPassword)
        #expect(center.storedGrant(for: "example.com") == nil)
    }

    @Test("Typing the address of an existing kept-session site keeps its name and the date it was added", .timeLimit(.minutes(1)))
    func typedAddressKeepsAnExistingSite() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        try center.save(grant: sessionGrant(), record: record(name: "My Bank"))
        let model = typed("example.com/login")
        await model.openTypedAddress(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .saved)
        let site = try #require(center.sites.first)
        #expect(center.sites.count == 1)
        #expect(site.name == "My Bank")
        #expect(site.added == added)
        #expect(site.keepsSessionOnly)
    }

    @Test("A page that fails to load reports it and offers a retry, which opens it once the site answers", .timeLimit(.minutes(1)))
    func failedLoadIsRetried() async throws {
        let (fixture, _, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(URL(string: "https://example.com/start")!)

        await model.beginIfTrusted(using: enrollment)
        #expect(model.problem == .pageDidNotLoad)
        #expect(model.problem?.signInWindowMessage == "The page did not finish loading.")
        #expect(model.offersRetry)

        bank.site.route("/start", page: TestPages.redirect(to: "/login"))
        await model.retry(using: enrollment)

        #expect(model.problem == nil)
        #expect(!model.offersRetry)
        #expect(model.hasOpenedPage)
        try await waitFor { enrollment.browser.currentURL?.path == "/login" }
        #expect(bank.site.requests(to: "/start").count == 2)
    }

    @Test("A typed address that fails to load offers no retry; Open Page serves", .timeLimit(.minutes(1)))
    func typedAddressOffersNoRetry() async throws {
        let (fixture, _, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = typed("example.com/start")
        await model.openTypedAddress(using: enrollment)
        #expect(model.problem == .pageDidNotLoad)
        #expect(!model.offersRetry)
        await model.retry(using: enrollment)
        #expect(bank.site.requests(to: "/start").count == 1)
        #expect(model.canOpenTypedAddress)
    }

    @Test("A Keychain save that fails is tried again with the kept result", .timeLimit(.minutes(1)), .enabled(if: getuid() != 0))
    func failedSaveIsRetried() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        let first = await model.done(using: enrollment, into: center)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        #expect(first == .notSaved)
        #expect(model.problem == .notSaved)
        #expect(model.canPressDone)
        #expect(center.sites.isEmpty)

        // The enrollment has handed over its grant, so only the kept result can make this save.
        await #expect(throws: SiteEnrollment.Failure.notSignedIn) {
            _ = try await enrollment.finishKeepingSession(name: "Bank")
        }
        #expect(await model.done(using: enrollment, into: center) == .saved)
        #expect(center.sites.map(\.id) == ["example.com"])
        #expect(model.problem == nil)
    }

    @Test("Two Done presses in a row store one grant", .timeLimit(.minutes(1)))
    func twoDonePressesStoreOne() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
        }
        var saves = 0
        center.onSiteSaved = { _, _ in saves += 1 }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        let first = Task { @MainActor in await model.done(using: enrollment, into: center) }
        while !model.isWorking {
            await Task.yield()
        }
        #expect(!model.canPressDone)
        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(await first.value == .saved)
        #expect(await model.done(using: enrollment, into: center) == .notSaved)

        #expect(saves == 1)
        #expect(center.sites.count == 1)
        #expect(fixture.store.accounts.count == 1)
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

    // MARK: Requests

    /// A proposals folder holding one open request for example.com.
    private func requestFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-sign-in-request-\(UUID().uuidString)", isDirectory: true)
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

    /// What ProVisor does with a save the center reports: settle the earliest open request for
    /// the saved site (`SignInDemand.effectOfSaving`, `SiteRequests.settle`).
    private func settleOnSave(
        _ center: SiteAccessCenter,
        in directory: URL,
        outcomes: @escaping (SiteRequests.Outcome) -> Void
    ) {
        center.onSiteSaved = { record, wasAwaited in
            let effect = SignInDemand.effectOfSaving(
                record.id,
                proposals: ProposalStore.load(from: directory),
                now: Date(),
                wasAwaited: wasAwaited
            )
            guard let proposalID = effect.settles else { return }
            outcomes(SiteRequests.settle(
                proposalID: proposalID,
                host: record.id,
                savedSiteID: record.id,
                siteName: record.name,
                in: directory,
                isBusy: false
            ))
        }
    }

    @Test("Done settles no request by itself", .timeLimit(.minutes(1)))
    func doneSettlesNothingItself() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        let directory = try requestFolder()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
            try? FileManager.default.removeItem(at: directory)
        }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .saved)
        #expect(ProposalStore.load(from: directory).first?.status == .proposed)
    }

    @Test("Closing a requested sign-in window without saving stores nothing and leaves the request open", .timeLimit(.minutes(1)))
    func requestCancelReportsNothing() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        let directory = try requestFolder()
        defer {
            withExtendedLifetime((fixture, bank)) {}
            try? FileManager.default.removeItem(at: directory)
        }
        var outcomes: [SiteRequests.Outcome] = []
        var saves = 0
        settleOnSave(center, in: directory) { outcomes.append($0) }
        let settle = center.onSiteSaved
        center.onSiteSaved = { record, wasAwaited in
            saves += 1
            settle?(record, wasAwaited)
        }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)
        enrollment.cancel()

        #expect(await model.done(using: enrollment, into: center) == .notSaved)
        #expect(saves == 0)
        #expect(outcomes.isEmpty)
        #expect(center.sites.isEmpty)
        #expect(ProposalStore.load(from: directory).first?.status == .proposed)
    }

    @Test("Saving the requested site through the center settles the request on disk", .timeLimit(.minutes(1)))
    func requestSettledOnSave() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        let directory = try requestFolder()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
            try? FileManager.default.removeItem(at: directory)
        }
        var outcomes: [SiteRequests.Outcome] = []
        settleOnSave(center, in: directory) { outcomes.append($0) }
        let model = trusted(loginURL)
        await model.beginIfTrusted(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .saved)
        #expect(outcomes == [.settled])
        let proposal = try #require(ProposalStore.load(from: directory).first)
        #expect(proposal.status == .done)
        #expect(proposal.result == "Signed in to example.com.")
    }

    @Test("A site saved under another host than the one requested leaves the request open", .timeLimit(.minutes(1)))
    func requestNotSettledForAnotherHost() async throws {
        let (fixture, center, bank, enrollment) = try flow()
        bank.site.route("/login", host: "login.example.com", page: TestPages.redirect(to: "https://example.com/login"))
        let directory = try requestFolder()
        defer {
            enrollment.cancel()
            withExtendedLifetime((fixture, bank)) {}
            try? FileManager.default.removeItem(at: directory)
        }
        var outcomes: [SiteRequests.Outcome] = []
        settleOnSave(center, in: directory) { outcomes.append($0) }
        let model = SiteSignInModel(
            host: "example.com",
            record: nil,
            start: .asksForAddress(host: "example.com"),
            proposalID: "2026-11-17-check",
            needsPerson: false,
            offersPasswords: false,
            followUps: FollowUpHoldsStub()
        )
        model.address = "login.example.com/login"
        await model.openTypedAddress(using: enrollment)
        try await signInOnPage(enrollment, bank)

        #expect(await model.done(using: enrollment, into: center) == .saved)
        #expect(center.sites.map(\.id) == ["login.example.com"])
        #expect(outcomes.isEmpty)
        #expect(ProposalStore.load(from: directory).first?.status == .proposed)
    }
}
