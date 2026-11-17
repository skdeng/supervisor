import Foundation
import Security
import Testing
import WebKit

@testable import SuperVisor

/// A clock a test moves by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { instant } }

    func advance(days: Int) {
        lock.withLock { instant = instant.addingTimeInterval(TimeInterval(days) * 86_400) }
    }
}

private let usernameField = FieldKey(name: "username", id: "user", autocomplete: "username", type: "text")
private let passwordField = FieldKey(name: "password", id: "pass", autocomplete: "current-password", type: "password")
private let codeField = FieldKey(name: "otp", id: "otp", autocomplete: "one-time-code", type: "text")

@Suite("Site access", .serialized)
@MainActor
struct SiteAccessTests {
    /// A site access over a fake bank, an in-memory vault, and a registry file of its own.
    @MainActor
    private final class Fixture {
        let bank = TestBank()
        let store = InMemorySecretStore()
        let clock = TestClock()
        let directory: URL
        let registry: URL
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let stub: CodeStub
        let access: SiteAccess
        var vault: SiteVault { SiteVault(store: store) }

        let codeKind: SiteGrant.CodeKind
        let signOutControlSeen: Bool

        init(
            granted: Bool = true,
            steps: Bool = true,
            codeKind: SiteGrant.CodeKind = .none,
            signOutControlSeen: Bool = false,
            stub: CodeStub = CodeStub(),
            codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit,
            configure: (TestBank) -> Void = { _ in }
        ) throws {
            self.codeKind = codeKind
            self.signOutControlSeen = signOutControlSeen
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("site-access-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            registry = directory.appendingPathComponent("sites.json")
            self.stub = stub
            configure(bank)
            let clock = self.clock
            access = SiteAccess(
                vault: SiteVault(store: store),
                registryURL: registry,
                codes: stub.codes,
                dataStore: dataStore,
                simulatedPages: bank.site.answer,
                settling: .fast,
                codeWaitLimit: codeWaitLimit,
                now: { clock.now }
            )
            if granted { try grant() }
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func grant(steps: Bool = true, host: String = "example.com") throws {
            try access.add(grant: makeGrant(steps: steps), record: record(host))
        }

        func makeGrant(steps: Bool = true) -> SiteGrant {
            SiteGrant(
                username: bank.username,
                password: bank.password,
                authenticatorKey: codeKind == .authenticator ? CodeStub.sampleKey : nil,
                signInURL: URL(string: "https://example.com/login")!,
                startURL: URL(string: "https://example.com/account")!,
                fillHosts: ["example.com"],
                browseHosts: ["example.com"],
                codeKind: codeKind,
                codeSender: codeKind == .text ? "24273" : nil,
                signInSteps: steps
                    ? [
                        SignInStep(kind: .username, origin: "https://example.com", path: "/login", field: usernameField),
                        SignInStep(kind: .password, origin: "https://example.com", path: "/login", field: passwordField),
                    ] + (codeKind == .none ? [] : [
                        SignInStep(kind: .code, origin: "https://example.com", path: "/verify", field: codeField),
                    ])
                    : [],
                signOutControlSeen: signOutControlSeen
            )
        }

        func record(_ host: String = "example.com") -> SiteRecord {
            SiteRecord(id: host, name: "Bank", added: clock.now)
        }

        var stored: SiteRecord? {
            access.sites().first { $0.id == "example.com" }
        }
    }

    private func page(_ result: Result<PageSnapshot, SiteAccess.Failure>) -> PageSnapshot? {
        if case let .success(page) = result { return page }
        return nil
    }

    private func failure(_ result: Result<PageSnapshot, SiteAccess.Failure>) -> SiteAccess.Failure? {
        if case let .failure(failure) = result { return failure }
        return nil
    }

    // MARK: Opening

    @Test("Opening a site that is signed in returns its start page with no sign-in attempt", .timeLimit(.minutes(1)))
    func openSignedIn() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        defer { fixture.access.end(visit: "run") }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        let opened = try #require(page(result))
        #expect(opened.title == "Account")
        #expect(opened.text.contains("Amex ending 1001"))
        #expect(opened.links.map(\.text) == ["Cards", "Statements"])
        #expect(fixture.bank.site.posts.isEmpty)
        #expect(fixture.bank.site.requests.map(\.path) == ["/account"])
        #expect(fixture.stored?.attemptCount == 0)
        #expect(fixture.stored?.attemptsDay == nil)
        #expect(fixture.access.currentPage(visit: "run") == opened)
    }

    @Test("A signed-out site signs in with its recorded steps, and the attempt is recorded", .timeLimit(.minutes(1)))
    func openSignedOut() async throws {
        let fixture = try Fixture()
        defer { fixture.access.end(visit: "run") }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        let opened = try #require(page(result))
        #expect(opened.title == "Account")
        #expect(fixture.bank.signedIn)
        #expect(fixture.bank.site.posts.count == 1)
        #expect(fixture.bank.site.posts.first?.fields == [
            "username": fixture.bank.username, "password": fixture.bank.password,
        ])
        let record = try #require(fixture.stored)
        #expect(record.attemptCount == 1)
        #expect(record.attemptsDay == SignInAttempts.day(of: fixture.clock.now, in: .current))
        #expect(record.lastSignedIn == fixture.clock.now)
        #expect(!record.needsPerson)
    }

    @Test("A failed sign-in sets needsPerson, and the next open answers it without loading anything", .timeLimit(.minutes(1)))
    func failureStopsTheApp() async throws {
        let fixture = try Fixture { $0.neverSignsIn = true }
        defer { fixture.access.end(visit: "run") }

        let first = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(first) == .needsPerson)
        #expect(fixture.stored?.needsPerson == true)
        #expect(fixture.stored?.attemptCount == 1)
        #expect(fixture.bank.site.posts.count == 1)
        #expect(fixture.access.currentPage(visit: "run") == nil)

        fixture.bank.site.forgetRequests()
        let second = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(second) == .needsPerson)
        #expect(fixture.bank.site.requests.isEmpty)
        #expect(fixture.stored?.attemptCount == 1)

        // The person signing in again, which is what adding the site records, ends it.
        fixture.bank.neverSignsIn = false
        try fixture.grant()
        #expect(fixture.stored?.needsPerson == false)
        #expect(fixture.stored?.attemptCount == 0)
        let third = await fixture.access.open(siteID: "example.com", visit: "run")
        #expect(page(third)?.title == "Account")
    }

    @Test("A site recorded with no steps needs a person as soon as the session ends", .timeLimit(.minutes(1)))
    func noRecordedSteps() async throws {
        let fixture = try Fixture(granted: false)
        try fixture.access.add(grant: fixture.makeGrant(steps: false), record: fixture.record())
        defer { fixture.access.end(visit: "run") }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(result) == .needsPerson)
        #expect(fixture.bank.site.posts.isEmpty)
        #expect(fixture.stored?.needsPerson == true)
    }

    @Test("Three sign-ins are allowed a day and the fourth is refused until the next day", .timeLimit(.minutes(2)))
    func fourthAttemptRefused() async throws {
        let fixture = try Fixture()
        defer { fixture.access.end(visit: "run") }

        for _ in 1...3 {
            fixture.bank.signOut()
            let result = await fixture.access.open(siteID: "example.com", visit: "run")
            #expect(page(result)?.title == "Account")
        }
        #expect(fixture.bank.site.posts.count == 3)
        #expect(fixture.stored?.attemptCount == 3)

        fixture.bank.signOut()
        let refused = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(refused) == .needsPerson)
        #expect(fixture.bank.site.posts.count == 3)
        // Running out of attempts is no failure of the site.
        #expect(fixture.stored?.needsPerson == false)

        // A session that is still good is read even with no attempts left.
        fixture.bank.markSignedIn()
        #expect(page(await fixture.access.open(siteID: "example.com", visit: "run"))?.title == "Account")

        fixture.clock.advance(days: 1)
        fixture.bank.signOut()
        let next = await fixture.access.open(siteID: "example.com", visit: "run")
        #expect(page(next)?.title == "Account")
        #expect(fixture.bank.site.posts.count == 4)
        #expect(fixture.stored?.attemptCount == 1)
    }

    @Test("Two visits opening the same signed-out site cause one sign-in", .timeLimit(.minutes(1)))
    func oneSignInForTwoVisits() async throws {
        let fixture = try Fixture()
        defer {
            fixture.access.end(visit: "a")
            fixture.access.end(visit: "b")
        }

        async let first = fixture.access.open(siteID: "example.com", visit: "a")
        async let second = fixture.access.open(siteID: "example.com", visit: "b")
        let results = await [first, second]

        #expect(results.compactMap(page).map(\.title) == ["Account", "Account"])
        #expect(fixture.bank.site.posts.count == 1)
        #expect(fixture.stored?.attemptCount == 1)
        #expect(fixture.access.currentPage(visit: "a")?.title == "Account")
        #expect(fixture.access.currentPage(visit: "b")?.title == "Account")
    }

    @Test("A site that sends the browser off its hosts needs a person, and no attempt is counted", .timeLimit(.minutes(1)))
    func startPageLeavesTheSite() async throws {
        let fixture = try Fixture()
        fixture.bank.site.route("/account", page: TestPages.redirect(to: "https://evil.test/landing"))
        defer { fixture.access.end(visit: "run") }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(result) == .needsPerson)
        #expect(fixture.stored?.attemptCount == 0)
        #expect(fixture.stored?.needsPerson == false)
        #expect(!fixture.bank.site.requests.contains { $0.host == "evil.test" })
    }

    @Test("A site that cannot be reached is unavailable, and no attempt is counted", .timeLimit(.minutes(1)))
    func startPageUnavailable() async throws {
        let fixture = try Fixture()
        fixture.bank.site.route("/account", page: TestPages.redirect(to: "/gone"))
        defer { fixture.access.end(visit: "run") }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(result) == .unavailable)
        #expect(fixture.stored?.attemptCount == 0)
        #expect(fixture.stored?.needsPerson == false)
    }

    @Test("A site that is not granted is unknown, whatever the reason", .timeLimit(.minutes(1)))
    func unknownSite() async throws {
        let fixture = try Fixture()
        defer { fixture.access.end(visit: "run") }

        #expect(failure(await fixture.access.open(siteID: "other.example.org", visit: "run")) == .unknownSite)
        #expect(failure(await fixture.access.open(siteID: "Not A Host", visit: "run")) == .unknownSite)
        #expect(failure(await fixture.access.open(siteID: "", visit: "run")) == .unknownSite)

        // A registry entry without a grant, and a grant without a registry entry.
        try SiteRegistry.save(
            fixture.access.sites() + [SiteRecord(id: "nogrant.example.org", name: "No grant", added: fixture.clock.now)],
            to: fixture.registry
        )
        #expect(failure(await fixture.access.open(siteID: "nogrant.example.org", visit: "run")) == .unknownSite)
        try fixture.vault.save(
            SiteGrant(
                username: "u",
                password: "p",
                authenticatorKey: nil,
                signInURL: URL(string: "https://norecord.example.org/login")!,
                startURL: URL(string: "https://norecord.example.org/")!,
                fillHosts: ["norecord.example.org"],
                browseHosts: ["norecord.example.org"],
                codeKind: .none,
                codeSender: nil
            ),
            for: "norecord.example.org"
        )
        #expect(failure(await fixture.access.open(siteID: "norecord.example.org", visit: "run")) == .unknownSite)
        #expect(fixture.bank.site.requests.isEmpty)
    }

    @Test("A failed open leaves the visit with no page to follow links from", .timeLimit(.minutes(1)))
    func failedOpenDropsThePage() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        defer { fixture.access.end(visit: "run") }
        #expect(page(await fixture.access.open(siteID: "example.com", visit: "run")) != nil)
        #expect(fixture.access.currentPage(visit: "run") != nil)

        fixture.bank.site.route("/account", page: TestPages.redirect(to: "/gone"))
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "run")) == .unavailable)

        #expect(fixture.access.currentPage(visit: "run") == nil)
        #expect(failure(await fixture.access.follow(link: 1, visit: "run")) == .nothingOpen)
    }

    @Test("A vault that cannot be read is unavailable, not an unknown site", .timeLimit(.minutes(1)))
    func vaultFailure() async throws {
        struct Broken: SecretStore {
            func read(account: String) throws -> Data? { throw KeychainError(status: errSecInteractionNotAllowed) }
            func write(_ data: Data, account: String) throws {}
            func delete(account: String) throws {}
        }
        let fixture = try Fixture()
        let access = SiteAccess(
            vault: SiteVault(store: Broken()),
            registryURL: fixture.registry,
            codes: fixture.stub.codes,
            dataStore: fixture.dataStore,
            simulatedPages: fixture.bank.site.answer,
            settling: .fast
        )
        defer { access.end(visit: "run") }

        #expect(failure(await access.open(siteID: "example.com", visit: "run")) == .unavailable)
        #expect(fixture.bank.site.requests.isEmpty)
    }

    @Test("A visit has an id, and only a few can be open at once", .timeLimit(.minutes(2)))
    func visitLimits() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        defer { (0..<SiteAccess.maximumVisits).forEach { fixture.access.end(visit: "v\($0)") } }

        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "")) == .unavailable)
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: String(repeating: "v", count: 129))) == .unavailable)
        for index in 0..<SiteAccess.maximumVisits {
            #expect(page(await fixture.access.open(siteID: "example.com", visit: "v\(index)")) != nil)
        }
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "extra")) == .unavailable)

        fixture.access.end(visit: "v0")
        #expect(page(await fixture.access.open(siteID: "example.com", visit: "extra")) != nil)
        fixture.access.end(visit: "extra")
    }

    @Test("Opening another site closes the first on the same visit", .timeLimit(.minutes(1)))
    func switchingSites() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        fixture.bank.site.route("/start", host: "other.example.org", page: TestPages.page("Other", "<p>other site</p>"))
        let other = SiteGrant(
            username: "u",
            password: "p",
            authenticatorKey: nil,
            signInURL: URL(string: "https://other.example.org/login")!,
            startURL: URL(string: "https://other.example.org/start")!,
            fillHosts: ["other.example.org"],
            browseHosts: ["other.example.org"],
            codeKind: .none,
            codeSender: nil
        )
        try fixture.access.add(grant: other, record: SiteRecord(id: "other.example.org", name: "Other", added: fixture.clock.now))
        defer { fixture.access.end(visit: "run") }

        #expect(page(await fixture.access.open(siteID: "example.com", visit: "run"))?.title == "Account")
        #expect(page(await fixture.access.open(siteID: "other.example.org", visit: "run"))?.title == "Other")
        #expect(fixture.access.currentPage(visit: "run")?.title == "Other")
        // The page of the first site is not one the visit can follow a link from.
        #expect(failure(await fixture.access.follow(link: 3, visit: "run")) == .noSuchLink)
    }

    // MARK: Bookkeeping

    /// Waits, a few milliseconds at a time, until `condition` holds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("A failure that may not repeat counts an attempt and leaves the site open to another", .timeLimit(.minutes(2)))
    func transientFailureDoesNotFlag() async throws {
        let fixture = try Fixture(codeKind: .authenticator, stub: CodeStub(authenticator: nil)) { $0.requiresCode = true }
        defer { fixture.access.end(visit: "run") }

        let first = await fixture.access.open(siteID: "example.com", visit: "run")

        // No code could be had: the password went in, the code did not, and nobody is needed.
        #expect(failure(first) == .unavailable)
        #expect(fixture.stored?.needsPerson == false)
        #expect(fixture.stored?.attemptCount == 1)
        #expect(fixture.bank.site.posts.map(\.path) == ["/session"])

        fixture.bank.signOut()
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "run")) == .unavailable)
        #expect(fixture.stored?.attemptCount == 2)
        fixture.bank.signOut()
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "run")) == .unavailable)

        // Three a day, flagged or not.
        fixture.bank.signOut()
        #expect(fixture.stored?.attemptCount == 3)
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "run")) == .needsPerson)
        #expect(fixture.stored?.attemptCount == 3)
        #expect(fixture.stored?.needsPerson == false)
        #expect(fixture.bank.site.posts.count == 3)
    }

    @Test("An attempt is counted before the sign-in starts, and a registry that cannot be written means no sign-in", .timeLimit(.minutes(1)))
    func unwritableRegistryFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.access.end(visit: "run") }
        let path = fixture.directory.path
        #expect(chmod(path, 0o500) == 0)
        defer { chmod(path, 0o700) }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(result) == .unavailable)
        #expect(fixture.bank.site.posts.isEmpty)
        #expect(!fixture.bank.signedIn)
        #expect(fixture.stored?.attemptCount == 0)
        #expect(fixture.stored?.needsPerson == false)

        // With the registry writable again the same open signs in and counts the attempt.
        chmod(path, 0o700)
        #expect(page(await fixture.access.open(siteID: "example.com", visit: "run"))?.title == "Account")
        #expect(fixture.stored?.attemptCount == 1)
    }

    @Test("The attempt is in the registry while the sign-in runs, ahead of its outcome", .timeLimit(.minutes(1)))
    func attemptIsCountedFirst() async throws {
        let gate = TestGate()
        let fixture = try Fixture(codeKind: .text, stub: CodeStub(textedGate: gate)) { $0.requiresCode = true }
        defer { fixture.access.end(visit: "run") }
        let signedInBefore = try #require(fixture.stored?.lastSignedIn)
        fixture.clock.advance(days: 1)

        let opening = Task { @MainActor in await fixture.access.open(siteID: "example.com", visit: "run") }
        try await waitUntil { fixture.stub.calls.contains { $0.hasPrefix("texted") } }

        #expect(fixture.stored?.attemptCount == 1)
        #expect(fixture.stored?.attemptsDay == SignInAttempts.day(of: fixture.clock.now, in: .current))
        #expect(fixture.stored?.needsPerson == false)
        #expect(fixture.stored?.lastSignedIn == signedInBefore)

        await gate.open()
        #expect(page(await opening.value)?.title == "Account")
        #expect(fixture.stored?.attemptCount == 1)
        #expect(fixture.stored?.lastSignedIn == fixture.clock.now)
    }

    @Test("A sign-in cut short by the visit ending submits nothing more, counts no attempt, and flags nothing", .timeLimit(.minutes(1)))
    func endingTheVisitInterrupts() async throws {
        let gate = TestGate()
        let fixture = try Fixture(codeKind: .text, stub: CodeStub(textedGate: gate)) { $0.requiresCode = true }
        let opening = Task { @MainActor in await fixture.access.open(siteID: "example.com", visit: "run") }
        try await waitUntil { fixture.stub.calls.contains { $0.hasPrefix("texted") } }
        #expect(fixture.stored?.attemptCount == 1)

        fixture.access.end(visit: "run")
        await gate.open()
        let result = await opening.value

        #expect(failure(result) == .unavailable)
        #expect(fixture.bank.site.posts.map(\.path) == ["/session"])
        #expect(!fixture.bank.signedIn)
        #expect(fixture.stored?.attemptCount == 0)
        #expect(fixture.stored?.attemptsDay == nil)
        #expect(fixture.stored?.needsPerson == false)
        #expect(fixture.access.currentPage(visit: "run") == nil)
    }

    @Test("Adding the site again while a sign-in runs cuts it off and leaves the new record clean", .timeLimit(.minutes(1)))
    func addingDuringASignInLeavesTheNewRecordClean() async throws {
        let gate = TestGate()
        let fixture = try Fixture(codeKind: .text, stub: CodeStub(textedGate: gate)) { $0.requiresCode = true }
        // An earlier attempt today, so that taking the cut-short one back would show.
        fixture.bank.requiresCode = false
        defer { fixture.access.end(visit: "run") }
        #expect(page(await fixture.access.open(siteID: "example.com", visit: "earlier")) != nil)
        fixture.access.end(visit: "earlier")
        #expect(fixture.stored?.attemptCount == 1)
        fixture.bank.requiresCode = true
        fixture.bank.signOut()

        let opening = Task { @MainActor in await fixture.access.open(siteID: "example.com", visit: "run") }
        try await waitUntil { fixture.stub.calls.contains { $0.hasPrefix("texted") } }
        #expect(fixture.stored?.attemptCount == 2)

        try fixture.grant()
        await gate.open()
        let result = await opening.value

        #expect(failure(result) == .unavailable)
        let record = try #require(fixture.stored)
        #expect(record.attemptCount == 0)
        #expect(record.attemptsDay == nil)
        #expect(!record.needsPerson)
        #expect(record.lastSignedIn == fixture.clock.now)
        #expect(fixture.bank.site.posts.map(\.path) == ["/session", "/session"])
        #expect(!fixture.bank.signedIn)
    }

    @Test("Removing the site while a sign-in runs cuts it off and brings nothing back", .timeLimit(.minutes(1)))
    func removingDuringASignIn() async throws {
        let gate = TestGate()
        let fixture = try Fixture(codeKind: .text, stub: CodeStub(textedGate: gate)) { $0.requiresCode = true }
        let opening = Task { @MainActor in await fixture.access.open(siteID: "example.com", visit: "run") }
        try await waitUntil { fixture.stub.calls.contains { $0.hasPrefix("texted") } }

        try await fixture.access.remove(siteID: "example.com")
        await gate.open()
        let result = await opening.value

        #expect(failure(result) == .unavailable)
        #expect(fixture.access.sites().isEmpty)
        #expect(fixture.store.accounts.isEmpty)
        #expect(fixture.bank.site.posts.map(\.path) == ["/session"])
        fixture.access.end(visit: "run")
    }

    @Test("A code source that never answers does not hold the sign-in past the limit", .timeLimit(.minutes(1)))
    func codeWaitDoesNotHoldTheGate() async throws {
        let fixture = try Fixture(
            codeKind: .text,
            stub: CodeStub(hangs: true),
            codeWaitLimit: .milliseconds(200)
        ) { $0.requiresCode = true }
        defer {
            fixture.access.end(visit: "a")
            fixture.access.end(visit: "b")
        }

        async let first = fixture.access.open(siteID: "example.com", visit: "a")
        async let second = fixture.access.open(siteID: "example.com", visit: "b")
        let results = await [first, second]

        #expect(results.compactMap(failure) == [.unavailable, .unavailable])
        #expect(fixture.stored?.needsPerson == false)
        #expect(fixture.stored?.attemptCount == 2)
    }

    // MARK: Signed in

    @Test("A public start page is signed in unless a sign-out control was seen at enrollment", .timeLimit(.minutes(1)))
    func publicStartPage() async throws {
        let lenient = try Fixture { $0.startPageIsPublic = true }
        defer { lenient.access.end(visit: "run") }
        let welcome = page(await lenient.access.open(siteID: "example.com", visit: "run"))
        #expect(welcome?.title == "Welcome")
        #expect(lenient.bank.site.posts.isEmpty)
        #expect(lenient.stored?.attemptCount == 0)

        let strict = try Fixture(signOutControlSeen: true) { $0.startPageIsPublic = true }
        defer { strict.access.end(visit: "strict") }
        let refused = await strict.access.open(siteID: "example.com", visit: "strict")
        #expect(failure(refused) == .needsPerson)
        #expect(strict.bank.site.posts.isEmpty)
        #expect(strict.stored?.needsPerson == true)

        // Signed in, the same page shows the control, and is read.
        let signedIn = try Fixture(signOutControlSeen: true) { $0.startPageIsPublic = true }
        defer { signedIn.access.end(visit: "signedIn") }
        signedIn.bank.markSignedIn()
        #expect(page(await signedIn.access.open(siteID: "example.com", visit: "signedIn"))?.title == "Account")
    }

    @Test("A start page that moves to another path once signed in is not one a session shows", .timeLimit(.minutes(1)))
    func startPageMovesAway() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        fixture.bank.site.route("/account", page: TestPages.redirect(to: "/home"))
        defer { fixture.access.end(visit: "run") }

        let result = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(failure(result) == .needsPerson)
        #expect(fixture.stored?.needsPerson == true)
    }

    @Test("An unknown site takes no visit slot", .timeLimit(.minutes(2)))
    func unknownSiteTakesNoSlot() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        defer { fixture.access.end(visit: "real") }

        for index in 0..<(SiteAccess.maximumVisits + 3) {
            #expect(failure(await fixture.access.open(siteID: "nope.example.org", visit: "v\(index)")) == .unknownSite)
            #expect(failure(await fixture.access.open(siteID: "Not A Host", visit: "w\(index)")) == .unknownSite)
        }

        #expect(page(await fixture.access.open(siteID: "example.com", visit: "real")) != nil)
    }

    // MARK: Following

    @Test("A link is followed by its number, and a number that is not a link is refused", .timeLimit(.minutes(1)))
    func followByNumber() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        defer { fixture.access.end(visit: "run") }
        _ = await fixture.access.open(siteID: "example.com", visit: "run")

        let cards = await fixture.access.follow(link: 1, visit: "run")

        #expect(page(cards)?.title == "Cards")
        #expect(fixture.access.currentPage(visit: "run")?.title == "Cards")

        // Numbers count from the page last read, which is now the cards page.
        #expect(page(await fixture.access.follow(link: 1, visit: "run"))?.title == "Account")
        #expect(failure(await fixture.access.follow(link: 3, visit: "run")) == .noSuchLink)
        #expect(failure(await fixture.access.follow(link: 0, visit: "run")) == .noSuchLink)
        #expect(failure(await fixture.access.follow(link: -1, visit: "run")) == .noSuchLink)
        #expect(failure(await fixture.access.follow(link: Int.max, visit: "run")) == .noSuchLink)
        #expect(failure(await fixture.access.follow(link: Int.min, visit: "run")) == .noSuchLink)
        #expect(fixture.access.currentPage(visit: "run")?.title == "Account")
    }

    @Test("Nothing can be followed before something is open", .timeLimit(.minutes(1)))
    func followNothingOpen() async throws {
        let fixture = try Fixture { $0.neverSignsIn = true }
        defer { fixture.access.end(visit: "run") }

        #expect(failure(await fixture.access.follow(link: 1, visit: "never-used")) == .nothingOpen)
        _ = await fixture.access.open(siteID: "example.com", visit: "run")
        #expect(failure(await fixture.access.follow(link: 1, visit: "run")) == .nothingOpen)
        #expect(fixture.access.currentPage(visit: "never-used") == nil)

        fixture.access.end(visit: "run")
        #expect(failure(await fixture.access.follow(link: 1, visit: "run")) == .nothingOpen)
    }

    @Test("A visit may follow twelve links", .timeLimit(.minutes(3)))
    func linkLimit() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        fixture.bank.site.route("/cards", page: TestPages.page("Cards", "<a href=\"/cards\">Cards</a>"))
        defer {
            fixture.access.end(visit: "run")
            fixture.access.end(visit: "other")
        }
        _ = await fixture.access.open(siteID: "example.com", visit: "run")

        for _ in 1...SiteAccess.linksPerVisit {
            #expect(page(await fixture.access.follow(link: 1, visit: "run"))?.title == "Cards")
        }
        #expect(failure(await fixture.access.follow(link: 1, visit: "run")) == .tooManyLinks)

        // Opening the site again does not give the visit more.
        _ = await fixture.access.open(siteID: "example.com", visit: "run")
        #expect(failure(await fixture.access.follow(link: 1, visit: "run")) == .tooManyLinks)

        // Another visit has its own count.
        _ = await fixture.access.open(siteID: "example.com", visit: "other")
        #expect(page(await fixture.access.follow(link: 1, visit: "other"))?.title == "Cards")
    }

    @Test("Following a link never submits a form or fills a password field, even on a page that asks for one", .timeLimit(.minutes(1)))
    func followNeverSubmits() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        fixture.bank.site.route("/statements", page: TestPages.page("Statements", """
            <form method="post" action="/transfer"><button type="submit">Go</button></form>
            <a href="/recheck">Recheck</a>
            """))
        fixture.bank.site.route("/recheck", page: TestPages.page("Recheck", """
            <form method="post" action="/confirm"><input type="password" name="password" id="again" autocomplete="current-password">
            <button type="submit">Continue</button></form>
            """))
        defer { fixture.access.end(visit: "run") }
        _ = await fixture.access.open(siteID: "example.com", visit: "run")

        #expect(page(await fixture.access.follow(link: 2, visit: "run"))?.title == "Statements")
        let recheck = page(await fixture.access.follow(link: 1, visit: "run"))

        #expect(recheck?.title == "Recheck")
        #expect(fixture.bank.site.posts.isEmpty)
        #expect(fixture.stored?.attemptCount == 0)
    }

    @Test("A followed link that leaves the site's hosts is refused", .timeLimit(.minutes(1)))
    func followLeavingTheSite() async throws {
        let fixture = try Fixture()
        fixture.bank.markSignedIn()
        fixture.bank.site.route("/statements", page: TestPages.page("Statements", "<a href=\"/hop\">Next</a>"))
        fixture.bank.site.route("/hop", page: TestPages.redirect(to: "https://evil.test/x"))
        defer { fixture.access.end(visit: "run") }
        _ = await fixture.access.open(siteID: "example.com", visit: "run")
        _ = await fixture.access.follow(link: 2, visit: "run")

        let result = await fixture.access.follow(link: 1, visit: "run")

        #expect(failure(result) == .noSuchLink)
        #expect(!fixture.bank.site.requests.contains { $0.host == "evil.test" })
    }

    // MARK: Sites

    @Test("A site is added to the vault and the registry, replacing an earlier entry", .timeLimit(.minutes(1)))
    func addAndReplace() throws {
        let fixture = try Fixture(granted: false)
        #expect(fixture.access.sites().isEmpty)

        try fixture.grant()
        #expect(fixture.access.sites().map(\.id) == ["example.com"])
        #expect(try fixture.vault.grant(for: "example.com") == fixture.makeGrant())

        var renamed = fixture.record()
        renamed.name = "Renamed"
        try fixture.access.add(grant: fixture.makeGrant(steps: false), record: renamed)
        #expect(fixture.access.sites().map(\.name) == ["Renamed"])
        #expect(try fixture.vault.grant(for: "example.com")?.signInSteps.isEmpty == true)
        #expect(fixture.store.accounts == ["example.com"])
    }

    @Test("An invalid grant or record is refused and stores nothing", .timeLimit(.minutes(1)))
    func addRefusesInvalid() throws {
        let fixture = try Fixture(granted: false)
        var bad = fixture.record()
        bad.name = "  "

        #expect(throws: SiteVault.Failure.invalidGrant) {
            try fixture.access.add(grant: fixture.makeGrant(), record: bad)
        }
        #expect(throws: SiteVault.Failure.invalidGrant) {
            try fixture.access.add(grant: fixture.makeGrant(), record: fixture.record("other.example.org"))
        }

        #expect(fixture.store.accounts.isEmpty)
        #expect(fixture.access.sites().isEmpty)
    }

    @Test("When the registry cannot be written the vault is put back as it was", .timeLimit(.minutes(1)))
    func addRollsBack() throws {
        let fixture = try Fixture()
        let earlier = try #require(try fixture.vault.grant(for: "example.com"))
        let blocked = fixture.directory.appendingPathComponent("file")
        try Data("x".utf8).write(to: blocked)
        let broken = SiteAccess(
            vault: fixture.vault,
            registryURL: blocked.appendingPathComponent("sites.json"),
            codes: fixture.stub.codes,
            dataStore: fixture.dataStore,
            simulatedPages: fixture.bank.site.answer,
            settling: .fast
        )

        #expect(throws: (any Error).self) {
            try broken.add(grant: fixture.makeGrant(steps: false), record: fixture.record())
        }
        #expect(try fixture.vault.grant(for: "example.com") == earlier)

        let other = SiteGrant(
            username: "u",
            password: "p",
            authenticatorKey: nil,
            signInURL: URL(string: "https://fresh.example.org/login")!,
            startURL: URL(string: "https://fresh.example.org/")!,
            fillHosts: ["fresh.example.org"],
            browseHosts: ["fresh.example.org"],
            codeKind: .none,
            codeSender: nil
        )
        #expect(throws: (any Error).self) {
            try broken.add(grant: other, record: SiteRecord(id: "fresh.example.org", name: "Fresh", added: fixture.clock.now))
        }
        #expect(try fixture.vault.grant(for: "fresh.example.org") == nil)
    }

    @Test("Removing a site deletes its Keychain item, its registry entry, and its cookies, and nothing else", .timeLimit(.minutes(1)))
    func removeDeletesEverything() async throws {
        let fixture = try Fixture()
        let other = SiteGrant(
            username: "u",
            password: "p",
            authenticatorKey: nil,
            signInURL: URL(string: "https://keep.example.net/login")!,
            startURL: URL(string: "https://keep.example.net/")!,
            fillHosts: ["keep.example.net"],
            browseHosts: ["keep.example.net"],
            codeKind: .none,
            codeSender: nil
        )
        try fixture.access.add(grant: other, record: SiteRecord(id: "keep.example.net", name: "Keep", added: fixture.clock.now))
        fixture.bank.markSignedIn()
        _ = await fixture.access.open(siteID: "example.com", visit: "run")

        let cookies = fixture.dataStore.httpCookieStore
        for domain in ["example.com", "www.example.com", "keep.example.net"] {
            let cookie = try #require(HTTPCookie(properties: [
                .name: "session", .value: "x", .domain: domain, .path: "/", .secure: true,
            ]))
            await cookies.setCookie(cookie)
        }
        #expect(await cookies.allCookies().count == 3)

        try await fixture.access.remove(siteID: "example.com")

        #expect(fixture.store.accounts == ["keep.example.net"])
        #expect(fixture.access.sites().map(\.id) == ["keep.example.net"])
        #expect(try fixture.vault.grant(for: "example.com") == nil)
        #expect(await cookies.allCookies().map(\.domain) == ["keep.example.net"])
        #expect(fixture.access.currentPage(visit: "run") == nil)
        #expect(failure(await fixture.access.open(siteID: "example.com", visit: "run")) == .unknownSite)

        // Removing it again, or a site that was never added, is not an error.
        try await fixture.access.remove(siteID: "example.com")
        await #expect(throws: SiteVault.Failure.invalidSite) {
            try await fixture.access.remove(siteID: "Not A Host")
        }
        fixture.access.end(visit: "run")
    }

    @Test("Removing a site leaves the cookies and data that another granted site shares", .timeLimit(.minutes(1)))
    func removeKeepsWhatASiteSharesWithAnother() async throws {
        let fixture = try Fixture(granted: false)
        func grant(_ host: String) -> SiteGrant {
            SiteGrant(
                username: "u",
                password: "p",
                authenticatorKey: nil,
                signInURL: URL(string: "https://\(host)/login")!,
                startURL: URL(string: "https://\(host)/")!,
                fillHosts: [host],
                browseHosts: [host],
                codeKind: .none,
                codeSender: nil
            )
        }
        try fixture.access.add(grant: grant("a.example.org"), record: SiteRecord(id: "a.example.org", name: "A", added: fixture.clock.now))
        try fixture.access.add(grant: grant("b.example.org"), record: SiteRecord(id: "b.example.org", name: "B", added: fixture.clock.now))
        try fixture.access.add(grant: grant("c.example.net"), record: SiteRecord(id: "c.example.net", name: "C", added: fixture.clock.now))

        let cookies = fixture.dataStore.httpCookieStore
        for domain in [".example.org", "a.example.org", "b.example.org", "c.example.net"] {
            let cookie = try #require(HTTPCookie(properties: [
                .name: "session", .value: "x", .domain: domain, .path: "/", .secure: true,
            ]))
            await cookies.setCookie(cookie)
        }
        #expect(await cookies.allCookies().count == 4)

        try await fixture.access.remove(siteID: "a.example.org")

        // The cookie of the shared parent domain stays for b, whose own and c's stay as well.
        #expect(Set(await cookies.allCookies().map(\.domain)) == [".example.org", "b.example.org", "c.example.net"])
        #expect(fixture.access.sites().map(\.id).sorted() == ["b.example.org", "c.example.net"])

        // With b gone too, nothing keeps the shared one.
        try await fixture.access.remove(siteID: "b.example.org")
        #expect(Set(await cookies.allCookies().map(\.domain)) == ["c.example.net"])
    }

    @Test("The registry file is read and written by the access alone, and keeps each site's own record", .timeLimit(.minutes(1)))
    func registryUpdatesAreWholeRecords() async throws {
        let fixture = try Fixture()
        let other = SiteGrant(
            username: "u",
            password: "p",
            authenticatorKey: nil,
            signInURL: URL(string: "https://second.example.net/login")!,
            startURL: URL(string: "https://second.example.net/")!,
            fillHosts: ["second.example.net"],
            browseHosts: ["second.example.net"],
            codeKind: .none,
            codeSender: nil
        )
        try fixture.access.add(grant: other, record: SiteRecord(id: "second.example.net", name: "Second", added: fixture.clock.now))
        defer { fixture.access.end(visit: "run") }

        _ = await fixture.access.open(siteID: "example.com", visit: "run")

        let records = Dictionary(uniqueKeysWithValues: fixture.access.sites().map { ($0.id, $0) })
        #expect(records["example.com"]?.attemptCount == 1)
        #expect(records["second.example.net"]?.attemptCount == 0)
        #expect(records["second.example.net"]?.name == "Second")
    }
}
