import Foundation
import SQLite3
import Testing

@testable import SuperVisor

// MARK: - Fixtures

/// A scratch database with the subset of the Messages schema the store reads.
private final class MessagesFixture {
    let path: String
    private var database: OpaquePointer?

    init(path: String, writeAheadLog: Bool = false) throws {
        self.path = path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK
        else { throw FixtureError.sqlite }
        if writeAheadLog {
            try exec("PRAGMA journal_mode = WAL")
            // Rows stay in the log until this connection closes, so a reader must look there.
            try exec("PRAGMA wal_autocheckpoint = 0")
        }
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
            """)
    }

    func close() {
        sqlite3_close(database)
        database = nil
    }

    enum FixtureError: Error { case sqlite }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
    }

    @discardableResult
    func addHandle(_ id: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT INTO handle (id) VALUES (?1)", -1, &statement, nil) == SQLITE_OK
        else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        return sqlite3_last_insert_rowid(database)
    }

    @discardableResult
    func addMessage(
        text: String? = nil,
        body: Data? = nil,
        date: Int64,
        fromMe: Bool = false,
        handle: Int64? = nil
    ) throws -> Int64 {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO message (text, attributedBody, date, is_from_me, handle_id)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let text { sqlite3_bind_text(statement, 1, text, -1, transient) } else { sqlite3_bind_null(statement, 1) }
        if let body {
            _ = body.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(body.count), transient) }
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int64(statement, 3, date)
        sqlite3_bind_int(statement, 4, fromMe ? 1 : 0)
        if let handle { sqlite3_bind_int64(statement, 5, handle) } else { sqlite3_bind_null(statement, 5) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        return sqlite3_last_insert_rowid(database)
    }
}

/// Runs `body` against a scratch database in its own temporary directory.
private func withMessages<T>(
    writeAheadLog: Bool = false,
    _ body: (MessagesFixture, MessagesStore) throws -> T
) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("messages-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("chat.db").path
    let fixture = try MessagesFixture(path: path, writeAheadLog: writeAheadLog)
    defer { fixture.close() }
    return try body(fixture, MessagesStore(path: path))
}

/// Seconds since 2001-01-01 for the instants the tests use. Nanoseconds on current macOS.
private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func nanoseconds(_ offset: TimeInterval) -> Int64 {
    Int64((800_000_000 + offset) * 1e9)
}

private func seconds(_ offset: TimeInterval) -> Int64 {
    Int64(800_000_000 + offset)
}

/// A real typedstream, as `NSArchiver` writes it for an attributed string. The app never
/// unarchives; archiving is how the tests get genuine bytes.
private func archived(_ string: String) -> Data {
    NSArchiver.archivedData(withRootObject: NSAttributedString(string: string))
}

private func archivedWithAttributes(_ string: String) -> Data {
    let attributed = NSMutableAttributedString(string: string)
    attributed.addAttribute(
        NSAttributedString.Key("__kIMMessagePartAttributeName"),
        value: NSNumber(value: 0),
        range: NSRange(location: 0, length: attributed.length)
    )
    return NSArchiver.archivedData(withRootObject: attributed)
}

@Suite("Messages store")
struct MessagesStoreTests {
    @Test("The default path is the user's Messages database")
    func defaultPath() {
        #expect(MessagesStore.defaultPath == NSHomeDirectory() + "/Library/Messages/chat.db")
        #expect(MessagesStore().path == MessagesStore.defaultPath)
    }

    @Test("A message's fields come through, with the text from the column")
    func fieldsFromColumn() throws {
        try withMessages { fixture, store in
            let handle = try fixture.addHandle("+14155550123")
            let row = try fixture.addMessage(text: "hello", date: nanoseconds(0), fromMe: false, handle: handle)

            let messages = try store.messages(since: base.addingTimeInterval(-10), limit: 10)

            #expect(messages == [
                TextMessage(rowID: row, sender: "+14155550123", isFromMe: false, date: base, text: "hello"),
            ])
        }
    }

    @Test("Text that lives only in the blob is read, whatever its length or script")
    func textFromBlob() throws {
        let texts = [
            "Hi",
            String(repeating: "a", count: 127),
            String(repeating: "b", count: 128),
            String(repeating: "c", count: 255),
            String(repeating: "d", count: 256),
            String(repeating: "👋", count: 100),
            "你好，世界 Привет",
        ]
        try withMessages { fixture, store in
            let handle = try fixture.addHandle("24273")
            for (index, text) in texts.enumerated() {
                try fixture.addMessage(body: archived(text), date: nanoseconds(Double(index)), handle: handle)
            }

            let messages = try store.messages(since: base.addingTimeInterval(-10), limit: 50)

            #expect(messages.map(\.text) == texts.reversed())
        }
    }

    @Test("A column that is empty falls back to the blob, and a row with neither is skipped")
    func rowsWithoutText() throws {
        try withMessages { fixture, store in
            let handle = try fixture.addHandle("24273")
            try fixture.addMessage(text: "", body: archived("from blob"), date: nanoseconds(1), handle: handle)
            try fixture.addMessage(text: "", date: nanoseconds(2), handle: handle)
            try fixture.addMessage(date: nanoseconds(3), handle: handle)
            try fixture.addMessage(body: Data([1, 2, 3]), date: nanoseconds(4), handle: handle)
            try fixture.addMessage(text: "plain", date: nanoseconds(5), handle: handle)

            let messages = try store.messages(since: base.addingTimeInterval(-10), limit: 50)

            #expect(messages.map(\.text) == ["plain", "from blob"])
        }
    }

    @Test("A message with no handle has an empty sender, and outgoing ones are flagged")
    func unknownSenderAndOutgoing() throws {
        try withMessages { fixture, store in
            let handle = try fixture.addHandle("24273")
            try fixture.addMessage(text: "no handle", date: nanoseconds(1), handle: nil)
            try fixture.addMessage(text: "handle zero", date: nanoseconds(2), handle: 0)
            try fixture.addMessage(text: "outgoing", date: nanoseconds(3), fromMe: true, handle: handle)

            let messages = try store.messages(since: base.addingTimeInterval(-10), limit: 50)

            #expect(messages.map(\.text) == ["outgoing", "handle zero", "no handle"])
            #expect(messages.map(\.sender) == ["24273", "", ""])
            #expect(messages.map(\.isFromMe) == [true, false, false])
        }
    }

    @Test("Dates are read as nanoseconds on current macOS and seconds on old versions")
    func dateUnits() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "nanoseconds", date: nanoseconds(60))
            try fixture.addMessage(text: "seconds", date: seconds(30))

            let messages = try store.messages(since: base.addingTimeInterval(-10), limit: 10)

            #expect(messages.map(\.text) == ["nanoseconds", "seconds"])
            #expect(abs(messages[0].date.timeIntervalSince(base.addingTimeInterval(60))) < 0.001)
            #expect(abs(messages[1].date.timeIntervalSince(base.addingTimeInterval(30))) < 0.001)
        }
    }

    @Test("The since filter applies in both units, and includes the instant itself")
    func sinceFilter() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "old ns", date: nanoseconds(-100))
            try fixture.addMessage(text: "old s", date: seconds(-100))
            try fixture.addMessage(text: "at ns", date: nanoseconds(0))
            try fixture.addMessage(text: "at s", date: seconds(0))
            try fixture.addMessage(text: "new ns", date: nanoseconds(100))
            try fixture.addMessage(text: "new s", date: seconds(100))

            let messages = try store.messages(since: base, limit: 50)

            #expect(Set(messages.map(\.text)) == ["at ns", "at s", "new ns", "new s"])
            #expect(try store.messages(since: base.addingTimeInterval(1), limit: 50).map(\.text).sorted() == ["new ns", "new s"])
            #expect(try store.messages(since: base.addingTimeInterval(1_000), limit: 50).isEmpty)
            #expect(try store.messages(since: .distantPast, limit: 50).count == 6)
            #expect(try store.messages(since: .distantFuture, limit: 50).isEmpty)
        }
    }

    @Test("Messages come newest first, the later row first when dates tie")
    func ordering() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "middle", date: nanoseconds(50))
            try fixture.addMessage(text: "oldest", date: nanoseconds(10))
            try fixture.addMessage(text: "tie first", date: nanoseconds(90))
            try fixture.addMessage(text: "newest", date: nanoseconds(100))
            try fixture.addMessage(text: "tie second", date: nanoseconds(90))

            let messages = try store.messages(since: base, limit: 50)

            #expect(messages.map(\.text) == ["newest", "tie second", "tie first", "middle", "oldest"])
        }
    }

    @Test("The sender filter matches the handle exactly, short codes included")
    func senderFilter() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let longer = try fixture.addHandle("242730")
            let phone = try fixture.addHandle("+14155550123")
            let mail = try fixture.addHandle("alerts@example.com")
            try fixture.addMessage(text: "from bank", date: nanoseconds(1), handle: bank)
            try fixture.addMessage(text: "from longer", date: nanoseconds(2), handle: longer)
            try fixture.addMessage(text: "from phone", date: nanoseconds(3), handle: phone)
            try fixture.addMessage(text: "from mail", date: nanoseconds(4), handle: mail)
            try fixture.addMessage(text: "from nobody", date: nanoseconds(5), handle: nil)
            let since = base.addingTimeInterval(-10)

            #expect(try store.messages(since: since, sender: "24273", limit: 10).map(\.text) == ["from bank"])
            #expect(try store.messages(since: since, sender: "+14155550123", limit: 10).map(\.text) == ["from phone"])
            #expect(try store.messages(since: since, sender: "alerts@example.com", limit: 10).map(\.text) == ["from mail"])
            #expect(try store.messages(since: since, sender: "2427", limit: 10).isEmpty)
            #expect(try store.messages(since: since, sender: "ALERTS@EXAMPLE.COM", limit: 10).isEmpty)
            #expect(try store.messages(since: since, sender: "", limit: 10).isEmpty)
            #expect(try store.messages(since: since, sender: nil, limit: 10).count == 5)
        }
    }

    @Test("A sender is a value to compare, never part of the query")
    func senderIsBound() throws {
        try withMessages { fixture, store in
            let handle = try fixture.addHandle("24273")
            try fixture.addMessage(text: "kept", date: nanoseconds(1), handle: handle)

            for sender in ["' OR '1'='1", "24273' --", "24273\" OR 1=1 --", "24273\u{0000}x", "%", "_____"] {
                #expect(try store.messages(since: base.addingTimeInterval(-10), sender: sender, limit: 10).isEmpty, "\(sender)")
            }
            #expect(try store.messages(since: base.addingTimeInterval(-10), limit: 10).count == 1)
        }
    }

    @Test("The text filter ignores case, reaches text held only in the blob, and an empty one filters nothing")
    func containingFilter() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "Please VERIFY your account", date: nanoseconds(1))
            try fixture.addMessage(body: archived("Your Verification code is 123456"), date: nanoseconds(2))
            try fixture.addMessage(text: "Lunch tomorrow?", date: nanoseconds(3))
            let since = base.addingTimeInterval(-10)

            #expect(try store.messages(since: since, containing: "verif", limit: 10).map(\.text)
                == ["Your Verification code is 123456", "Please VERIFY your account"])
            #expect(try store.messages(since: since, containing: "VERIFICATION CODE", limit: 10).count == 1)
            #expect(try store.messages(since: since, containing: "lunch", limit: 10).count == 1)
            #expect(try store.messages(since: since, containing: "absent", limit: 10).isEmpty)
            #expect(try store.messages(since: since, containing: "", limit: 10).count == 3)
        }
    }

    @Test("The limit is clamped to 1 through 200 and applied after the text filter")
    func limits() throws {
        try withMessages { fixture, store in
            try fixture.exec("BEGIN")
            for index in 0..<250 {
                try fixture.addMessage(text: index.isMultiple(of: 5) ? "match \(index)" : "other \(index)", date: nanoseconds(Double(index)))
            }
            try fixture.exec("COMMIT")
            let since = base.addingTimeInterval(-10)

            #expect(try store.messages(since: since, limit: 3).map(\.text) == ["other 249", "other 248", "other 247"])
            #expect(try store.messages(since: since, limit: 1).count == 1)
            #expect(try store.messages(since: since, limit: 0).count == 1)
            #expect(try store.messages(since: since, limit: -5).count == 1)
            #expect(try store.messages(since: since, limit: 200).count == 200)
            #expect(try store.messages(since: since, limit: 5_000).count == 200)
            #expect(try store.messages(since: since, containing: "match", limit: 2).map(\.text) == ["match 245", "match 240"])
        }
    }

    @Test("Only the newest 2,000 rows are examined")
    func scanCap() throws {
        for (newer, expectFound) in [(1_999, true), (2_000, false)] {
            try withMessages { fixture, store in
                try fixture.exec("BEGIN")
                try fixture.addMessage(text: "needle", date: nanoseconds(0))
                for index in 0..<newer {
                    try fixture.addMessage(text: "hay", date: nanoseconds(Double(index + 1)))
                }
                try fixture.exec("COMMIT")

                let found = try store.messages(since: base.addingTimeInterval(-10), containing: "needle", limit: 5)

                #expect(found.count == (expectFound ? 1 : 0), "\(newer) newer rows")
            }
        }
    }

    @Test("Rows still in the write-ahead log are read")
    func writeAheadLog() throws {
        try withMessages(writeAheadLog: true) { fixture, store in
            let handle = try fixture.addHandle("24273")
            try fixture.addMessage(text: "only in the log", date: nanoseconds(1), handle: handle)

            #expect(FileManager.default.fileExists(atPath: store.path + "-wal"))
            #expect(try store.messages(since: base.addingTimeInterval(-10), limit: 10).map(\.text) == ["only in the log"])

            // A later write is seen by the next call, which opens a fresh connection.
            try fixture.addMessage(text: "arrived later", date: nanoseconds(2), handle: handle)
            #expect(try store.messages(since: base.addingTimeInterval(-10), limit: 10).map(\.text)
                == ["arrived later", "only in the log"])
        }
    }

    @Test("Reading never writes to the database or creates one")
    func readOnly() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "kept", date: nanoseconds(1))
            let before = try Data(contentsOf: URL(fileURLWithPath: store.path))

            _ = try store.messages(since: .distantPast, limit: 10)

            #expect(try Data(contentsOf: URL(fileURLWithPath: store.path)) == before)
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("absent-\(UUID().uuidString).db").path
        #expect(throws: MessagesStore.Failure.unreadable) {
            try MessagesStore(path: missing).messages(since: .distantPast, limit: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test("The connection every read uses cannot write")
    func connectionIsReadOnly() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "kept", date: nanoseconds(1))

            let connection = try store.openConnection()
            defer { sqlite3_close(connection) }

            #expect(
                sqlite3_exec(connection, "INSERT INTO message (text, date) VALUES ('added', 1)", nil, nil, nil)
                    == SQLITE_READONLY
            )
            #expect(sqlite3_exec(connection, "UPDATE message SET text = 'changed'", nil, nil, nil) == SQLITE_READONLY)
            #expect(sqlite3_exec(connection, "DROP TABLE message", nil, nil, nil) == SQLITE_READONLY)
            #expect(sqlite3_db_readonly(connection, "main") == 1)
            #expect(try store.messages(since: .distantPast, limit: 10).map(\.text) == ["kept"])
        }
    }

    @Test("A database that cannot be opened or is not the Messages schema is unreadable")
    func unreadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("messages-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let garbage = directory.appendingPathComponent("garbage.db")
        try Data("this is not a database, it is just text of some length".utf8).write(to: garbage)
        let empty = directory.appendingPathComponent("empty.db")
        try Data().write(to: empty)
        let noSchema = directory.appendingPathComponent("noschema.db")
        let fixture = try MessagesFixture(path: noSchema.path)
        try fixture.exec("DROP TABLE message")
        fixture.close()

        for path in [
            directory.appendingPathComponent("missing.db").path,
            directory.path,
            garbage.path,
            empty.path,
            noSchema.path,
            "",
        ] {
            #expect(throws: MessagesStore.Failure.unreadable, "\(path)") {
                try MessagesStore(path: path).messages(since: .distantPast, limit: 1)
            }
            #expect(throws: MessagesStore.Failure.unreadable, "\(path)") {
                try MessagesStore(path: path).latestRowID()
            }
            #expect(throws: MessagesStore.Failure.unreadable, "\(path)") {
                try MessagesStore(path: path).latestCode(afterRowID: 0, sender: "24273")
            }
            #expect(throws: MessagesStore.Failure.unreadable, "\(path)") {
                try MessagesStore(path: path).messagesForModel(since: .distantPast, limit: 1)
            }
        }
    }

    @Test(
        "A file the system refuses to open is access denied, not unreadable",
        .enabled(if: getuid() != 0)
    )
    func accessDenied() throws {
        try withMessages { fixture, store in
            try fixture.addMessage(text: "hidden", date: nanoseconds(1))
            fixture.close()
            #expect(try store.messages(since: .distantPast, limit: 10).count == 1)

            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path) }

            #expect(throws: MessagesStore.Failure.accessDenied) {
                try store.messages(since: .distantPast, limit: 10)
            }
            #expect(throws: MessagesStore.Failure.accessDenied) {
                try store.messagesForModel(since: .distantPast, limit: 10)
            }
            #expect(throws: MessagesStore.Failure.accessDenied) {
                try store.latestRowID()
            }
            #expect(throws: MessagesStore.Failure.accessDenied) {
                try store.latestCode(afterRowID: 0, sender: "24273")
            }
        }
    }

    @Test("Damaged data pages are malformed, not an empty result")
    func malformed() throws {
        try withMessages { fixture, store in
            try fixture.exec("BEGIN")
            for index in 0..<400 {
                try fixture.addMessage(text: String(repeating: "x", count: 200) + "\(index)", date: nanoseconds(Double(index)))
            }
            try fixture.exec("COMMIT")
            fixture.close()

            let url = URL(fileURLWithPath: store.path)
            var bytes = try Data(contentsOf: url)
            let page = 4_096
            #expect(bytes.count > 6 * page)
            for pageIndex in 2..<(bytes.count / page) {
                bytes.replaceSubrange((pageIndex * page)..<((pageIndex + 1) * page), with: Data(repeating: 0xFF, count: page))
            }
            try bytes.write(to: url)

            #expect(throws: MessagesStore.Failure.malformed) {
                try store.messages(since: .distantPast, limit: 10)
            }
        }
    }

    // MARK: Latest code

    @Test("The latest row id is 0 for an empty table and otherwise the newest row's id")
    func latestRowID() throws {
        try withMessages { fixture, store in
            #expect(try store.latestRowID() == 0)

            let handle = try fixture.addHandle("24273")
            try fixture.addMessage(text: "one", date: nanoseconds(1), handle: handle)
            let last = try fixture.addMessage(text: "two", date: nanoseconds(2), fromMe: true, handle: handle)
            #expect(try store.latestRowID() == last)

            // A row without text still advances it.
            let bare = try fixture.addMessage(date: nanoseconds(3), handle: handle)
            #expect(bare == last + 1)
            #expect(try store.latestRowID() == bare)
        }
    }

    @Test("A code is read only from rows that arrived after the baseline, so one code serves once")
    func codeIsNotReused() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            try fixture.addMessage(text: "Your code is 111111", date: nanoseconds(10), handle: bank)
            let baseline = try store.latestRowID()
            #expect(try store.latestCode(afterRowID: baseline, sender: "24273") == nil)

            let arrived = try fixture.addMessage(text: "Your code is 222222", date: nanoseconds(20), handle: bank)
            let found = try #require(try store.latestCode(afterRowID: baseline, sender: "24273"))
            #expect(found.code == "222222")
            #expect(found.rowID == arrived)

            // Taking the found row as the new baseline leaves nothing to reuse.
            #expect(try store.latestCode(afterRowID: found.rowID, sender: "24273") == nil)
            // The earlier attempt's code is out of reach from any later baseline.
            #expect(try store.latestCode(afterRowID: baseline, sender: "24273")?.code != "111111")
        }
    }

    @Test("The newest row wins, whatever its sender's clock says")
    func newestByArrival() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let baseline = try store.latestRowID()
            // Arrives first, stamped far in the future.
            try fixture.addMessage(text: "Your code is 111111", date: nanoseconds(1_000_000), handle: bank)
            // Arrives second, stamped in the past.
            let second = try fixture.addMessage(text: "Your code is 222222", date: nanoseconds(-1_000_000), handle: bank)

            let found = try #require(try store.latestCode(afterRowID: baseline, sender: "24273"))

            #expect(found.code == "222222")
            #expect(found.rowID == second)
        }
    }

    @Test("Only incoming messages from the named sender supply a code, matched exactly")
    func codeSenderRules() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let longer = try fixture.addHandle("242730")
            let shop = try fixture.addHandle("+14155550123")
            let baseline = try store.latestRowID()
            try fixture.addMessage(text: "Your code is 111111", date: nanoseconds(10), handle: bank)
            try fixture.addMessage(text: "Your code is 222222", date: nanoseconds(20), handle: longer)
            try fixture.addMessage(text: "Your verification code is 333333", date: nanoseconds(30), handle: shop)
            try fixture.addMessage(text: "My code is 999999", date: nanoseconds(40), fromMe: true, handle: bank)
            try fixture.addMessage(text: "Your code is 888888", date: nanoseconds(50), handle: nil)

            #expect(try store.latestCode(afterRowID: baseline, sender: "24273")?.code == "111111")
            #expect(try store.latestCode(afterRowID: baseline, sender: "242730")?.code == "222222")
            #expect(try store.latestCode(afterRowID: baseline, sender: "+14155550123")?.code == "333333")
            #expect(try store.latestCode(afterRowID: baseline, sender: "2427") == nil)
            #expect(try store.latestCode(afterRowID: baseline, sender: "") == nil)
            #expect(try store.latestCode(afterRowID: baseline, sender: "' OR '1'='1") == nil)
        }
    }

    @Test("Outgoing messages never supply a code")
    func latestCodeIgnoresOutgoing() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let baseline = try store.latestRowID()
            try fixture.addMessage(text: "Your code is 111111", date: nanoseconds(10), handle: bank)
            try fixture.addMessage(text: "Reply with code 888888", date: nanoseconds(20), fromMe: true, handle: bank)

            #expect(try store.latestCode(afterRowID: baseline, sender: "24273")?.code == "111111")
        }
    }

    @Test("A message that merely mentions digits is not a code, and a code in the blob is found")
    func latestCodeNeedsAKeyword() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let baseline = try store.latestRowID()
            try fixture.addMessage(text: "Your balance is $1234.56", date: nanoseconds(10), handle: bank)
            try fixture.addMessage(text: "Call 555-123-4567", date: nanoseconds(20), handle: bank)
            try fixture.addMessage(text: "Meeting room 4821", date: nanoseconds(30), handle: bank)
            #expect(try store.latestCode(afterRowID: baseline, sender: "24273") == nil)

            try fixture.addMessage(body: archived("Use 482910 to sign in"), date: nanoseconds(40), handle: bank)
            #expect(try store.latestCode(afterRowID: baseline, sender: "24273")?.code == "482910")
        }
    }

    @Test("The code is the number after the code word, not an account number before it")
    func latestCodePicksTheCode() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let baseline = try store.latestRowID()
            try fixture.addMessage(
                text: "Wells Fargo: for acct ending 1234 your code is 567890",
                date: nanoseconds(10),
                handle: bank
            )

            #expect(try store.latestCode(afterRowID: baseline, sender: "24273")?.code == "567890")
        }
    }

    // MARK: For a model

    @Test(
        "Each masking keyword hides the numbers in its message, in any case",
        arguments: [
            "code", "passcode", "pin", "otp", "password", "token", "2fa", "verification", "verify",
            "login", "log in", "sign in", "sign-in", "authentication", "security", "código", "codigo",
            "bestätigungscode", "vérification",
        ]
    )
    func keywordFamiliesMask(_ keyword: String) throws {
        try withMessages { fixture, store in
            let person = try fixture.addHandle("+14155550123")
            try fixture.addMessage(text: "Your \(keyword) is 482910", date: nanoseconds(1), handle: person)
            try fixture.addMessage(text: "YOUR \(keyword.uppercased()) IS 482910", date: nanoseconds(2), handle: person)
            try fixture.addMessage(body: archived("Your \(keyword) is 482910"), date: nanoseconds(3), handle: person)

            let seen = try store.messagesForModel(since: .distantPast, limit: 10)

            #expect(seen.count == 3)
            for message in seen {
                #expect(message.text.contains("••••"), "\(message.text)")
                #expect(!message.text.contains("482910"), "\(message.text)")
            }
            // The raw read is unmasked.
            #expect(try store.messages(since: .distantPast, limit: 10).allSatisfy { $0.text.contains("482910") })
        }
    }

    @Test("A short-code sender masks its messages with no keyword at all")
    func shortCodeSenderMasks() throws {
        try withMessages { fixture, store in
            let short = try fixture.addHandle("24273")
            let three = try fixture.addHandle("123")
            let eight = try fixture.addHandle("12345678")
            let nine = try fixture.addHandle("123456789")
            try fixture.addMessage(text: "482910", date: nanoseconds(1), handle: short)
            try fixture.addMessage(text: "Table 1234 is ready", date: nanoseconds(2), handle: three)
            try fixture.addMessage(text: "Table 1234 is ready", date: nanoseconds(3), handle: eight)
            try fixture.addMessage(text: "Table 1234 is ready", date: nanoseconds(4), handle: nine)

            let seen = try store.messagesForModel(since: .distantPast, limit: 10)

            #expect(seen.map(\.text) == ["Table 1234 is ready", "Table •••• is ready", "Table •••• is ready", "••••"])
        }
    }

    @Test("An ordinary message from a person with a number and no keyword is left alone")
    func ordinaryMessagesUntouched() throws {
        try withMessages { fixture, store in
            let person = try fixture.addHandle("+14155550123")
            let mail = try fixture.addHandle("friend@example.com")
            try fixture.addMessage(text: "Dinner at 7pm, room 1234", date: nanoseconds(1), handle: person)
            try fixture.addMessage(text: "Call me on 555-123-4567 about zipcode 90210", date: nanoseconds(2), handle: mail)
            try fixture.addMessage(text: "I decoded the hotpot receipt: 12345678", date: nanoseconds(3), handle: person)

            let seen = try store.messagesForModel(since: .distantPast, limit: 10)

            #expect(seen.map(\.text) == [
                "I decoded the hotpot receipt: 12345678",
                "Call me on 555-123-4567 about zipcode 90210",
                "Dinner at 7pm, room 1234",
            ])
            #expect(seen == (try store.messages(since: .distantPast, limit: 10)))
        }
    }

    @Test("A search matches the masked text, so a guessed code finds nothing")
    func searchSeesMaskedText() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            try fixture.addMessage(text: "Your code is 482910", date: nanoseconds(1), handle: bank)
            try fixture.addMessage(text: "Your code is 123 456", date: nanoseconds(2), handle: bank)
            let since = base.addingTimeInterval(-10)

            #expect(try store.messagesForModel(since: since, containing: "482910", limit: 10).isEmpty)
            #expect(try store.messagesForModel(since: since, containing: "4829", limit: 10).isEmpty)
            #expect(try store.messagesForModel(since: since, containing: "123 456", limit: 10).isEmpty)
            #expect(try store.messagesForModel(since: since, containing: "••••", limit: 10).count == 2)
            #expect(try store.messagesForModel(since: since, containing: "your code", limit: 10).count == 2)
            // The raw read still finds it.
            #expect(try store.messages(since: since, containing: "482910", limit: 10).count == 1)
        }
    }

    @Test("The model read applies the sender filter, ordering, and limit as the raw read does")
    func modelReadFilters() throws {
        try withMessages { fixture, store in
            let bank = try fixture.addHandle("24273")
            let person = try fixture.addHandle("+14155550123")
            try fixture.addMessage(text: "Code 111111", date: nanoseconds(1), handle: bank)
            try fixture.addMessage(text: "hello", date: nanoseconds(2), handle: person)
            try fixture.addMessage(text: "Code 222222", date: nanoseconds(3), handle: bank)
            let since = base.addingTimeInterval(-10)

            #expect(try store.messagesForModel(since: since, sender: "24273", limit: 10).map(\.text)
                == ["Code ••••", "Code ••••"])
            #expect(try store.messagesForModel(since: since, limit: 2).map(\.text) == ["Code ••••", "hello"])
            #expect(try store.messagesForModel(since: since, limit: 10).map(\.rowID)
                == (try store.messages(since: since, limit: 10).map(\.rowID)))
        }
    }
}

// MARK: - Nested suites

extension MessagesStoreTests {
    @Suite("Message bodies")
    struct BodyTests {
        @Test("The text column is the text when it holds any")
        func columnWins() {
            let blob = archived("from the blob")

            #expect(MessageBody.text(column: "from the column", attributedBody: blob) == "from the column")
            #expect(MessageBody.text(column: "from the column", attributedBody: nil) == "from the column")
        }

        @Test("An empty or missing column falls back to the blob, and with no blob there is no text")
        func columnFallsBack() {
            let blob = archived("from the blob")

            #expect(MessageBody.text(column: "", attributedBody: blob) == "from the blob")
            #expect(MessageBody.text(column: nil, attributedBody: blob) == "from the blob")
            #expect(MessageBody.text(column: "", attributedBody: nil) == nil)
            #expect(MessageBody.text(column: nil, attributedBody: nil) == nil)
            #expect(MessageBody.text(column: nil, attributedBody: Data()) == nil)
        }

        @Test(
            "Text archived in the blob comes back whole",
            arguments: [
                "Hi",
                "Your verification code is 123456",
                "line one\nline two",
                String(repeating: "a", count: 127),
                String(repeating: "b", count: 128),
                String(repeating: "c", count: 200),
                String(repeating: "d", count: 255),
                String(repeating: "e", count: 256),
                String(repeating: "f", count: 300),
                String(repeating: "g", count: 5_000),
                String(repeating: "h", count: MessageBody.maximumTextBytes),
                "Hi 👋 there",
                String(repeating: "👋", count: 100),
                "你好，世界",
                "Привет, мир",
                "مرحبا بالعالم",
                "🧑‍🧑‍🧒‍🧒 family e\u{301}",
            ]
        )
        func blobText(_ text: String) {
            #expect(MessageBody.text(column: nil, attributedBody: archived(text)) == text)
            #expect(MessageBody.text(column: nil, attributedBody: archivedWithAttributes(text)) == text)
        }

        @Test("The length is one byte below 128, then 0x81 and two bytes, little-endian")
        func lengthEncoding() {
            let encoding: [UInt8] = [0x84, 0x01, 0x2B]
            func lengthBytes(_ count: Int) -> [UInt8] {
                let blob = [UInt8](archived(String(repeating: "x", count: count)))
                guard let at = blob.indices.first(where: { blob[$0...].starts(with: encoding) }) else { return [] }
                let start = at + encoding.count
                let width = blob[start] == 0x81 ? 3 : 1
                return Array(blob[start..<(start + width)])
            }

            #expect(lengthBytes(2) == [0x02])
            #expect(lengthBytes(127) == [0x7F])
            #expect(lengthBytes(128) == [0x81, 0x80, 0x00])
            #expect(lengthBytes(255) == [0x81, 0xFF, 0x00])
            #expect(lengthBytes(256) == [0x81, 0x00, 0x01])
            #expect(lengthBytes(300) == [0x81, 0x2C, 0x01])
        }

        @Test("A four-byte length is read")
        func fourByteLength() {
            var blob = [UInt8](archived("Hi"))
            let at = blob.indices.first { blob[$0...].starts(with: [0x84, 0x01, 0x2B, 0x02, 0x48, 0x69]) }!
            blob.replaceSubrange((at + 3)...(at + 3), with: [0x82, 0x02, 0x00, 0x00, 0x00])

            #expect(MessageBody.text(column: nil, attributedBody: Data(blob)) == "Hi")
        }

        @Test("Text over the cap reads as absent in both places")
        func overlongText() {
            let atCap = String(repeating: "a", count: MessageBody.maximumTextBytes)
            let overCap = atCap + "a"

            #expect(MessageBody.text(column: atCap, attributedBody: nil) == atCap)
            #expect(MessageBody.text(column: overCap, attributedBody: nil) == nil)
            #expect(MessageBody.text(column: nil, attributedBody: archived(atCap)) == atCap)
            #expect(MessageBody.text(column: nil, attributedBody: archived(overCap)) == nil)
            // The multi-byte case counts bytes, not characters.
            let emoji = String(repeating: "👋", count: MessageBody.maximumTextBytes / 4)
            #expect(emoji.utf8.count == MessageBody.maximumTextBytes)
            #expect(MessageBody.text(column: nil, attributedBody: archived(emoji)) == emoji)
            #expect(MessageBody.text(column: nil, attributedBody: archived(emoji + "👋")) == nil)
        }

        @Test("An archive cut short at any point yields the text only once the whole string is present")
        func truncation() throws {
            let text = "Truncate me please"
            let blob = archived(text)
            let payload = try #require(blob.range(of: Data(text.utf8)))

            for length in 0...blob.count {
                let result = MessageBody.text(column: nil, attributedBody: blob.prefix(length))
                if length < payload.upperBound {
                    #expect(result == nil, "prefix of \(length) bytes")
                } else {
                    #expect(result == text, "prefix of \(length) bytes")
                }
            }
        }

        @Test("A length that claims more bytes than the archive holds yields nothing")
        func lengthBeyondBuffer() throws {
            let text = "Hi"
            let blob = archived(text)
            let payload = try #require(blob.range(of: Data(text.utf8)))
            let lengthIndex = payload.lowerBound - 1
            #expect(blob[lengthIndex] == 0x02)

            // Cut right after the payload, a length of 2 fits exactly and 3 does not.
            let cut = Data(blob.prefix(payload.upperBound))
            #expect(MessageBody.text(column: nil, attributedBody: cut) == text)
            var claimsOneMore = cut
            claimsOneMore[lengthIndex] = 0x03
            #expect(MessageBody.text(column: nil, attributedBody: claimsOneMore) == nil)

            // Each width of length field, claiming far more than follows.
            let head = Data(blob.prefix(lengthIndex))
            let tail = Data(blob.suffix(from: payload.lowerBound))
            let claims: [[UInt8]] = [
                [0x7F],
                [0x81, 0x00, 0x10],
                [0x81, 0xFF, 0xFF],
                [0x82, 0x00, 0x10, 0x00, 0x00],
                [0x82, 0xFF, 0xFF, 0xFF, 0xFF],
                [0x82, 0xFF, 0xFF, 0xFF, 0x7F],
            ]
            for claim in claims {
                let forged = head + Data(claim) + tail
                #expect(MessageBody.text(column: nil, attributedBody: forged) == nil, "claim \(claim)")
            }
        }

        @Test("A length field cut off mid-way yields nothing")
        func lengthFieldTruncated() throws {
            let blob = [UInt8](archived(String(repeating: "x", count: 300)))
            let at = try #require(blob.indices.first { blob[$0...].starts(with: [0x84, 0x01, 0x2B, 0x81]) })

            for length in (at + 3)...(at + 5) {
                #expect(MessageBody.text(column: nil, attributedBody: Data(blob.prefix(length))) == nil)
            }
            let fourByte = Data(blob.prefix(at + 3) + [0x82, 0x01, 0x00])
            #expect(MessageBody.text(column: nil, attributedBody: fourByte) == nil)
        }

        @Test("Bytes that are not an archive of a string yield nothing")
        func garbage() throws {
            let valid = archived("Hello there")
            let payload = try #require(valid.range(of: Data("Hello there".utf8)))
            let lengthIndex = payload.lowerBound - 1

            func mutated(_ change: (inout [UInt8]) -> Void) -> Data {
                var bytes = [UInt8](valid)
                change(&bytes)
                return Data(bytes)
            }
            func replacing(_ old: [UInt8], with new: [UInt8], in bytes: inout [UInt8]) {
                if let at = bytes.indices.first(where: { bytes[$0...].starts(with: old) }) {
                    bytes.replaceSubrange(at..<(at + old.count), with: new)
                }
            }

            let header = [UInt8]([0x04, 0x0B]) + Array("streamtyped".utf8)
            let cases: [(String, Data)] = [
                ("empty", Data()),
                ("one byte", Data([0x04])),
                ("header only", Data(header)),
                ("plain text", Data("hello world, this is not an archive".utf8)),
                ("zeros", Data(repeating: 0, count: 1_000)),
                ("ones", Data(repeating: 0xFF, count: 1_000)),
                ("header and noise", Data(header + (0..<300).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })),
                ("wrong magic", mutated { $0[2] = 0x53 }),
                ("wrong version", mutated { $0[0] = 0x03 }),
                ("class name altered", mutated { replacing(Array("NSString".utf8), with: Array("NSStrinX".utf8), in: &$0) }),
                ("class name absent", mutated { replacing(Array("NSString".utf8), with: Array("NSNumber".utf8), in: &$0) }),
                ("type encoding altered", mutated { replacing([0x84, 0x01, 0x2B], with: [0x84, 0x01, 0x2A], in: &$0) }),
                ("zero length", mutated { $0[lengthIndex] = 0x00 }),
                ("length tag 0x80", mutated { $0[lengthIndex] = 0x80 }),
                ("length tag 0x83", mutated { $0[lengthIndex] = 0x83 }),
                ("length tag 0xFF", mutated { $0[lengthIndex] = 0xFF }),
                ("invalid UTF-8", mutated { $0[payload.lowerBound] = 0xC3; $0[payload.lowerBound + 1] = 0x28 }),
                ("lone continuation byte", mutated { $0[payload.lowerBound] = 0x80 }),
                ("overlong encoding", mutated { $0[payload.lowerBound] = 0xC0; $0[payload.lowerBound + 1] = 0xAF }),
            ]
            for (name, data) in cases {
                #expect(MessageBody.text(column: nil, attributedBody: data) == nil, "\(name)")
            }
        }

        @Test("Single-byte changes anywhere in an archive never crash the reader")
        func mutationsDoNotCrash() {
            let valid = [UInt8](archived(String(repeating: "x", count: 300)))
            for index in valid.indices {
                for value in [UInt8(0x00), 0x01, 0x2B, 0x7F, 0x80, 0x81, 0x82, 0x84, 0xFF] {
                    var bytes = valid
                    bytes[index] = value
                    let text = MessageBody.text(column: nil, attributedBody: Data(bytes))
                    #expect((text?.utf8.count ?? 0) <= MessageBody.maximumTextBytes)
                }
            }
        }

        @Test(
            "Text that itself holds the class name and the type-encoding bytes still extracts exactly",
            arguments: [
                "NSString",
                "NSString Ą\u{01}+",
                "streamtyped NSString Ą\u{01}+ 84 01 2b",
                "NSMutableString NSAttributedString NSString\u{01}Ą\u{01}+\u{05}hello",
                "Ą\u{01}+Ą\u{01}+Ą\u{01}+",
                String(repeating: "NSString Ą\u{01}+ ", count: 40),
            ]
        )
        func textHoldingMarkers(_ text: String) {
            // U+0104 is the bytes C4 84, so the text carries 84 01 2b.
            #expect(text.contains("Ą\u{01}+") || !text.contains("Ą"))

            #expect(MessageBody.text(column: nil, attributedBody: archived(text)) == text)
            #expect(MessageBody.text(column: nil, attributedBody: archivedWithAttributes(text)) == text)
        }

        @Test("Marker bytes in the text do not move where the string is read from")
        func markerBytesInTextAreNotTheMarker() throws {
            let text = "NSString Ą\u{01}+\u{05}XXXXX"
            #expect(Data(text.utf8).range(of: Data([0x84, 0x01, 0x2B])) != nil)
            let blob = archived(text)
            let payload = try #require(blob.range(of: Data(text.utf8)))

            // Cut inside the text: the real length claims bytes that are missing, so a reader
            // that took the embedded marker for the real one would answer with other bytes.
            for length in 0..<payload.upperBound {
                #expect(MessageBody.text(column: nil, attributedBody: blob.prefix(length)) == nil, "\(length)")
            }
            #expect(MessageBody.text(column: nil, attributedBody: blob.prefix(payload.upperBound)) == text)
        }

        @Test("An archive over the size cap is not examined")
        func oversizedArchive() {
            var blob = archived("Hi")
            blob.append(Data(repeating: 0, count: MessageBody.maximumArchiveBytes))

            #expect(MessageBody.text(column: nil, attributedBody: blob) == nil)
        }
    }

    @Suite("Sign-in codes")
    struct SignInCodeTests {
        @Test(
            "A standing-alone run of 4 to 8 digits is the code",
            arguments: [
                ("Your code is 1234", "1234"),
                ("Your code is 12345", "12345"),
                ("123456 is your code", "123456"),
                ("code: 1234567", "1234567"),
                ("code: 12345678.", "12345678"),
                ("Use 482913 to sign in", "482913"),
                ("G-123456 is your verification code", "123456"),
                ("Order 12 ships; your code is 345678", "345678"),
                ("ref 123 then 4567", "4567"),
                ("Your code:\n0042", "0042"),
                ("On 2026-11-16 your code is 654321", "654321"),
                ("(654321)", "654321"),
                ("Wells Fargo: for acct ending 1234 your code is 567890", "567890"),
                ("Nov 16 2026: your code is 482910", "482910"),
                ("482910 is your verification code", "482910"),
                ("Your code is 123 456", "123456"),
                ("Use 123-456 to sign in. Code expires in 10 minutes", "123456"),
                ("Meeting room 4821 at 7pm", "4821"),
            ]
        )
        func found(_ text: String, _ expected: String) {
            #expect(SignInCode.code(in: text) == expected)
        }

        @Test(
            "The first number after a code word is the code, wherever other numbers sit",
            arguments: [
                ("Order 112233 shipped. Your code is 445566", "445566"),
                ("Ref 9876 - your PIN is 4455", "4455"),
                ("Reference 556677, one-time password 889900", "889900"),
                ("Your token 123456 expires 654321", "123456"),
                ("Tu código es 123456", "123456"),
                ("Pedido 998877. Tu codigo es 123456", "123456"),
                ("Pedido 998877. Tu co\u{0301}digo es 123456", "123456"),
                ("ORDER 112233. YOUR CODE IS 445566", "445566"),
                // No code word follows 1234, so the first candidate stands.
                ("Reference 1234 and 5678, code withheld", "1234"),
            ]
        )
        func afterCodeWord(_ text: String, _ expected: String) {
            #expect(SignInCode.code(in: text) == expected)
        }

        @Test(
            "A number named by an account word is not a candidate",
            arguments: [
                ("Card ending 4821 was charged $1234.56", nil),
                ("acct ending in 1234", nil),
                ("Account #1234 has a balance", nil),
                ("ACCT: 1234", nil),
                ("card x4821", nil),
                ("card X4821", nil),
                ("Card ****4821", nil),
                ("Visa ends in 4821", nil),
                ("Last 4: 4821", nil),
                ("last four 4821", nil),
                ("acct ending  in 1234", nil),
                ("acct ending\u{00A0}in 1234", nil),
                ("acct\tending 1234", nil),
                ("Account ending 1234, code 567890", "567890"),
                ("Your card ending 1234 code 5678", "5678"),
                // The account word must stand alone: `pending` is not `ending`, `discard` not `card`.
                ("Payment pending 1234", "1234"),
                ("Please discard 1234", "1234"),
                // Only the listed fillers may sit between the word and the digits.
                ("Account number 1234", "1234"),
            ] as [(String, String?)]
        )
        func accountReferences(_ text: String, _ expected: String?) {
            #expect(SignInCode.code(in: text) == expected)
        }

        @Test(
            "Grouped codes read as six digits",
            arguments: [
                ("Your code is 123 456", "123456"),
                ("Your code is 123-456", "123456"),
                ("123-456 is your code", "123456"),
                ("G-123 456 is your code", "123456"),
                ("Code: 123 456.", "123456"),
                ("Your code is 123456 or 123-456", "123456"),
            ]
        )
        func grouped(_ text: String, _ expected: String) {
            #expect(SignInCode.code(in: text) == expected)
        }

        @Test(
            "Groups that are part of a longer number are not a code",
            arguments: [
                "Phone 555-123-4567",
                "Phone 1-800-555-1234",
                "Call (415) 555-1234",
                "Total 123.456",
                "Part 123-456-789",
                "Date 2026-123-456",
            ]
        )
        func groupsInLongerNumbers(_ text: String) {
            #expect(SignInCode.code(in: text) == nil)
        }

        @Test("The masked text hides every run of 3 to 8 digits, so no group of a code is left")
        func masking() {
            #expect(SignInCode.masked("Your code is 482910") == "Your code is ••••")
            #expect(SignInCode.masked("1234") == "••••")
            #expect(SignInCode.masked("12345678") == "••••")
            #expect(SignInCode.masked("G-482910 or 111111") == "G-•••• or ••••")
            #expect(SignInCode.masked("Use 123 456 now") == "Use •••• •••• now")
            #expect(SignInCode.masked("Use 123-456 now") == "Use ••••-•••• now")
            #expect(SignInCode.masked("Use 123.456 now") == "Use ••••.•••• now")
            #expect(SignInCode.masked("Code 4829-1033") == "Code ••••-••••")
            #expect(SignInCode.masked("Pin 123 4567") == "Pin •••• ••••")
            #expect(SignInCode.masked("123") == "••••")
            // Any script's decimal digits count.
            #expect(SignInCode.masked("\u{FF14}\u{FF18}\u{FF12}\u{FF19}\u{FF11}\u{FF10}") == "••••")
            #expect(SignInCode.masked("\u{0664}\u{0668}\u{0662}\u{0669}\u{0661}\u{0660}") == "••••")
        }

        @Test("The masked text leaves everything else as it was")
        func maskingLeavesOtherText() {
            for text in ["", "Your code is ready", "Room 12", "Total 123456789", "Call 12 or 34", "Hello 👋 there", "a\nb\tc"] {
                #expect(SignInCode.masked(text) == text, "\(text)")
            }
            #expect(SignInCode.masked("Room 12, code 4829\n👋 482910") == "Room 12, code ••••\n👋 ••••")
        }

        @Test(
            "A short-code sender, or a keyword that begins a word, marks a message as possibly carrying a code",
            arguments: [
                ("24273", "hello"),
                ("123", "hello"),
                ("12345678", "hello"),
                ("+14155550123", "Your CODE is 1234"),
                ("mom@example.com", "Sign-in 1234"),
                ("mom@example.com", "(token)"),
                ("mom@example.com", "Wait, security first"),
                ("mom@example.com", "Bestätigungscode: 123456"),
                ("mom@example.com", "Votre vérification"),
                ("mom@example.com", "Please log in"),
            ]
        )
        func mayCarryCode(_ sender: String, _ text: String) {
            #expect(SignInCode.mayCarryCode(sender: sender, text: text))
        }

        @Test(
            "A person's message with no keyword at a word start does not",
            arguments: [
                ("+14155550123", "Dinner at 7pm, room 1234"),
                ("mom@example.com", "zipcode 90210"),
                ("mom@example.com", "I decoded the barcode"),
                ("mom@example.com", "Photo from the hotpot place"),
                ("mom@example.com", "Please assign in order"),
                ("123456789", "hello"),
                ("12", "hello"),
                ("24273a", "hello"),
                ("2427\n", "hello"),
                ("", ""),
            ]
        )
        func doesNotMarkOrdinaryMessages(_ sender: String, _ text: String) {
            #expect(!SignInCode.mayCarryCode(sender: sender, text: text))
        }

        @Test(
            "Fewer than 4 digits, more than 8, or digits within a larger number are not a code",
            arguments: [
                "",
                "No digits here",
                "Your code is 123",
                "Your code is 123456789",
                "Call 1234567890",
                "id 1234567890123",
                "Total $1234.56",
                "Total $1,234.56",
                "Total 12.3456",
                "Phone 555-1234",
                "Phone 555-123-4567",
                "Date 2026-11-16",
                "Date 16/11/2026",
                "Ratio 1234/5678",
                "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}",
                "\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}",
                "Card ending 4821 was charged $1234.56",
            ]
        )
        func notFound(_ text: String) {
            #expect(SignInCode.code(in: text) == nil)
        }

        @Test(
            "A code with a keyword is a code message",
            arguments: [
                "Your verification code is 123456",
                "YOUR CODE IS 123456",
                "Use 482913 to sign in to Example",
                "Sign-in 1234",
                "Your OTP is 4821",
                "OTP: 4821",
                "G-123456 is your Google verification code.",
                "Your one-time password: 99887766",
                "Security code 5555",
                "Passcode: 1234",
                "Verify your account with 123456",
                "login 123456",
                "Please log in with 123456",
                "Two-step authentication 7777",
                "(code) 1234",
            ]
        )
        func codeMessages(_ text: String) {
            #expect(SignInCode.isCodeMessage(text))
        }

        @Test(
            "Without a keyword, without a standalone code, or with a keyword only inside a word, it is not",
            arguments: [
                "",
                "Call me at 555-123-4567",
                "Your payment of $1234.56 was received",
                "Dinner at 7pm, table 1234",
                "Your verification code is ready",
                "Your code is 123",
                "Your code is 123456789",
                "zipcode 90210",
                "barcode 12345678",
                "decode 1234",
                "Photo 1234 from the hotpot place",
                "Please assign in 1234 steps",
            ]
        )
        func notCodeMessages(_ text: String) {
            #expect(!SignInCode.isCodeMessage(text))
        }
    }
}
