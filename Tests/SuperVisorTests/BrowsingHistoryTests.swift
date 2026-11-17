import Foundation
import SQLite3
import Testing

@testable import SuperVisor

/// Temporary history files in the shapes Chromium-family browsers and Safari keep, and a
/// `BrowsingHistory` over them.
private final class HistoryFixture: @unchecked Sendable {
    enum FixtureError: Error { case sqlite }

    /// One visit: the page and when it was visited.
    struct Visit {
        let url: String
        let date: Date
    }

    let directory: URL
    let chrome: URL
    let arc: URL
    let safari: URL
    let timeZone = TimeZone(identifier: "America/Los_Angeles")!
    private let lock = NSLock()
    private var protectedAllowed = true
    private var protectedAsked = 0

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsing-history-\(UUID().uuidString)", isDirectory: true)
        chrome = directory.appendingPathComponent("Google/Chrome", isDirectory: true)
        arc = directory.appendingPathComponent("Arc/User Data", isDirectory: true)
        safari = directory.appendingPathComponent("Safari/History.db", isDirectory: false)
        for folder in [chrome, arc, safari.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var allowsProtected: Bool {
        get { lock.withLock { protectedAllowed } }
        set { lock.withLock { protectedAllowed = newValue } }
    }

    var protectedChecks: Int { lock.withLock { protectedAsked } }

    var history: BrowsingHistory {
        BrowsingHistory(
            chromiumRoots: [
                .init(url: chrome, isProtected: true),
                .init(url: arc, isProtected: false),
            ],
            safariHistoryURL: safari,
            timeZone: timeZone,
            canReadProtectedData: { [self] in
                lock.withLock {
                    protectedAsked += 1
                    return protectedAllowed
                }
            }
        )
    }

    /// A local time in the fixture's time zone.
    func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Writes a Chromium-family profile's `History` under `root` with these visits.
    func chromiumProfile(_ name: String, in root: URL? = nil, _ visits: [Visit]) throws {
        let folder = (root ?? chrome).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(
            folder.appendingPathComponent("History").path,
            schema: """
                CREATE TABLE urls (id INTEGER PRIMARY KEY AUTOINCREMENT, url LONGVARCHAR, title LONGVARCHAR, visit_count INTEGER DEFAULT 0 NOT NULL, typed_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL DEFAULT 0, hidden INTEGER DEFAULT 0 NOT NULL);
                CREATE INDEX urls_url_index ON urls (url);
                CREATE TABLE visits (id INTEGER PRIMARY KEY AUTOINCREMENT, url INTEGER NOT NULL, visit_time INTEGER NOT NULL, from_visit INTEGER, transition INTEGER DEFAULT 0 NOT NULL);
                CREATE INDEX visits_url_index ON visits (url);
                """,
            items: "urls",
            visitsTable: "visits",
            visitColumn: "url",
            visits: visits
        ) { date in
            .integer(Int64((date.timeIntervalSince1970 + BrowsingHistory.chromiumEpochOffset) * 1_000_000))
        }
    }

    func safariHistory(_ visits: [Visit]) throws {
        try write(
            safari.path,
            schema: """
                CREATE TABLE history_items (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL UNIQUE, domain_expansion TEXT NULL, visit_count INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE history_visits (id INTEGER PRIMARY KEY AUTOINCREMENT, history_item INTEGER NOT NULL, visit_time REAL NOT NULL, title TEXT NULL);
                """,
            items: "history_items",
            visitsTable: "history_visits",
            visitColumn: "history_item",
            visits: visits
        ) { date in
            .real(date.timeIntervalSinceReferenceDate)
        }
    }

    enum Time {
        case integer(Int64)
        case real(Double)
    }

    private func write(
        _ path: String,
        schema: String,
        items: String,
        visitsTable: String,
        visitColumn: String,
        visits: [Visit],
        time: (Date) -> Time
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for visit in visits {
            var itemID: Int64 = 0
            var find: OpaquePointer?
            sqlite3_prepare_v2(database, "SELECT id FROM \(items) WHERE url = ?1", -1, &find, nil)
            sqlite3_bind_text(find, 1, visit.url, -1, transient)
            if sqlite3_step(find) == SQLITE_ROW { itemID = sqlite3_column_int64(find, 0) }
            sqlite3_finalize(find)
            if itemID == 0 {
                var insert: OpaquePointer?
                sqlite3_prepare_v2(database, "INSERT INTO \(items) (url) VALUES (?1)", -1, &insert, nil)
                sqlite3_bind_text(insert, 1, visit.url, -1, transient)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw FixtureError.sqlite }
                sqlite3_finalize(insert)
                itemID = sqlite3_last_insert_rowid(database)
            }
            var insert: OpaquePointer?
            let sql = "INSERT INTO \(visitsTable) (\(visitColumn), visit_time) VALUES (?1, ?2)"
            guard sqlite3_prepare_v2(database, sql, -1, &insert, nil) == SQLITE_OK else { throw FixtureError.sqlite }
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_int64(insert, 1, itemID)
            switch time(visit.date) {
            case let .integer(value): sqlite3_bind_int64(insert, 2, value)
            case let .real(value): sqlite3_bind_double(insert, 2, value)
            }
            guard sqlite3_step(insert) == SQLITE_DONE else { throw FixtureError.sqlite }
        }
    }
}

@Suite("Browsing history")
struct BrowsingHistoryTests {
    private typealias Visit = HistoryFixture.Visit

    @Test("Visits on two days in one Chromium profile count, and only for that host")
    func twoDays() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [
            Visit(url: "https://example.com/login", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://example.com/account", date: fixture.local(2026, 11, 9)),
        ])

        #expect(fixture.history.hasVisited(host: "example.com"))
        #expect(!fixture.history.hasVisited(host: "other.example"))
    }

    @Test("Many visits on one day do not count")
    func oneDayIsNotEnough() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", (0..<12).map { minute in
            Visit(url: "https://example.com/login", date: fixture.local(2026, 11, 2, 9, minute))
        })
        try fixture.safariHistory([
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 2, 18)),
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 2, 23, 59)),
        ])

        #expect(!fixture.history.hasVisited(host: "example.com"))
    }

    @Test("Visits on two days in Safari alone count")
    func safariOnly() throws {
        let fixture = try HistoryFixture()
        try fixture.safariHistory([
            Visit(url: "https://example.com/", date: fixture.local(2026, 10, 1)),
            Visit(url: "https://example.com", date: fixture.local(2026, 10, 5)),
        ])

        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("Days split across two browsers count")
    func splitAcrossBrowsers() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Profile 1", in: fixture.arc, [
            Visit(url: "https://example.com/a", date: fixture.local(2026, 11, 2)),
        ])
        try fixture.safariHistory([Visit(url: "https://example.com/b", date: fixture.local(2026, 11, 3))])

        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("Days split across two profiles of one browser count")
    func splitAcrossProfiles() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [Visit(url: "https://example.com/a", date: fixture.local(2026, 11, 2))])
        try fixture.chromiumProfile("Profile 1", [Visit(url: "https://example.com/b?x=1", date: fixture.local(2026, 11, 4))])

        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("A Chromium-family browser other than Chrome is read")
    func otherChromiumRoot() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", in: fixture.arc, [
            Visit(url: "https://example.com/a", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://example.com/a", date: fixture.local(2026, 11, 3)),
        ])
        fixture.allowsProtected = false

        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("Chrome and Safari are not read without access to protected data, and the other browsers are")
    func protectedRootsSkipped() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [
            Visit(url: "https://example.com/a", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://example.com/a", date: fixture.local(2026, 11, 3)),
        ])
        try fixture.safariHistory([
            Visit(url: "https://other.example/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://other.example/", date: fixture.local(2026, 11, 3)),
        ])
        fixture.allowsProtected = false

        #expect(!fixture.history.hasVisited(host: "example.com"))
        #expect(!fixture.history.hasVisited(host: "other.example"))
        #expect(fixture.protectedChecks == 2)

        fixture.allowsProtected = true
        #expect(fixture.history.hasVisited(host: "example.com"))
        #expect(fixture.history.hasVisited(host: "other.example"))
    }

    @Test("A Chromium visit time just either side of local midnight lands on its own local day")
    func chromiumDayBoundary() throws {
        let fixture = try HistoryFixture()
        let midnight = fixture.local(2026, 11, 3, 0, 0)
        try fixture.chromiumProfile("Default", [
            Visit(url: "https://example.com/", date: midnight.addingTimeInterval(-1)),
            Visit(url: "https://example.com/", date: midnight.addingTimeInterval(1)),
        ])

        #expect(fixture.history.hasVisited(host: "example.com"))
        // Two seconds apart in UTC terms, but one local day when both fall after midnight.
        let sameDay = try HistoryFixture()
        try sameDay.chromiumProfile("Default", [
            Visit(url: "https://example.com/", date: midnight.addingTimeInterval(1)),
            Visit(url: "https://example.com/", date: midnight.addingTimeInterval(3)),
        ])
        #expect(!sameDay.history.hasVisited(host: "example.com"))
    }

    @Test("A Safari visit time just either side of local midnight lands on its own local day")
    func safariDayBoundary() throws {
        let fixture = try HistoryFixture()
        let midnight = fixture.local(2026, 11, 3, 0, 0)
        try fixture.safariHistory([
            Visit(url: "https://example.com/", date: midnight.addingTimeInterval(-1)),
            Visit(url: "https://example.com/a", date: midnight.addingTimeInterval(1)),
        ])

        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("The stored times convert from their epochs to the right local day")
    func conversions() {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        // 2026-11-03T07:59:59Z is 23:59:59 on Nov 2 in Los Angeles; one second later is Nov 3.
        let before = Int64((1_793_692_799 + BrowsingHistory.chromiumEpochOffset) * 1_000_000)
        let after = before + 1_000_000
        let first = BrowsingHistory.date(chromiumMicroseconds: before)
        let second = BrowsingHistory.date(chromiumMicroseconds: after)
        #expect(first.map { BrowsingHistory.day(of: $0, in: losAngeles) } == DateComponents(year: 2026, month: 11, day: 2))
        #expect(second.map { BrowsingHistory.day(of: $0, in: losAngeles) } == DateComponents(year: 2026, month: 11, day: 3))

        let safariBefore = 1_793_692_799 - Date.timeIntervalBetween1970AndReferenceDate
        #expect(BrowsingHistory.date(safariSeconds: safariBefore).map { BrowsingHistory.day(of: $0, in: losAngeles) }
            == DateComponents(year: 2026, month: 11, day: 2))
        #expect(BrowsingHistory.date(safariSeconds: safariBefore + 1).map { BrowsingHistory.day(of: $0, in: losAngeles) }
            == DateComponents(year: 2026, month: 11, day: 3))

        #expect(BrowsingHistory.date(chromiumMicroseconds: 0) == nil)
        #expect(BrowsingHistory.date(safariSeconds: .nan) == nil)
        #expect(BrowsingHistory.date(safariSeconds: -5) == nil)
    }

    @Test("Plain http pages do not count")
    func httpDoesNotCount() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [
            Visit(url: "http://example.com/login", date: fixture.local(2026, 11, 2)),
            Visit(url: "http://example.com/login", date: fixture.local(2026, 11, 3)),
        ])

        #expect(!fixture.history.hasVisited(host: "example.com"))
    }

    @Test(
        "A look-alike address, a port, or credentials in front of the host does not count",
        arguments: [
            "https://example.com.evil.test/login",
            "https://notexample.com/",
            "https://example.com:8443/login",
            "https://example.com@evil.test/",
            "https://example.co/",
            "https://example.comx/",
            "https://evil.test/https://example.com/",
            "https://EXAMPLE.com/",
        ]
    )
    func lookAlikesDoNotCount(_ url: String) throws {
        let fixture = try HistoryFixture()
        let visits = [Visit(url: url, date: fixture.local(2026, 11, 2)), Visit(url: url, date: fixture.local(2026, 11, 3))]
        try fixture.chromiumProfile("Default", visits)
        try fixture.safariHistory(visits)

        #expect(!fixture.history.hasVisited(host: "example.com"))
    }

    @Test("A parent domain or a subdomain is a different site")
    func parentAndSubdomain() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [
            Visit(url: "https://bank.example.com/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://bank.example.com/", date: fixture.local(2026, 11, 3)),
            Visit(url: "https://login.bank.example.com/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://login.bank.example.com/", date: fixture.local(2026, 11, 3)),
        ])

        #expect(!fixture.history.hasVisited(host: "example.com"))
        #expect(fixture.history.hasVisited(host: "bank.example.com"))
        #expect(!fixture.history.hasVisited(host: "secure.bank.example.com"))
    }

    @Test(
        "A host that is not a plain lowercase DNS name is never visited",
        arguments: ["", "Example.com", "example.com/", "example", "https://example.com", "example.com:443", "127.0.0.1", "exa%mple.com"]
    )
    func invalidHost(_ host: String) throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [
            Visit(url: "https://\(host)/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://\(host)/", date: fixture.local(2026, 11, 3)),
        ])

        #expect(!fixture.history.hasVisited(host: host))
    }

    @Test("Missing history files read as no visits")
    func missingFiles() {
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("browsing-history-missing-\(UUID().uuidString)", isDirectory: true)
        let history = BrowsingHistory(
            chromiumRoots: [.init(url: nowhere, isProtected: false)],
            safariHistoryURL: nowhere.appendingPathComponent("History.db"),
            canReadProtectedData: { true }
        )

        #expect(!history.hasVisited(host: "example.com"))
        #expect(history.schemaReport() == BrowsingHistory.SchemaReport(
            chromiumProfilesRead: 0,
            chromiumSchemaOK: false,
            safariReadable: false,
            safariSchemaOK: false,
            canReadProtectedData: true
        ))
    }

    @Test("A file that is not a history database, or has another schema, reads as no visits")
    func unexpectedFiles() throws {
        let fixture = try HistoryFixture()
        let folder = fixture.chrome.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: folder.appendingPathComponent("History"))
        // A Chromium file where Safari's should be: the wrong tables for Safari.
        try fixture.chromiumProfile("Profile 1", [
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 2)),
        ])
        try FileManager.default.copyItem(at: fixture.chrome.appendingPathComponent("Profile 1/History"), to: fixture.safari)

        #expect(!fixture.history.hasVisited(host: "example.com"))
        let report = fixture.history.schemaReport()
        #expect(report.chromiumProfilesRead == 2)
        #expect(!report.chromiumSchemaOK)
        #expect(report.safariReadable)
        #expect(!report.safariSchemaOK)
    }

    @Test("The schema report holds counts and flags for readable files of the expected shape")
    func schemaReport() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Default", [])
        try fixture.chromiumProfile("Default", in: fixture.arc, [])
        try fixture.safariHistory([])

        #expect(fixture.history.schemaReport() == BrowsingHistory.SchemaReport(
            chromiumProfilesRead: 2,
            chromiumSchemaOK: true,
            safariReadable: true,
            safariSchemaOK: true,
            canReadProtectedData: true
        ))
        fixture.allowsProtected = false
        #expect(fixture.history.schemaReport() == BrowsingHistory.SchemaReport(
            chromiumProfilesRead: 1,
            chromiumSchemaOK: true,
            safariReadable: false,
            safariSchemaOK: false,
            canReadProtectedData: false
        ))
    }

    @Test("A profile folder without a History file is skipped, and a History that is a link is not read")
    func profileWithoutHistory() throws {
        let fixture = try HistoryFixture()
        let empty = fixture.chrome.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try fixture.chromiumProfile("Profile 1", [Visit(url: "https://example.com/", date: fixture.local(2026, 11, 2))])
        try fixture.chromiumProfile("Profile 3", in: fixture.arc, [
            Visit(url: "https://other.example/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://other.example/", date: fixture.local(2026, 11, 3)),
        ])
        let linked = fixture.chrome.appendingPathComponent("Profile 2", isDirectory: true)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linked.appendingPathComponent("History"),
            withDestinationURL: fixture.arc.appendingPathComponent("Profile 3/History")
        )
        // A file directly in a root folder is not a profile.
        try FileManager.default.copyItem(
            at: fixture.arc.appendingPathComponent("Profile 3/History"),
            to: fixture.chrome.appendingPathComponent("History")
        )
        try FileManager.default.removeItem(at: fixture.arc.appendingPathComponent("Profile 3"))
        try fixture.chromiumProfile("Profile 4", in: fixture.arc, [
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 3)),
        ])

        #expect(fixture.history.hasVisited(host: "example.com"))
        #expect(!fixture.history.hasVisited(host: "other.example"))
    }

    @Test("A profile folder whose name holds URI punctuation is read")
    func punctuatedProfileName() throws {
        let fixture = try HistoryFixture()
        try fixture.chromiumProfile("Work ?mode=rw#%20 é", [
            Visit(url: "https://example.com/login", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://example.com/login", date: fixture.local(2026, 11, 3)),
        ])

        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("At most sixteen profiles are read from one root")
    func profilesPerRootAreBounded() throws {
        let fixture = try HistoryFixture()
        for index in 0..<BrowsingHistory.maximumProfilesPerRoot {
            try fixture.chromiumProfile(String(format: "Profile %02d", index), [])
        }
        try fixture.chromiumProfile("Profile 99", [
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 3)),
        ])

        #expect(!fixture.history.hasVisited(host: "example.com"))
        try FileManager.default.removeItem(at: fixture.chrome.appendingPathComponent("Profile 00"))
        #expect(fixture.history.hasVisited(host: "example.com"))
    }

    @Test("At most forty-eight profiles are read across roots")
    func profilesInAllAreBounded() throws {
        let fixture = try HistoryFixture()
        let roots = (0..<4).map { fixture.directory.appendingPathComponent("Root \($0)", isDirectory: true) }
        for root in roots.prefix(3) {
            for index in 0..<BrowsingHistory.maximumProfilesPerRoot {
                try fixture.chromiumProfile(String(format: "Profile %02d", index), in: root, [])
            }
        }
        try fixture.chromiumProfile("Default", in: roots[3], [
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 2)),
            Visit(url: "https://example.com/", date: fixture.local(2026, 11, 3)),
        ])
        func history(_ roots: [URL]) -> BrowsingHistory {
            BrowsingHistory(
                chromiumRoots: roots.map { .init(url: $0, isProtected: false) },
                safariHistoryURL: fixture.safari,
                canReadProtectedData: { false }
            )
        }

        #expect(history(roots).schemaReport().chromiumProfilesRead == BrowsingHistory.maximumProfiles)
        #expect(!history(roots).hasVisited(host: "example.com"))
        #expect(history(Array(roots.dropFirst())).hasVisited(host: "example.com"))
    }

    @Test("Only the most recent visits are read from a file")
    func visitsAreBounded() throws {
        let fixture = try HistoryFixture()
        // An old visit on another day, behind a full window of recent visits on one day.
        let recent = (0..<BrowsingHistory.maximumVisits).map { index in
            Visit(url: "https://example.com/\(index)", date: fixture.local(2026, 11, 10, 9).addingTimeInterval(Double(index)))
        }
        try fixture.chromiumProfile("Default", [Visit(url: "https://example.com/old", date: fixture.local(2026, 1, 5))] + recent)

        #expect(!fixture.history.hasVisited(host: "example.com"))
    }
}
