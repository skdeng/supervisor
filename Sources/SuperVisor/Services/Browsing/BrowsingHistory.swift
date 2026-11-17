import Foundation
import SQLite3

/// Whether the user's own browsers have a history of visiting a host. It answers one question
/// and exposes nothing else: no address, title, or date leaves this type.
///
/// A host counts as visited when `https` pages on exactly that host were visited on at least
/// `minimumDays` distinct local calendar days, across every Chromium-family profile and Safari.
/// Days, not visits: one click can count twice (a reload, a redirect), and a phishing link is
/// usually followed on one day. A parent domain, a subdomain, a port, or a plain `http` page is
/// a different site and counts for nothing. Anything that keeps a history file from being read
/// — missing, no access, another schema, busy — reads as no visits.
///
/// **Protected folders are read only with Full Disk Access.** Chrome's folder and Safari's are
/// protected by macOS, and touching them without the grant can put a consent prompt in front of
/// the user. They are skipped unless `canReadProtectedData` says the grant is there; the other
/// browsers' folders are read regardless.
struct BrowsingHistory: Sendable {
    /// A folder whose direct children holding a `History` file are Chromium-family profiles.
    struct ChromiumRoot: Sendable, Equatable {
        let url: URL
        /// Read only when `canReadProtectedData` says so.
        let isProtected: Bool
    }

    /// What the schema self-check found. It holds counts and flags only.
    struct SchemaReport: Equatable, Sendable {
        let chromiumProfilesRead: Int
        let chromiumSchemaOK: Bool
        let safariReadable: Bool
        let safariSchemaOK: Bool
        let canReadProtectedData: Bool
    }

    static let minimumDays = 2
    static let maximumProfilesPerRoot = 16
    static let maximumProfiles = 48
    /// The most recent matching visits read from one database.
    static let maximumVisits = 400

    /// Seconds from 1601-01-01 UTC, Chromium's epoch, to 1970-01-01 UTC.
    static let chromiumEpochOffset: Double = 11_644_473_600

    let chromiumRoots: [ChromiumRoot]
    let safariHistoryURL: URL
    let timeZone: TimeZone
    let canReadProtectedData: @Sendable () -> Bool

    init() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let safari = home.appendingPathComponent("Library/Safari/History.db", isDirectory: false)
        let roots = [
            ("Google/Chrome", true),
            ("Arc/User Data", false),
            ("BraveSoftware/Brave-Browser", false),
            ("Microsoft Edge", false),
            ("Chromium", false),
            ("Vivaldi", false),
            ("Dia/User Data", false),
        ].map { path, isProtected in
            ChromiumRoot(url: support.appendingPathComponent(path, isDirectory: true), isProtected: isProtected)
        }
        self.init(
            chromiumRoots: roots,
            safariHistoryURL: safari,
            timeZone: .current,
            canReadProtectedData: { Self.canOpenForReading(safari) }
        )
    }

    init(
        chromiumRoots: [ChromiumRoot],
        safariHistoryURL: URL,
        timeZone: TimeZone = .current,
        canReadProtectedData: @escaping @Sendable () -> Bool
    ) {
        self.chromiumRoots = chromiumRoots
        self.safariHistoryURL = safariHistoryURL
        self.timeZone = timeZone
        self.canReadProtectedData = canReadProtectedData
    }

    func hasVisited(host: String) -> Bool {
        guard SiteHost.isValid(host) else { return false }
        let mayReadProtected = canReadProtectedData()
        var days = Set<DateComponents>()
        for history in chromiumHistoryFiles(mayReadProtected: mayReadProtected) {
            days.formUnion(Self.visitDays(to: host, in: history, source: .chromium, timeZone: timeZone))
            if days.count >= Self.minimumDays { break }
        }
        if days.count < Self.minimumDays, mayReadProtected {
            days.formUnion(Self.visitDays(to: host, in: safariHistoryURL, source: .safari, timeZone: timeZone))
        }
        let visited = days.count >= Self.minimumDays
        AppLog.debug(.sites, "browsing history answered \(visited)")
        return visited
    }

    /// Whether the history files can be opened and carry the tables and columns read here.
    func schemaReport() -> SchemaReport {
        let mayReadProtected = canReadProtectedData()
        let profiles = chromiumHistoryFiles(mayReadProtected: mayReadProtected)
        let chromiumOK = !profiles.isEmpty && profiles.allSatisfy { Self.hasSchema(of: .chromium, in: $0) }
        let safariReadable = mayReadProtected && Self.withDatabase(safariHistoryURL, source: .safari) { _ in true } == true
        return SchemaReport(
            chromiumProfilesRead: profiles.count,
            chromiumSchemaOK: chromiumOK,
            safariReadable: safariReadable,
            safariSchemaOK: safariReadable && Self.hasSchema(of: .safari, in: safariHistoryURL),
            canReadProtectedData: mayReadProtected
        )
    }

    // MARK: Files

    /// The `History` file of each direct child folder of each root that holds one as a regular
    /// file, in root order and then name order: at most `maximumProfilesPerRoot` per root and
    /// `maximumProfiles` in all. A protected root is skipped unless `mayReadProtected`.
    private func chromiumHistoryFiles(mayReadProtected: Bool) -> [URL] {
        var files: [URL] = []
        for root in chromiumRoots where mayReadProtected || !root.isProtected {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.url.path) else {
                continue
            }
            var fromRoot = 0
            for name in names.sorted() {
                guard fromRoot < Self.maximumProfilesPerRoot, files.count < Self.maximumProfiles else { break }
                let folder = root.url.appendingPathComponent(name, isDirectory: true)
                guard Self.isDirectory(folder) else { continue }
                let history = folder.appendingPathComponent("History", isDirectory: false)
                if Self.isRegularFile(history) {
                    files.append(history)
                    fromRoot += 1
                }
            }
        }
        return files
    }

    /// A directory, reached by a symbolic link or not: a profile folder is the browser's to
    /// arrange.
    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A regular file that is not a symbolic link.
    private static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func canOpenForReading(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    // MARK: Reading

    /// Which browser's tables a file holds, and how its visit times count.
    enum Source {
        /// `urls(id, url)` and `visits(url → urls.id, visit_time)`, microseconds since 1601-01-01
        /// UTC. Opened immutable: the browser keeps the file locked while it runs.
        case chromium
        /// `history_items(id, url)` and `history_visits(history_item → history_items.id,
        /// visit_time)`, seconds since 2001-01-01 UTC.
        case safari

        var query: String {
            switch self {
            case .chromium:
                """
                SELECT visits.visit_time FROM visits JOIN urls ON urls.id = visits.url
                WHERE (urls.url >= ?1 AND urls.url < ?2) OR urls.url = ?3
                ORDER BY visits.visit_time DESC LIMIT ?4
                """
            case .safari:
                """
                SELECT history_visits.visit_time FROM history_visits
                JOIN history_items ON history_items.id = history_visits.history_item
                WHERE (history_items.url >= ?1 AND history_items.url < ?2) OR history_items.url = ?3
                ORDER BY history_visits.visit_time DESC LIMIT ?4
                """
            }
        }

        /// The instant a stored visit time stands for; nil for a value that is not one.
        func date(fromColumn statement: OpaquePointer?) -> Date? {
            switch self {
            case .chromium:
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { return nil }
                return BrowsingHistory.date(chromiumMicroseconds: sqlite3_column_int64(statement, 0))
            case .safari:
                let type = sqlite3_column_type(statement, 0)
                guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else { return nil }
                return BrowsingHistory.date(safariSeconds: sqlite3_column_double(statement, 0))
            }
        }
    }

    static func date(chromiumMicroseconds value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000_000 - chromiumEpochOffset)
    }

    static func date(safariSeconds value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: value)
    }

    /// The local calendar day `date` falls on in `timeZone`.
    static func day(of date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    /// The distinct local days among the most recent `maximumVisits` visits to `https://<host>`
    /// or a page under `https://<host>/`; empty when the file cannot be read.
    ///
    /// The prefix is the range `[https://host/, https://host0)`, `0` being the character after
    /// `/`: it compares byte for byte and uses the column's index, where `LIKE` folds case.
    private static func visitDays(
        to host: String,
        in file: URL,
        source: Source,
        timeZone: TimeZone
    ) -> Set<DateComponents> {
        withDatabase(file, source: source) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, source.query, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return []
            }
            defer { sqlite3_finalize(statement) }
            bind("https://\(host)/", to: statement, at: 1)
            bind("https://\(host)0", to: statement, at: 2)
            bind("https://\(host)", to: statement, at: 3)
            sqlite3_bind_int(statement, 4, Int32(maximumVisits))

            var days = Set<DateComponents>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let date = source.date(fromColumn: statement) {
                    days.insert(day(of: date, in: timeZone))
                }
            }
            return days
        } ?? []
    }

    /// Whether the query this type runs on `source`'s tables prepares, which it does exactly
    /// when the tables and columns it names exist.
    private static func hasSchema(of source: Source, in file: URL) -> Bool {
        withDatabase(file, source: source) { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            return sqlite3_prepare_v2(database, source.query, -1, &statement, nil) == SQLITE_OK
        } ?? false
    }

    /// Opens `file` read-only, runs `body`, and closes it; nil when the file is not a regular
    /// file or does not open.
    private static func withDatabase<Value>(
        _ file: URL,
        source: Source,
        _ body: (OpaquePointer) -> Value
    ) -> Value? {
        guard isRegularFile(file) else { return nil }
        var database: OpaquePointer?
        let opened: Int32
        switch source {
        case .chromium:
            guard let path = percentEncodedPath(file.path) else { return nil }
            opened = sqlite3_open_v2(
                "file:\(path)?mode=ro&immutable=1",
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                nil
            )
        case .safari:
            opened = sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil)
        }
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK, let database else { return nil }
        sqlite3_busy_timeout(database, 100)
        return body(database)
    }

    /// Binds `value` with its byte length.
    private static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient)
        }
    }

    /// The path with every byte but unreserved characters and `/` percent-encoded, so a `?`,
    /// `#`, or `%` in a folder name cannot end the path part of the URI.
    private static func percentEncodedPath(_ path: String) -> String? {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/"
        )
        return path.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
