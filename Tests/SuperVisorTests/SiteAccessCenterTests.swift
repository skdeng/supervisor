import Combine
import Foundation
import SQLite3
import Testing
import WebKit

@testable import SuperVisor

/// A scratch directory holding a registry path and, when asked, a Messages database with the
/// tables the store reads.
@MainActor
final class SiteCenterFixture {
    let directory: URL
    let registry: URL
    let databasePath: String
    let store = InMemorySecretStore()
    let defaultsName = "site-access-center-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: SettingsStore

    init(database makesDatabase: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-access-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry = directory.appendingPathComponent("sites.json")
        databasePath = directory.appendingPathComponent("chat.db").path
        defaults = UserDefaults(suiteName: defaultsName)!
        settings = SettingsStore(defaults: defaults)
        if makesDatabase {
            try exec("""
                CREATE TABLE handle (ROWID INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL);
                CREATE TABLE message (
                    ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
                    text TEXT,
                    attributedBody BLOB,
                    date INTEGER,
                    is_from_me INTEGER DEFAULT 0,
                    handle_id INTEGER DEFAULT 0
                );
                INSERT INTO handle (id) VALUES ('24273');
                INSERT INTO message (text, date, handle_id) VALUES ('Lunch at noon?', 1, 1);
                """)
        }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: directory)
    }

    enum FixtureError: Error { case sqlite }

    /// Runs `sql` on a connection of its own, closed before returning, as another app writing
    /// to the database would.
    func exec(_ sql: String) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
        else { throw FixtureError.sqlite }
    }

    /// Adds a text from the one handle, `24273`.
    func receive(_ text: String) throws {
        try exec("INSERT INTO message (text, date, handle_id) VALUES ('\(text)', 2, 1)")
    }

    var messages: MessagesStore { MessagesStore(path: databasePath) }

    func center(
        polling: SiteAccessCenter.CodePolling = .standard,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> SiteAccessCenter {
        SiteAccessCenter(
            secretStore: store,
            registryURL: registry,
            messages: messages,
            settings: settings,
            dataStore: .nonPersistent(),
            codePolling: polling,
            simulatedPages: simulatedPages,
            settling: settling,
            now: now
        )
    }

    func codes(
        textsOn: Bool,
        relay: EmailedCodeRelay = EmailedCodeRelay(),
        polling: SiteAccessCenter.CodePolling = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> SignInCodes {
        SiteAccessCenter.makeCodes(
            messages: messages,
            textsSwitch: TextsSwitch(isOn: textsOn),
            relay: relay,
            polling: polling,
            now: now
        )
    }
}

private func grant(_ host: String = "example.com", password: String = "pw-\(UUID().uuidString)") -> SiteGrant {
    SiteGrant(
        username: "alice@example.com",
        password: password,
        authenticatorKey: nil,
        signInURL: URL(string: "https://\(host)/login")!,
        startURL: URL(string: "https://\(host)/account")!,
        fillHosts: [host],
        browseHosts: [host],
        codeKind: .none,
        codeSender: nil
    )
}

private func record(_ host: String = "example.com", name: String = "Bank") -> SiteRecord {
    SiteRecord(id: host, name: name, added: Date(timeIntervalSince1970: 1_700_000_000))
}

/// A grant that keeps a signed-in session and no password.
private func sessionGrant(_ host: String = "example.com") -> SiteGrant {
    SiteGrant(
        username: "",
        password: "",
        authenticatorKey: nil,
        signInURL: URL(string: "https://\(host)/login")!,
        startURL: URL(string: "https://\(host)/account")!,
        fillHosts: [host],
        browseHosts: [host],
        codeKind: .none,
        codeSender: nil,
        signOutControlSeen: true,
        remembersPassword: false
    )
}

/// What `SiteAccessCenter.onSiteSaved` was called with, in order.
@MainActor
private final class SaveLog {
    struct Entry: Equatable {
        let siteID: String
        let wasAwaited: Bool
    }

    private(set) var entries: [Entry] = []

    func record(_ record: SiteRecord, _ wasAwaited: Bool) {
        entries.append(Entry(siteID: record.id, wasAwaited: wasAwaited))
    }
}

/// Polls quickly, for tests that wait for a code to arrive.
private let quickPolling = SiteAccessCenter.CodePolling(interval: .milliseconds(20), limit: .seconds(5))

@Suite("Site access center", .serialized)
@MainActor
struct SiteAccessCenterTests {
    // MARK: Sites

    @Test("The site list follows the registry through save and remove")
    func listFollowsSaveAndRemove() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        center.refresh()
        #expect(center.sites.isEmpty)

        try center.save(grant: grant(), record: record())
        try center.save(grant: grant("other.example.org"), record: record("other.example.org", name: "Other"))
        #expect(center.sites.map(\.id) == ["example.com", "other.example.org"])
        #expect(center.sites.first?.lastSignedIn != nil)
        #expect(SiteRegistry.load(from: fixture.registry).map(\.id) == center.sites.map(\.id))

        try await center.remove("example.com")
        #expect(center.sites.map(\.id) == ["other.example.org"])
        #expect(fixture.store.accounts == ["other.example.org"])
    }

    @Test(
        "A removal whose registry write fails throws, keeps the row, and the next try finishes it",
        .enabled(if: getuid() != 0)
    )
    func partialRemovalCanBeRetried() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())

        // A directory that cannot be written to refuses the registry's replacement file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        await #expect(throws: (any Error).self) { try await center.remove("example.com") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)

        #expect(fixture.store.accounts.isEmpty)
        #expect(center.sites.map(\.id) == ["example.com"])

        try await center.remove("example.com")
        #expect(center.sites.isEmpty)
        #expect(SiteRegistry.load(from: fixture.registry).isEmpty)
    }

    @Test("A grant that cannot be stored throws and leaves the list as it was")
    func invalidSaveThrows() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        #expect(throws: SiteVault.Failure.invalidGrant) {
            try center.save(grant: grant("example.com"), record: record("other.example.org"))
        }
        #expect(center.sites.isEmpty)
        #expect(fixture.store.accounts.isEmpty)
    }

    @Test("The stored grant is the one saved, and none for a site never saved")
    func storedGrant() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        let saved = grant()
        try center.save(grant: saved, record: record())

        #expect(center.storedGrant(for: "example.com") == saved)
        #expect(center.storedGrant(for: "other.example.org") == nil)
        #expect(center.storedGrant(for: "not a host") == nil)
    }

    @Test("A site's status: needs you, then signed in, then not signed in yet")
    func siteStatus() {
        var site = record()
        #expect(SiteAccessCenter.SiteStatus(site, awaiting: []) == .notSignedInYet)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        site.lastSignedIn = date
        #expect(SiteAccessCenter.SiteStatus(site, awaiting: []) == .signedIn(date))
        site.needsPerson = true
        #expect(SiteAccessCenter.SiteStatus(site, awaiting: []) == .needsYou)
    }

    @Test("A site kept by its session reads as signed in that way, and needs you once its session ends")
    func sessionSiteStatus() {
        var site = record()
        site.keepsSessionOnly = true
        #expect(SiteAccessCenter.SiteStatus(site, awaiting: []) == .notSignedInYet)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        site.lastSignedIn = date
        #expect(SiteAccessCenter.SiteStatus(site, awaiting: []) == .signedInKeepingSession(date))
        site.needsPerson = true
        #expect(SiteAccessCenter.SiteStatus(site, awaiting: []) == .needsYou)
    }

    // MARK: Waiting on the person

    @Test("A run turned away from a site leaves it flagged, awaiting the person, and in the list", .timeLimit(.minutes(1)))
    func turnedAwayRunIsRecorded() async throws {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        let center = fixture.center(simulatedPages: bank.site.answer, settling: .fast)
        try center.save(grant: sessionGrant(), record: record())
        defer { center.access.end(visit: "run") }
        #expect(center.awaitingSignIn.isEmpty)

        let result = await center.access.open(siteID: "example.com", visit: "run")

        #expect(result == .failure(.needsPerson))
        #expect(center.awaitingSignIn == ["example.com"])
        // The hook refreshed the list after the flag was written.
        #expect(center.sites.first?.needsPerson == true)
    }

    @Test("A day's attempts used up put a site in the awaiting set, and a later open that reads its page takes it out", .timeLimit(.minutes(2)))
    func openingTakesTheSiteOutOfTheAwaitingSet() async throws {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        let center = fixture.center(simulatedPages: bank.site.answer, settling: .fast)
        try center.save(
            grant: SiteGrant(
                username: bank.username,
                password: bank.password,
                authenticatorKey: nil,
                signInURL: URL(string: "https://example.com/login")!,
                startURL: URL(string: "https://example.com/account")!,
                fillHosts: ["example.com"],
                browseHosts: ["example.com"],
                codeKind: .none,
                codeSender: nil,
                signInSteps: [
                    SignInStep(
                        kind: .username, origin: "https://example.com", path: "/login",
                        field: FieldKey(name: "username", id: "user", autocomplete: "username", type: "text")
                    ),
                    SignInStep(
                        kind: .password, origin: "https://example.com", path: "/login",
                        field: FieldKey(name: "password", id: "pass", autocomplete: "current-password", type: "password")
                    ),
                ]
            ),
            record: record()
        )
        defer { center.access.end(visit: "run") }

        for _ in 1...SignInAttempts.perDay {
            bank.signOut()
            #expect(await center.access.open(siteID: "example.com", visit: "run") != .failure(.needsPerson))
        }
        #expect(center.awaitingSignIn.isEmpty)

        bank.signOut()
        #expect(await center.access.open(siteID: "example.com", visit: "run") == .failure(.needsPerson))
        // Out of attempts is no flag, so only the awaiting set says the person is wanted.
        #expect(center.awaitingSignIn == ["example.com"])
        #expect(center.sites.first?.needsPerson == false)

        bank.markSignedIn()
        if case .failure = await center.access.open(siteID: "example.com", visit: "run") {
            Issue.record("the site's start page could not be read")
        }
        #expect(center.awaitingSignIn.isEmpty)
    }

    @Test("Saving a flagged site that a run was turned away from reports it once and clears the wait", .timeLimit(.minutes(1)))
    func savingAnAwaitedSiteIsReported() async throws {
        let fixture = try SiteCenterFixture()
        let bank = TestBank()
        let center = fixture.center(simulatedPages: bank.site.answer, settling: .fast)
        try center.save(grant: sessionGrant(), record: record())
        defer { center.access.end(visit: "run") }
        _ = await center.access.open(siteID: "example.com", visit: "run")
        let log = SaveLog()
        center.onSiteSaved = { log.record($0, $1) }

        bank.markSignedIn()
        try center.save(grant: sessionGrant(), record: record())

        #expect(log.entries == [.init(siteID: "example.com", wasAwaited: true)])
        #expect(center.awaitingSignIn.isEmpty)
        #expect(center.sites.first?.needsPerson == false)
    }

    @Test("Saving a site that a run was turned away from reports it as awaited though its record was never flagged")
    func savingAnAwaitedSiteWithACleanRecord() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        let log = SaveLog()
        center.onSiteSaved = { log.record($0, $1) }

        // A day's attempts used up tell the hook and leave the record unflagged.
        center.access.onPersonNeeded?("example.com")
        #expect(center.awaitingSignIn == ["example.com"])
        #expect(center.sites.first?.needsPerson == false)
        try center.save(grant: grant(), record: record())

        #expect(log.entries == [.init(siteID: "example.com", wasAwaited: true)])
        #expect(center.awaitingSignIn.isEmpty)
    }

    @Test("Saving a site flagged in the registry reports it as awaited though no run was turned away since the launch")
    func savingAFlaggedSiteIsReported() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        var flagged = try #require(SiteRegistry.load(from: fixture.registry).first)
        flagged.needsPerson = true
        try SiteRegistry.save([flagged], to: fixture.registry)
        let log = SaveLog()
        center.onSiteSaved = { log.record($0, $1) }
        #expect(center.awaitingSignIn.isEmpty)

        try center.save(grant: grant(), record: record())

        #expect(log.entries == [.init(siteID: "example.com", wasAwaited: true)])
    }

    @Test("Saving a site nothing waited on reports it as not awaited, and another site's wait is left alone")
    func savingASiteNothingWaitedOn() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        try center.save(grant: grant("other.example.org"), record: record("other.example.org", name: "Other"))
        let log = SaveLog()
        center.onSiteSaved = { log.record($0, $1) }

        try center.save(grant: grant(), record: record())
        #expect(log.entries == [.init(siteID: "example.com", wasAwaited: false)])

        center.access.onPersonNeeded?("other.example.org")
        try center.save(grant: grant(), record: record())
        #expect(log.entries.last == .init(siteID: "example.com", wasAwaited: false))
        #expect(center.awaitingSignIn == ["other.example.org"])
    }

    @Test("A save that fails reports nothing and leaves the wait in place")
    func failedSaveKeepsTheWait() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        center.access.onPersonNeeded?("example.com")
        let log = SaveLog()
        center.onSiteSaved = { log.record($0, $1) }

        #expect(throws: SiteVault.Failure.invalidGrant) {
            try center.save(grant: grant("other.example.org"), record: record("example.com"))
        }

        #expect(log.entries.isEmpty)
        #expect(center.awaitingSignIn == ["example.com"])
    }

    @Test("Removing a site ends its wait")
    func removalEndsTheWait() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        try center.save(grant: grant("other.example.org"), record: record("other.example.org", name: "Other"))
        center.access.onPersonNeeded?("example.com")
        center.access.onPersonNeeded?("other.example.org")

        try await center.remove("example.com")

        #expect(center.awaitingSignIn == ["other.example.org"])
    }

    @Test("A removal that fails leaves the site awaiting the person", .enabled(if: getuid() != 0))
    func failedRemovalKeepsTheWait() async throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        center.access.onPersonNeeded?("example.com")

        // A directory that cannot be written to refuses the registry's replacement file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.directory.path)
        await #expect(throws: (any Error).self) { try await center.remove("example.com") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)

        #expect(center.awaitingSignIn == ["example.com"])
    }

    @Test("Telling the hook again of a site already awaited publishes nothing")
    func awaitingPublishesOnlyChanges() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        var published: [Set<String>] = []
        let subscription = center.$awaitingSignIn.sink { published.append($0) }
        defer { subscription.cancel() }

        center.access.onPersonNeeded?("example.com")
        center.access.onPersonNeeded?("example.com")

        #expect(published == [[], ["example.com"]])
    }

    @Test("The center reports every turn-away, each time, once the awaiting set holds the site")
    func turnAwayIsReportedEachTime() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        try center.save(grant: grant(), record: record())
        var reported: [(String, Set<String>)] = []
        center.onPersonNeeded = { siteID in
            reported.append((siteID, center.awaitingSignIn))
        }

        center.access.onPersonNeeded?("example.com")
        center.access.onPersonNeeded?("example.com")

        #expect(reported.map(\.0) == ["example.com", "example.com"])
        #expect(reported.allSatisfy { $0.1 == ["example.com"] })
    }

    @Test("A site reads as needing you when its record is flagged or a run was turned away from it")
    func statusFollowsTheWait() {
        let clean = record()
        var flagged = record("other.example.org", name: "Other")
        flagged.needsPerson = true
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var signedIn = record()
        signedIn.lastSignedIn = date

        #expect(SiteAccessCenter.SiteStatus(clean, awaiting: []) == .notSignedInYet)
        #expect(SiteAccessCenter.SiteStatus(clean, awaiting: ["example.com"]) == .needsYou)
        #expect(SiteAccessCenter.SiteStatus(clean, awaiting: ["other.example.org"]) == .notSignedInYet)
        #expect(SiteAccessCenter.SiteStatus(flagged, awaiting: []) == .needsYou)
        #expect(SiteAccessCenter.SiteStatus(flagged, awaiting: ["example.com"]) == .needsYou)
        #expect(SiteAccessCenter.SiteStatus(signedIn, awaiting: []) == .signedIn(date))
        #expect(SiteAccessCenter.SiteStatus(signedIn, awaiting: ["example.com"]) == .needsYou)
    }

    // MARK: Texts

    @Test("Texts are off while the setting is, even with a readable database")
    func textsOff() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        center.refresh()
        #expect(center.textsStatus == .off)
        #expect(!center.textsEnabled)
    }

    @Test("Turning texts on reads the database, and the setting is kept")
    func textsOn() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        center.setTextsEnabled(true)
        #expect(center.textsStatus == .on)
        #expect(fixture.defaults.bool(forKey: "provisor.readTexts"))

        center.setTextsEnabled(false)
        #expect(center.textsStatus == .off)
        #expect(fixture.defaults.object(forKey: "provisor.readTexts") as? Bool == false)
    }

    @Test("A database the system refuses reads as denied access", .enabled(if: getuid() != 0))
    func textsDenied() throws {
        let fixture = try SiteCenterFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.databasePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.databasePath) }
        let center = fixture.center()
        center.setTextsEnabled(true)
        #expect(center.textsStatus == .accessDenied)
    }

    @Test("A missing database also reads as denied access")
    func textsMissing() throws {
        let fixture = try SiteCenterFixture(database: false)
        let center = fixture.center()
        center.setTextsEnabled(true)
        #expect(center.textsStatus == .accessDenied)
    }

    // MARK: Codes

    @Test("The authenticator source gives the key's code for the current time")
    func authenticatorCode() throws {
        let fixture = try SiteCenterFixture()
        // RFC 6238's SHA-1 vector: 94287082 at T = 59, of which six digits are kept.
        let codes = fixture.codes(textsOn: false, now: { Date(timeIntervalSince1970: 59) })
        #expect(codes.authenticator(CodeStub.sampleKey) == "287082")
        #expect(codes.authenticator("not a key") == nil)
    }

    @Test("A texted code is found once it arrives after the baseline", .timeLimit(.minutes(1)))
    func textedCode() async throws {
        let fixture = try SiteCenterFixture()
        let codes = fixture.codes(textsOn: true, polling: quickPolling)
        let baseline = try #require(codes.messageBaseline())

        let waiting = Task { await codes.texted("24273", baseline) }
        try await Task.sleep(for: .milliseconds(100))
        try fixture.receive("Your verification code is 482910")
        #expect(await waiting.value == "482910")

        let first = await codes.firstTextedCode(baseline)
        #expect(first?.code == "482910")
        #expect(first?.sender == "24273")
    }

    @Test("With texts off nothing is read: no baseline and no code", .timeLimit(.minutes(1)))
    func textsOffReadsNothing() async throws {
        let fixture = try SiteCenterFixture()
        try fixture.receive("Your verification code is 482910")
        let codes = fixture.codes(
            textsOn: false,
            polling: .init(interval: .milliseconds(20), limit: .milliseconds(200))
        )
        #expect(codes.messageBaseline() == nil)
        #expect(await codes.texted("24273", 0) == nil)
        #expect(await codes.firstTextedCode(0) == nil)
    }

    @Test("The center reads texts for a sign-in only while the setting is on")
    func centerCodesFollowSetting() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        #expect(center.codes.messageBaseline() == nil)

        center.setTextsEnabled(true)
        #expect(center.codes.messageBaseline() == 1)

        center.setTextsEnabled(false)
        #expect(center.codes.messageBaseline() == nil)
    }

    @Test("Cancelling a wait for a texted code ends it at once", .timeLimit(.minutes(1)))
    func textedWaitCancels() async throws {
        let fixture = try SiteCenterFixture()
        let codes = fixture.codes(
            textsOn: true,
            polling: .init(interval: .seconds(60), limit: .seconds(120))
        )
        let waiting = Task { await codes.texted("24273", 1_000) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("A wait for a texted code that never arrives gives up at the limit", .timeLimit(.minutes(1)))
    func textedWaitGivesUp() async throws {
        let fixture = try SiteCenterFixture()
        let codes = fixture.codes(
            textsOn: true,
            polling: .init(interval: .milliseconds(20), limit: .milliseconds(200))
        )
        let start = ContinuousClock.now
        #expect(await codes.texted("24273", 1_000) == nil)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("Emailed codes come from the center's source once one is set")
    func emailedCode() async throws {
        let fixture = try SiteCenterFixture()
        let relay = EmailedCodeRelay()
        let codes = fixture.codes(textsOn: false, relay: relay)
        #expect(await codes.emailed("codes@example.com", Date()) == nil)

        relay.source = { sender, _ in sender == "codes@example.com" ? "135790" : nil }
        #expect(await codes.emailed("codes@example.com", Date()) == "135790")
        #expect(await codes.emailed("other@example.com", Date()) == nil)
    }

    @Test("Setting the center's emailed source reaches the relay")
    func centerEmailedSource() throws {
        let fixture = try SiteCenterFixture()
        let center = fixture.center()
        #expect(center.emailedCode == nil)
        center.emailedCode = { _, _ in "135790" }
        #expect(center.emailedCode != nil)
        center.emailedCode = nil
        #expect(center.emailedCode == nil)
    }
}
