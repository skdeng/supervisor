import Darwin
import Foundation

/// Stable file-system identity used to detect replacements at an existing path.
struct FileSystemIdentity: Equatable, Sendable {
    let volumeNumber: UInt64
    let fileNumber: UInt64

    static func regularFile(at url: URL) -> FileSystemIdentity? {
        var metadata = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileSystemIdentity(metadata: metadata)
    }

    static func regularFile(openFileDescriptor descriptor: Int32) -> FileSystemIdentity? {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else { return nil }
        return FileSystemIdentity(metadata: metadata)
    }

    private init(metadata: stat) {
        volumeNumber = UInt64(bitPattern: Int64(metadata.st_dev))
        fileNumber = UInt64(metadata.st_ino)
    }
}
