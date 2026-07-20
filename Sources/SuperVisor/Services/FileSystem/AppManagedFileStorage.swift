import Darwin
import Foundation

struct AgentRunWorkspace: Sendable {
    let directoryURL: URL
    let copiedFileURL: URL
}

enum AppManagedFileStorage {
    private static let maximumFilenameLength = 120

    static func sweepOrphans() {
        for directory in [resultsDirectory, agentRunsDirectory] {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for child in children {
                try? FileManager.default.removeItem(at: child)
            }
        }
    }

    static func prepareAgentRun(
        sourceURL: URL,
        expectedIdentity: FileSystemIdentity
    ) throws -> AgentRunWorkspace {
        try ensureManagedDirectories()

        let scratchURL = agentRunsDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: scratchURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let copyURL = scratchURL.appendingPathComponent(
                sanitizedCopyBasename(sourceURL.lastPathComponent),
                isDirectory: false
            )
            try copyRegularFile(
                from: sourceURL,
                expectedIdentity: expectedIdentity,
                to: copyURL
            )
            return AgentRunWorkspace(directoryURL: scratchURL, copiedFileURL: copyURL)
        } catch {
            try? FileManager.default.removeItem(at: scratchURL)
            throw error
        }
    }

    static func removeAgentRun(_ directoryURL: URL) {
        guard isDirectChild(directoryURL, of: agentRunsDirectory) else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    static func writeResult(
        _ text: String,
        sourceBasename: String,
        resultTitle: String
    ) throws -> URL {
        try ensureManagedDirectories()
        let stem = sanitizedResultStem(sourceBasename)
        let title = sanitizedResultTitle(resultTitle)
        let data = Data(text.utf8)

        for counter in 1...10_000 {
            let suffix = counter == 1 ? "" : " \(counter)"
            let filename = "\(stem) — \(title)\(suffix).md"
            let resultURL = resultsDirectory.appendingPathComponent(filename, isDirectory: false)
            let descriptor = openExclusiveFile(at: resultURL)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            do {
                try writeAll(data, to: descriptor)
                guard Darwin.close(descriptor) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return resultURL
            } catch {
                Darwin.close(descriptor)
                try? FileManager.default.removeItem(at: resultURL)
                throw error
            }
        }

        throw POSIXError(.EEXIST)
    }

    static func removeGeneratedArtifact(_ url: URL) {
        guard isDirectChild(url, of: resultsDirectory) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var managedRoot: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport.appendingPathComponent("SuperVisor", isDirectory: true)
    }

    private static var resultsDirectory: URL {
        managedRoot.appendingPathComponent("Results", isDirectory: true)
    }

    private static var agentRunsDirectory: URL {
        managedRoot.appendingPathComponent("AgentRuns", isDirectory: true)
    }

    private static func ensureManagedDirectories() throws {
        for directory in [managedRoot, resultsDirectory, agentRunsDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private static func copyRegularFile(
        from sourceURL: URL,
        expectedIdentity: FileSystemIdentity,
        to destinationURL: URL
    ) throws {
        guard FileSystemIdentity.regularFile(at: sourceURL) == expectedIdentity else {
            throw CocoaError(.fileReadNoPermission)
        }

        let sourceDescriptor: Int32 = sourceURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(sourceDescriptor) }

        guard FileSystemIdentity.regularFile(openFileDescriptor: sourceDescriptor)
                == expectedIdentity
        else {
            throw CocoaError(.fileReadNoPermission)
        }

        let destinationDescriptor = openExclusiveFile(at: destinationURL)
        guard destinationDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(destinationDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            try buffer.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Darwin.write(
                        destinationDescriptor,
                        baseAddress.advanced(by: offset),
                        count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard written > 0 else { throw POSIXError(.EIO) }
                    offset += written
                }
            }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard written > 0 else { throw POSIXError(.EIO) }
                offset += written
            }
        }
    }

    private static func openExclusiveFile(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
    }

    private static func sanitizedCopyBasename(_ untrustedName: String) -> String {
        let path = untrustedName as NSString
        let rawExtension = path.pathExtension
        let rawStem = rawExtension.isEmpty
            ? untrustedName
            : path.deletingPathExtension
        let fileExtension = sanitizedComponent(
            rawExtension,
            fallback: "",
            maximumBytes: 16
        )
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let stem = sanitizedComponent(
            rawStem,
            fallback: "DroppedFile",
            maximumBytes: maximumFilenameLength - extensionSuffix.utf8.count
        )
        return stem + extensionSuffix
    }

    private static func sanitizedComponent(
        _ untrustedName: String,
        fallback: String,
        maximumBytes: Int
    ) -> String {
        let source = untrustedName.precomposedStringWithCanonicalMapping
        let cleaned = source.unicodeScalars.map { scalar -> Character in
            let allowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "-" || scalar == "_" || scalar == " "
            return allowed ? Character(String(scalar)) : "-"
        }
        var result = String(cleaned)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while result.first == "." || result.first == "-" {
            result.removeFirst()
        }
        if result.isEmpty { result = fallback }
        while result.utf8.count > maximumBytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func sanitizedResultStem(_ untrustedName: String) -> String {
        let source = (untrustedName as NSString).deletingPathExtension
        return sanitizedComponent(source, fallback: "Result", maximumBytes: 80)
    }

    private static func sanitizedResultTitle(_ title: String) -> String {
        sanitizedComponent(title, fallback: "Result", maximumBytes: 28)
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL
    }
}
