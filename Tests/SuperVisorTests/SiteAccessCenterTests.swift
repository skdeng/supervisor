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
        #expect(SiteAccessCenter.SiteStatus(site) == .notSignedInYet)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        site.lastSignedIn = date
        #expect(SiteAccessCenter.SiteStatus(site) == .signedIn(date))
        site.needsPerson = true
        #expect(SiteAccessCenter.SiteStatus(site) == .needsYou)
    }

    @Test("A site kept by its session reads as signed in that way, and needs you once its session ends")
    func sessionSiteStatus() {
        var site = record()
        site.keepsSessionOnly = true
        #expect(SiteAccessCenter.SiteStatus(site) == .notSignedInYet)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        site.lastSignedIn = date
        #expect(SiteAccessCenter.SiteStatus(site) == .signedInKeepingSession(date))
        site.needsPerson = true
        #expect(SiteAccessCenter.SiteStatus(site) == .needsYou)
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
