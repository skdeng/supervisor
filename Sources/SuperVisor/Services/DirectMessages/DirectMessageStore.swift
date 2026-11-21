import Foundation

/// One snapshot file per source, `<directory>/<source>.json`, holding the chats a sync last
/// read. Files are private to the user (directory 0700, file 0600).
struct DirectMessageStore: Sendable {
    enum WriteError: Error, Equatable {
        case invalidSource
        case tooLarge
    }

    static let maximumFileBytes = 4 << 20

    let directory: URL

    /// The file that holds `source`'s snapshot; nil unless `source` passes
    /// `DirectMessageSnapshot.isSourceID`, so a name can never reach outside `directory`.
    func url(for source: String) -> URL? {
        guard DirectMessageSnapshot.isSourceID(source) else { return nil }
        return directory.appendingPathComponent("\(source).json", isDirectory: false)
    }

    /// Replaces the source's file with the snapshot cut to what is kept. Throws, leaving the
    /// earlier file untouched, when the source id is invalid, the encoded snapshot exceeds
    /// `maximumFileBytes`, or the file cannot be written.
    func write(_ snapshot: DirectMessageSnapshot) throws {
        guard let url = url(for: snapshot.source) else { throw WriteError.invalidSource }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot.trimmed())
        guard data.count <= Self.maximumFileBytes else { throw WriteError.tooLarge }
        try Self.write(data, to: url)
    }

    /// The source's snapshot, or nil when the file is missing, is not a regular file, exceeds
    /// `maximumFileBytes`, does not decode, or holds a different source's snapshot.
    func read(source: String) -> DirectMessageSnapshot? {
        guard let url = url(for: source),
              let data = Self.readRegularFile(at: url, limit: Self.maximumFileBytes)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(DirectMessageSnapshot.self, from: data),
              snapshot.source == source
        else { return nil }
        return snapshot.trimmed()
    }

    /// Deletes the source's file. `unlink` takes a file or a link and never a directory's contents.
    func remove(source: String) {
        guard let url = url(for: source) else { return }
        unlink(url.path)
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
