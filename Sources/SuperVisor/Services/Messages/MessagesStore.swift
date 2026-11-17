import Foundation
import SQLite3

/// One row of the Messages database that carries text.
struct TextMessage: Equatable, Sendable {
    let rowID: Int64
    /// The handle the message came from or went to: a phone number, short code, or address.
    /// Empty when the row has no handle.
    let sender: String
    let isFromMe: Bool
    let date: Date
    let text: String
}

/// Where a message's text lives. Current macOS often leaves the `text` column empty and
/// archives the string, with its attributes, in the `attributedBody` blob.
enum MessageBody {
    /// The longest text returned, in UTF-8 bytes. Longer text reads as absent.
    static let maximumTextBytes = 20_000
    /// The largest archive examined. Attribute runs make an archive larger than its text.
    static let maximumArchiveBytes = 512 << 10

    /// The message's text: the `text` column when present and non-empty, else the string
    /// archived in `attributedBody`. Nil when neither yields text.
    static func text(column: String?, attributedBody: Data?) -> String? {
        if let column, !column.isEmpty, column.utf8.count <= maximumTextBytes {
            return column
        }
        guard let attributedBody else { return nil }
        return archivedString(in: attributedBody)
    }

    // The blob is a legacy `NSArchiver` typedstream of an `NSAttributedString`:
    //
    //   04 0b "streamtyped" …            header
    //   … "NSString" 01 <tag> 84 01 2b   the string's class, then its type encoding "+"
    //   <length> <UTF-8 bytes>           the string
    //   86 …                             the attribute runs, which are not read
    //
    // `<length>` is one byte below 0x80; otherwise 0x81 and a little-endian UInt16, or 0x82
    // and a little-endian UInt32. Every offset is checked against the buffer and no length is
    // taken on trust.
    private static let header: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8)
    private static let stringClass = Array("NSString".utf8)
    private static let stringEncoding: [UInt8] = [0x84, 0x01, 0x2B]
    /// How far into the archive the string's class is looked for: the class table comes first.
    private static let classSearchWindow = 512
    /// How many bytes the class name and the type encoding may be apart.
    private static let encodingSearchSpan = 6

    static func archivedString(in data: Data) -> String? {
        guard data.count <= maximumArchiveBytes else { return nil }
        let bytes = [UInt8](data)
        guard bytes.starts(with: header),
              let classStart = find(stringClass, in: bytes, from: header.count, upTo: classSearchWindow),
              let encodingStart = find(
                  stringEncoding,
                  in: bytes,
                  from: classStart + stringClass.count,
                  upTo: classStart + stringClass.count + encodingSearchSpan + stringEncoding.count
              )
        else { return nil }

        let lengthStart = encodingStart + stringEncoding.count
        guard lengthStart < bytes.count else { return nil }
        let length: Int
        let textStart: Int
        switch bytes[lengthStart] {
        case 0x00..<0x80:
            length = Int(bytes[lengthStart])
            textStart = lengthStart + 1
        case 0x81:
            guard lengthStart + 3 <= bytes.count else { return nil }
            length = Int(bytes[lengthStart + 1]) | Int(bytes[lengthStart + 2]) << 8
            textStart = lengthStart + 3
        case 0x82:
            guard lengthStart + 5 <= bytes.count else { return nil }
            length = (0..<4).reduce(0) { $0 | Int(bytes[lengthStart + 1 + $1]) << (8 * $1) }
            textStart = lengthStart + 5
        default:
            return nil
        }
        guard length > 0,
              length <= maximumTextBytes,
              textStart + length <= bytes.count
        else { return nil }
        return String(data: Data(bytes[textStart..<(textStart + length)]), encoding: .utf8)
    }

    /// The first position in `bytes[from..<limit]` where `pattern` begins and fits wholly
    /// inside `bytes`.
    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from: Int, upTo limit: Int) -> Int? {
        let end = min(limit, bytes.count)
        guard from >= 0, from + pattern.count <= end else { return nil }
        for start in from...(end - pattern.count) where bytes[start] == pattern[0] {
            if bytes[start..<(start + pattern.count)].elementsEqual(pattern) { return start }
        }
        return nil
    }
}

/// Recognizes, and masks, the one-time codes in text messages.
enum SignInCode {
    /// Words that mark a message as a sign-in or verification code message.
    private static let keywords = [
        "code", "verification", "verify", "passcode", "one-time", "otp", "security code",
        "login", "log in", "sign in", "sign-in", "authentication",
    ]

    /// Words a code follows, in the order they are tried when picking among several numbers.
    private static let codeWords = [
        "code", "passcode", "pin", "otp", "password", "token", "código", "codigo",
    ]

    /// Words that mark a message as one that may carry a code, so its numbers are masked.
    private static let maskingKeywords = [
        "code", "passcode", "pin", "otp", "password", "token", "2fa", "verification", "verify",
        "login", "log in", "sign in", "sign-in", "authentication", "security", "código", "codigo",
        "bestätigungscode", "vérification",
    ]

    /// Words that put an account reference, not a code, in the digits that follow.
    private static let accountWords = [
        "ending in", "ending", "ends in", "acct", "account", "card", "last 4", "last four",
    ].map { Array($0.utf8) }

    /// What may sit between an account word and its digits. Text is lowercased before it is
    /// examined, so `X` arrives as `x`.
    private static let accountFiller: Set<UInt8> = [
        UInt8(ascii: " "), UInt8(ascii: ":"), UInt8(ascii: "#"), UInt8(ascii: "*"), UInt8(ascii: "x"),
    ]

    static let mask = "••••"

    /// The code in `text`: the digits of the first candidate that follows a code word, else
    /// the first candidate.
    ///
    /// A candidate is a standalone run of 4 to 8 digits, or two groups of three digits joined
    /// by a space or hyphen, which reads as six digits. A run that is part of a longer run of
    /// digits is no candidate, nor is one that continues across `.`, `,`, `-`, or `/` into
    /// another digit, as in a date, a price, or a phone number. A number right after an account
    /// word (`card ending 4821`) is no candidate either.
    static func code(in text: String) -> String? {
        let normalized = normalizing(text)
        let bytes = Array(normalized.utf8)
        let candidates = candidates(in: bytes).filter {
            !followsAccountReference(bytes, before: $0.start)
        }
        guard let first = candidates.first else { return nil }
        guard let codeWordEnd = codeWordEnd(in: normalized) else { return first.digits }
        return (candidates.first { $0.start >= codeWordEnd } ?? first).digits
    }

    /// Whether `text` reads as a sign-in or verification code message: it holds a code and a
    /// keyword that begins a word.
    static func isCodeMessage(_ text: String) -> Bool {
        guard code(in: text) != nil else { return false }
        let normalized = normalizing(text)
        return keywords.contains { firstWordStart(of: $0, in: normalized) != nil }
    }

    /// Whether a message may carry a code: its sender is a short code (3 to 8 digits), or its
    /// text holds a masking keyword that begins a word.
    static func mayCarryCode(sender: String, text: String) -> Bool {
        if sender.range(of: #"\A[0-9]{3,8}\z"#, options: .regularExpression) != nil { return true }
        let normalized = normalizing(text)
        return maskingKeywords.contains { firstWordStart(of: $0, in: normalized) != nil }
    }

    /// `text` with every run of 3 to 8 decimal digits replaced by `mask`. Any script's decimal
    /// digits count. Three is the floor because codes are also written in groups (`123 456`,
    /// `123 4567`), and a group left standing would show half the code.
    static func masked(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard isDecimalDigit(scalars[index]) else {
                output.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isDecimalDigit(scalars[end]) { end += 1 }
            if (3...8).contains(end - index) {
                output.append(contentsOf: mask.unicodeScalars)
            } else {
                output.append(contentsOf: scalars[index..<end])
            }
            index = end
        }
        return String(output)
    }

    // MARK: Candidates

    private struct Candidate {
        let start: Int
        let digits: String
    }

    /// Lowercased, with runs of blanks reduced to one space, so every later offset and
    /// comparison is taken on the one string.
    private static func normalizing(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[ \t\u00A0]+"#, with: " ", options: .regularExpression)
    }

    private static func candidates(in bytes: [UInt8]) -> [Candidate] {
        var found: [Candidate] = []
        var index = 0
        while index < bytes.count {
            guard isDigit(bytes[index]) else {
                index += 1
                continue
            }
            var end = index
            while end < bytes.count, isDigit(bytes[end]) { end += 1 }
            var next = end
            if (4...8).contains(end - index) {
                if !continuesAcrossSeparator(bytes, start: index, end: end) {
                    found.append(Candidate(start: index, digits: digits(bytes, index..<end)))
                }
            } else if end - index == 3, end + 4 <= bytes.count,
                      bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "-"),
                      bytes[(end + 1)..<(end + 4)].allSatisfy(isDigit),
                      end + 4 == bytes.count || !isDigit(bytes[end + 4]),
                      !continuesAcrossSeparator(bytes, start: index, end: end + 4) {
                found.append(Candidate(
                    start: index,
                    digits: digits(bytes, index..<end) + digits(bytes, (end + 1)..<(end + 4))
                ))
                next = end + 4
            }
            index = next
        }
        return found
    }

    private static func digits(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }

    private static func isDecimalDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .decimalNumber
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        [UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: "-"), UInt8(ascii: "/")].contains(byte)
    }

    private static func continuesAcrossSeparator(_ bytes: [UInt8], start: Int, end: Int) -> Bool {
        let before = start >= 2 && isSeparator(bytes[start - 1]) && isDigit(bytes[start - 2])
        let after = end + 1 < bytes.count && isSeparator(bytes[end]) && isDigit(bytes[end + 1])
        return before || after
    }

    /// Whether the digits at `start` are named by an account word just before them.
    private static func followsAccountReference(_ bytes: [UInt8], before start: Int) -> Bool {
        var end = start
        while end > 0, accountFiller.contains(bytes[end - 1]) { end -= 1 }
        return accountWords.contains { word in
            guard end >= word.count, bytes[(end - word.count)..<end].elementsEqual(word) else {
                return false
            }
            let before = end - word.count - 1
            return before < 0 || !isLetter(bytes[before])
        }
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (97...122).contains(byte) || byte >= 0x80 }

    // MARK: Keywords

    /// Where the earliest code word ends, as a UTF-8 offset into `text`.
    private static func codeWordEnd(in text: String) -> Int? {
        codeWords
            .compactMap { firstWordStart(of: $0, in: text)?.upperBound }
            .min()
            .map { text.utf8.distance(from: text.utf8.startIndex, to: $0) }
    }

    /// The first place `keyword` occurs at the start of a word. `zipcode` and `decode` hold the
    /// word `code`, but neither begins with it.
    private static func firstWordStart(of keyword: String, in text: String) -> Range<String.Index>? {
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: keyword, range: searchRange) {
            if match.lowerBound == text.startIndex
                || !text[text.index(before: match.lowerBound)].isLetter {
                return match
            }
            searchRange = match.upperBound..<text.endIndex
        }
        return nil
    }
}

/// A read-only view of the Messages database.
///
/// Every call opens its own connection and closes it before returning: a read transaction
/// held open would pin the write-ahead log, and a fresh connection sees rows the Messages app
/// has written there but not yet merged into the main file. Values reach the query only as
/// bound parameters.
struct MessagesStore: Sendable {
    enum Failure: Error, Equatable {
        /// The database could not be opened or queried: missing, locked, or not the Messages
        /// schema.
        case unreadable
        /// The system refused the file, as it does an app without Full Disk Access.
        case accessDenied
        /// The database opened but a read hit damaged data.
        case malformed
    }

    static let defaultPath = NSHomeDirectory() + "/Library/Messages/chat.db"
    static let maximumLimit = 200
    static let maximumScannedRows = 2_000

    let path: String

    init(path: String = MessagesStore.defaultPath) {
        self.path = path
    }

    /// Messages with text from `since` on, newest first, at most `limit` (clamped to 1…200).
    /// `sender` must equal the message's handle exactly; `containing` matches anywhere in the
    /// text, ignoring case. Only the newest 2,000 rows from `since` are examined.
    ///
    /// The texts are as sent and may carry sign-in codes. They serve the app's own matching;
    /// `messagesForModel` is the read for anything a model sees.
    func messages(
        since: Date,
        sender: String? = nil,
        containing: String? = nil,
        limit: Int
    ) throws -> [TextMessage] {
        try collect(since: since, sender: sender, containing: containing, limit: limit) { $0 }
    }

    /// Messages for a model to read, with anything that may be a sign-in code masked. This is
    /// the only read for showing texts to a model.
    ///
    /// A message that may carry a code (see `SignInCode.mayCarryCode`) has its numbers
    /// replaced by `SignInCode.mask`, and `containing` is matched against the masked text, so
    /// a search for a guessed code finds nothing. The other parameters are those of `messages`.
    func messagesForModel(
        since: Date,
        sender: String? = nil,
        containing: String? = nil,
        limit: Int
    ) throws -> [TextMessage] {
        try collect(since: since, sender: sender, containing: containing, limit: limit) { message in
            guard SignInCode.mayCarryCode(sender: message.sender, text: message.text) else {
                return message
            }
            return TextMessage(
                rowID: message.rowID,
                sender: message.sender,
                isFromMe: message.isFromMe,
                date: message.date,
                text: SignInCode.masked(message.text)
            )
        }
    }

    /// The row id of the newest message, or 0 when there is none. Messages that arrive later
    /// have larger ids.
    func latestRowID() throws -> Int64 {
        var latest: Int64 = 0
        try read("SELECT COALESCE(MAX(ROWID), 0) FROM message", bind: { _ in }) { statement in
            latest = sqlite3_column_int64(statement, 0)
            return false
        }
        return latest
    }

    /// The code in the newest message from `sender` that arrived after `afterRowID` and reads
    /// as a code message, with that message's row id. Ids order messages by arrival, so no
    /// clock decides which message is newer.
    func latestCode(afterRowID: Int64, sender: String) throws -> (code: String, rowID: Int64)? {
        var found: (code: String, rowID: Int64)?
        try read(Self.incomingQuery, bind: { statement in
            sqlite3_bind_int64(statement, 1, afterRowID)
            Self.bind(sender, to: statement, at: 2)
            sqlite3_bind_int(statement, 3, Int32(Self.maximumScannedRows))
        }) { statement in
            guard let message = Self.message(from: statement),
                  SignInCode.isCodeMessage(message.text),
                  let code = SignInCode.code(in: message.text)
            else { return true }
            found = (code, message.rowID)
            return false
        }
        return found
    }

    /// The oldest incoming code message that arrived after `afterRowID`, from any sender that
    /// has a handle, with that message's row id.
    ///
    /// This is for enrollment, while the user watches the app sign in: it learns which handle
    /// the site's codes come from. Every later read names that recorded sender (`latestCode`),
    /// so no sign-in takes a code from a sender the user did not see.
    func firstCode(afterRowID: Int64) throws -> (code: String, sender: String, rowID: Int64)? {
        var found: (code: String, sender: String, rowID: Int64)?
        try read(Self.firstIncomingQuery, bind: { statement in
            sqlite3_bind_int64(statement, 1, afterRowID)
            sqlite3_bind_int(statement, 2, Int32(Self.maximumScannedRows))
        }) { statement in
            guard let message = Self.message(from: statement),
                  !message.sender.isEmpty,
                  SignInCode.isCodeMessage(message.text),
                  let code = SignInCode.code(in: message.text)
            else { return true }
            found = (code, message.sender, message.rowID)
            return false
        }
        return found
    }

    // MARK: Connection

    /// The connection every read uses, opened read-only. The caller closes it.
    func openConnection() throws -> OpaquePointer {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let database else {
            let denied = Self.isAccessDenied(status, database)
            sqlite3_close(database)
            throw denied ? Failure.accessDenied : Failure.unreadable
        }
        sqlite3_busy_timeout(database, 250)
        return database
    }

    /// The file exists but the system will not let this process read it.
    private static func isAccessDenied(_ status: Int32, _ database: OpaquePointer?) -> Bool {
        switch status & 0xFF {
        case SQLITE_AUTH:
            return true
        case SQLITE_CANTOPEN:
            return [EPERM, EACCES].contains(sqlite3_system_errno(database))
        default:
            return false
        }
    }

    // MARK: Queries

    /// `message.date` counts nanoseconds since 2001-01-01 on current macOS and seconds on old
    /// versions; a value above `?1` is nanoseconds. The filter is on the raw column.
    private static let dateQuery = """
        SELECT message.ROWID, message.text, message.attributedBody, message.date,
               message.is_from_me, handle.id
        FROM message
        LEFT JOIN handle ON handle.ROWID = message.handle_id
        WHERE ((message.date > ?1 AND message.date >= ?2) OR (message.date <= ?1 AND message.date >= ?3))
          AND (?4 IS NULL OR handle.id = ?4)
          AND (?5 = 0 OR message.is_from_me = 0)
        ORDER BY message.date DESC, message.ROWID DESC
        LIMIT ?6
        """

    private static let incomingQuery = """
        SELECT message.ROWID, message.text, message.attributedBody, message.date,
               message.is_from_me, handle.id
        FROM message
        JOIN handle ON handle.ROWID = message.handle_id
        WHERE message.ROWID > ?1 AND handle.id = ?2 AND message.is_from_me = 0
        ORDER BY message.ROWID DESC
        LIMIT ?3
        """

    private static let firstIncomingQuery = """
        SELECT message.ROWID, message.text, message.attributedBody, message.date,
               message.is_from_me, handle.id
        FROM message
        JOIN handle ON handle.ROWID = message.handle_id
        WHERE message.ROWID > ?1 AND message.is_from_me = 0
        ORDER BY message.ROWID ASC
        LIMIT ?2
        """

    private static let nanosecondThreshold: Int64 = 100_000_000_000

    private func collect(
        since: Date,
        sender: String?,
        containing: String?,
        limit: Int,
        transform: (TextMessage) -> TextMessage
    ) throws -> [TextMessage] {
        let wanted = min(max(limit, 1), Self.maximumLimit)
        let seconds = since.timeIntervalSinceReferenceDate
        let scaled = seconds * 1e9
        let nanoseconds = Int64(scaled.isNaN ? 0 : min(max(scaled, -9.2e18), 9.2e18))
        var found: [TextMessage] = []
        try read(Self.dateQuery, bind: { statement in
            sqlite3_bind_int64(statement, 1, Self.nanosecondThreshold)
            sqlite3_bind_int64(statement, 2, nanoseconds)
            sqlite3_bind_double(statement, 3, seconds.isNaN ? 0 : seconds)
            if let sender {
                Self.bind(sender, to: statement, at: 4)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            sqlite3_bind_int(statement, 5, 0)
            sqlite3_bind_int(statement, 6, Int32(Self.maximumScannedRows))
        }) { statement in
            guard let raw = Self.message(from: statement) else { return true }
            let message = transform(raw)
            if let containing, !containing.isEmpty,
               message.text.range(of: containing, options: .caseInsensitive) == nil {
                return true
            }
            found.append(message)
            return found.count < wanted
        }
        return found
    }

    /// Runs `sql` and hands each row to `row` until it returns false.
    private func read(
        _ sql: String,
        bind: (OpaquePointer?) -> Void,
        row: (OpaquePointer?) -> Bool
    ) throws {
        let database = try openConnection()
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            let denied = Self.isAccessDenied(prepared, database)
            sqlite3_finalize(statement)
            throw denied ? Failure.accessDenied : Failure.unreadable
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if !row(statement) { return }
            case SQLITE_DONE:
                return
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw Failure.unreadable
            default:
                throw Failure.malformed
            }
        }
    }

    /// Binds `value` with its byte length, so a NUL inside it is part of the compared string.
    private static func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString {
            sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient)
        }
    }

    /// Reads the row `dateQuery` and `incomingQuery` select; nil when it carries no text.
    private static func message(from statement: OpaquePointer?) -> TextMessage? {
        let column = text(statement, 1, limit: MessageBody.maximumTextBytes)
        var archive: Data?
        if sqlite3_column_type(statement, 2) == SQLITE_BLOB {
            let count = Int(sqlite3_column_bytes(statement, 2))
            if count > 0, count <= MessageBody.maximumArchiveBytes,
               let blob = sqlite3_column_blob(statement, 2) {
                archive = Data(bytes: blob, count: count)
            }
        }
        guard let body = MessageBody.text(column: column, attributedBody: archive) else { return nil }

        let raw = sqlite3_column_int64(statement, 3)
        let seconds = raw > nanosecondThreshold ? Double(raw) / 1e9 : Double(raw)
        return TextMessage(
            rowID: sqlite3_column_int64(statement, 0),
            sender: text(statement, 5, limit: 512) ?? "",
            isFromMe: sqlite3_column_int(statement, 4) != 0,
            date: Date(timeIntervalSinceReferenceDate: seconds),
            text: body
        )
    }

    /// A text column read as UTF-8; nil when it is not text, is invalid, or exceeds `limit` bytes.
    private static func text(_ statement: OpaquePointer?, _ index: Int32, limit: Int) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count <= limit, let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(data: Data(bytes: pointer, count: count), encoding: .utf8)
    }
}
