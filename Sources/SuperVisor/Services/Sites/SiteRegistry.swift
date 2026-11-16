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

    /// The id is a valid host and the name holds 1 to 60 characters once cleaned.
    var isValid: Bool {
        SiteHost.isValid(id)
            && Proposal.displayText(name, limit: Self.nameLimit, truncates: false) != nil
    }

    /// The record with its name cleaned the way `isValid` measures it; nil when invalid.
    fileprivate var cleaned: SiteRecord? {
        guard SiteHost.isValid(id),
              let name = Proposal.displayText(name, limit: Self.nameLimit, truncates: false)
        else { return nil }
        var record = self
        record.name = name
        return record
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
