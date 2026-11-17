import Foundation

/// Host-name syntax shared by the site registry and the Keychain grant.
enum SiteHost {
    /// A lowercase DNS name: at least two labels of letters, digits, and inner hyphens, ending
    /// in a label of 2 to 63 letters, at most 253 bytes in all. IP literals, ports, a trailing
    /// dot, and uppercase are not host names here. Checked on UTF-8 bytes, so a letter is an
    /// ASCII `a`–`z`.
    static func isValid(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        guard bytes.count <= 253 else { return false }
        let labels = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy(isValidLabel) else { return false }
        guard let last = labels.last else { return false }
        return (2...63).contains(last.count) && last.allSatisfy(isLowercaseLetter)
    }

    private static func isValidLabel(_ label: ArraySlice<UInt8>) -> Bool {
        guard (1...63).contains(label.count),
              label.first != UInt8(ascii: "-"),
              label.last != UInt8(ascii: "-")
        else { return false }
        return label.allSatisfy { isLowercaseLetter($0) || isDigit($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isLowercaseLetter(_ byte: UInt8) -> Bool { (97...122).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
}

/// A granted site as the settings list shows it. Nothing here decides where a secret goes;
/// the sign-in address and host lists are in the Keychain with the password (`SiteGrant`).
struct SiteRecord: Codable, Identifiable, Equatable, Sendable {
    static let nameLimit = 60

    /// The sign-in host.
    let id: String
    var name: String
    var added: Date
    var lastSignedIn: Date?
    /// The local calendar day (`yyyy-MM-dd`) that `attemptCount` counts unattended sign-in
    /// attempts for.
    var attemptsDay: String?
    var attemptCount = 0
    /// Set when an unattended sign-in failed; cleared when the person signs in again.
    var needsPerson = false
    /// Mirrors the grant's `remembersPassword == false`, so the site can be described without
    /// reading the Keychain. Nothing decides where a secret goes from it.
    var keepsSessionOnly = false
    /// Set when the site turned away the grant's saved password: an unattended sign-in filled it
    /// and the site still showed the person signed out, or the person signed in by hand after
    /// the app's fill of it was refused or withheld. While it is set the app never submits the
    /// saved password by itself (`SiteAccess`), and the sign-in window leaves the password field
    /// to the person. Cleared when a grant is saved, or when the app's fill of the saved
    /// password is seen to work.
    var passwordRejected = false

    /// The id is a valid host and the name holds 1 to 60 characters once cleaned.
    var isValid: Bool {
        SiteHost.isValid(id)
            && Proposal.displayText(name, limit: Self.nameLimit, truncates: false) != nil
    }

    /// The record with its name cleaned the way `isValid` measures it, and its attempt
    /// bookkeeping brought within range; nil when invalid.
    fileprivate var cleaned: SiteRecord? {
        guard SiteHost.isValid(id),
              let name = Proposal.displayText(name, limit: Self.nameLimit, truncates: false)
        else { return nil }
        var record = self
        record.name = name
        if let day = record.attemptsDay,
           day.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) == nil {
            record.attemptsDay = nil
        }
        record.attemptCount = min(max(record.attemptCount, 0), Self.attemptCountLimit)
        return record
    }

    /// The attempt count a stored record is held to; far above `SignInAttempts.perDay`.
    private static let attemptCountLimit = 1_000
}

extension SiteRecord {
    /// A stored record without the attempt keys reads as one with no attempts, one without
    /// `keepsSessionOnly` as a site that signs in by itself, and one without `passwordRejected`
    /// as one whose saved password was not turned away.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        added = try values.decode(Date.self, forKey: .added)
        lastSignedIn = try values.decodeIfPresent(Date.self, forKey: .lastSignedIn)
        attemptsDay = try values.decodeIfPresent(String.self, forKey: .attemptsDay)
        attemptCount = try values.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        needsPerson = try values.decodeIfPresent(Bool.self, forKey: .needsPerson) ?? false
        keepsSessionOnly = try values.decodeIfPresent(Bool.self, forKey: .keepsSessionOnly) ?? false
        passwordRejected = try values.decodeIfPresent(Bool.self, forKey: .passwordRejected) ?? false
    }
}

/// How many times a day the app may try to sign in by itself, and when it must stop.
///
/// A site that challenges or locks an account after a few failed sign-ins is spared further
/// attempts. A failure that says the person is needed stops the app until the person signs in
/// again; one that may pass on its own (a code that did not arrive, a page that did not load)
/// uses up an attempt and nothing more.
enum SignInAttempts {
    static let perDay = 3

    /// How an attempt ended, as far as the bookkeeping is concerned.
    enum AttemptOutcome: Equatable, Sendable {
        case succeeded
        /// The attempt failed in a way that may not repeat.
        case transientFailure
        /// The attempt failed in a way that only the person can put right.
        case needsPerson
    }

    /// False once the person is needed, or once `perDay` attempts have been made today.
    static func mayAttempt(_ record: SiteRecord, now: Date, timeZone: TimeZone) -> Bool {
        if record.needsPerson { return false }
        guard record.attemptsDay == day(of: now, in: timeZone) else { return true }
        return record.attemptCount < perDay
    }

    /// The record with one more attempt counted, before the attempt's outcome is known. The
    /// first attempt of a new day restarts the count.
    static func beginning(attemptOn record: SiteRecord, now: Date, timeZone: TimeZone) -> SiteRecord {
        var updated = record
        let today = day(of: now, in: timeZone)
        if updated.attemptsDay != today {
            updated.attemptsDay = today
            updated.attemptCount = 0
        }
        updated.attemptCount += 1
        return updated
    }

    /// The record after the outcome of an attempt that was already counted. A success stamps
    /// `lastSignedIn` and clears `needsPerson`, a failure that needs the person sets it, and a
    /// transient failure leaves it as it was.
    static func settling(_ record: SiteRecord, outcome: AttemptOutcome, now: Date) -> SiteRecord {
        var updated = record
        switch outcome {
        case .succeeded:
            updated.lastSignedIn = now
            updated.needsPerson = false
        case .transientFailure:
            break
        case .needsPerson:
            updated.needsPerson = true
        }
        return updated
    }

    /// The record after one attempt and its outcome.
    static func recording(
        attemptOn record: SiteRecord,
        outcome: AttemptOutcome,
        now: Date,
        timeZone: TimeZone
    ) -> SiteRecord {
        settling(beginning(attemptOn: record, now: now, timeZone: timeZone), outcome: outcome, now: now)
    }

    /// The record with an attempt that was cut short taken back: its count and day are those of
    /// `earlier`, the record as it was before the attempt was counted.
    static func abandoning(_ record: SiteRecord, restoring earlier: SiteRecord) -> SiteRecord {
        var updated = record
        updated.attemptsDay = earlier.attemptsDay
        updated.attemptCount = earlier.attemptCount
        return updated
    }

    /// The record after the person signed in themselves: attempts start over.
    /// `storedPasswordWorked` says the site's stored password is believed good, which clears
    /// `passwordRejected`; otherwise it is set, so the app asks the person again instead of
    /// submitting that password.
    static func recordingPersonSignedIn(_ record: SiteRecord, now: Date, storedPasswordWorked: Bool) -> SiteRecord {
        var updated = record
        updated.needsPerson = false
        updated.attemptCount = 0
        updated.attemptsDay = nil
        updated.lastSignedIn = now
        updated.passwordRejected = !storedPasswordWorked
        return updated
    }

    /// `yyyy-MM-dd` for the calendar day `date` falls on in `timeZone`.
    static func day(of date: Date, in timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }
}

/// The granted sites, kept in one JSON file.
enum SiteRegistry {
    static let maximumSites = 50
    static let maximumFileBytes = 256 << 10

    enum SaveError: Error, Equatable {
        case tooManySites
        case invalidSite
        case duplicateSite
        case tooLarge
    }

    /// Every valid record in the file, at most `maximumSites`. A missing file, a file that is
    /// not a regular non-symlink file within the size cap, and a file that does not decode as a
    /// whole all read as an empty list. A decoded entry that fails validation is dropped, and
    /// of two entries with one id the first valid one is kept.
    static func load(from url: URL) -> [SiteRecord] {
        guard let data = readRegularFile(at: url, limit: maximumFileBytes),
              let decoded = try? decoder().decode([SiteRecord].self, from: data)
        else { return [] }

        var seen = Set<String>()
        var records: [SiteRecord] = []
        for entry in decoded {
            guard let record = entry.cleaned, seen.insert(record.id).inserted else { continue }
            records.append(record)
            if records.count == maximumSites { break }
        }
        return records
    }

    /// Writes `records` atomically with mode 0600. Throws, leaving the file untouched, when a
    /// record is invalid, two share an id, or the result would be a file `load` refuses.
    static func save(_ records: [SiteRecord], to url: URL) throws {
        guard records.count <= maximumSites else { throw SaveError.tooManySites }
        var seen = Set<String>()
        var cleaned: [SiteRecord] = []
        for record in records {
            guard let valid = record.cleaned else { throw SaveError.invalidSite }
            guard seen.insert(valid.id).inserted else { throw SaveError.duplicateSite }
            cleaned.append(valid)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cleaned)
        guard data.count <= maximumFileBytes else { throw SaveError.tooLarge }
        try write(data, to: url)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads a regular file through one descriptor, so the type that is checked is that of the
    /// bytes read. A symlink at `url` is refused, and so is a file larger than `limit`.
    private static func readRegularFile(at url: URL, limit: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? handle.read(upToCount: limit + 1),
              data.count <= limit
        else { return nil }
        return data
    }

    /// Creates the file with its final mode, then renames it into place, so the contents are
    /// never readable by anyone else and a reader never sees a partial file.
    private static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
