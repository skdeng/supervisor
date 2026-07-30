import Foundation
import OSLog

enum AppLogCategory: String, CaseIterable, Sendable {
    case engine
    case module
    case swarm
    case calls
    case media
    case usage
    case agentDispatch
    case fileShelf
    case flow
}

enum AppLog {
    static let subsystem = "com.supervisor.SuperVisor"

    private static let loggers = LoggerStore()
    private static let fileMirror = FileLogMirror()

    static func notice(_ category: AppLogCategory, _ message: String) {
        loggers[category].notice("\(message, privacy: .public)")
        fileMirror.append(level: "NOTICE", category: category, message: message)
    }

    static func error(_ category: AppLogCategory, _ message: String) {
        loggers[category].error("\(message, privacy: .public)")
        fileMirror.append(level: "ERROR", category: category, message: message)
    }

    static func debug(_ category: AppLogCategory, _ message: String) {
        loggers[category].debug("\(message, privacy: .public)")
    }
}

private struct LoggerStore: Sendable {
    private let engine = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.engine.rawValue)
    private let module = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.module.rawValue)
    private let swarm = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.swarm.rawValue)
    private let calls = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.calls.rawValue)
    private let media = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.media.rawValue)
    private let usage = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.usage.rawValue)
    private let agentDispatch = Logger(
        subsystem: AppLog.subsystem,
        category: AppLogCategory.agentDispatch.rawValue
    )
    private let fileShelf = Logger(
        subsystem: AppLog.subsystem,
        category: AppLogCategory.fileShelf.rawValue
    )
    private let flow = Logger(subsystem: AppLog.subsystem, category: AppLogCategory.flow.rawValue)

    subscript(category: AppLogCategory) -> Logger {
        switch category {
        case .engine: engine
        case .module: module
        case .swarm: swarm
        case .calls: calls
        case .media: media
        case .usage: usage
        case .agentDispatch: agentDispatch
        case .fileShelf: fileShelf
        case .flow: flow
        }
    }
}

final class FileLogMirror: @unchecked Sendable {
    static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SuperVisor", isDirectory: true)

    private static let maximumFileSize: UInt64 = 1 << 20

    private let queue = DispatchQueue(
        label: "com.supervisor.file-log-mirror",
        qos: .utility
    )
    private let fileURL = directoryURL.appendingPathComponent("SuperVisor.log")
    private let rotatedFileURL = directoryURL.appendingPathComponent("SuperVisor.log.1")

    // Access is confined to `queue`.
    private var fileHandle: FileHandle?
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func append(level: String, category: AppLogCategory, message: String) {
        // Callers are often on the main actor; the disk write must never block them.
        queue.async { [self] in
            appendLocked(level: level, category: category, message: message)
        }
    }

    private func appendLocked(level: String, category: AppLogCategory, message: String) {
        let singleLineMessage = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let prefix = "\(timestampFormatter.string(from: Date())) \(level) [\(category.rawValue)] "
        let line = prefix + singleLineMessage + "\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            try FileManager.default.createDirectory(
                at: Self.directoryURL,
                withIntermediateDirectories: true
            )

            var handle = try openFileLocked()
            let size = try handle.seekToEnd()
            if size + UInt64(data.count) > Self.maximumFileSize {
                try rotateLocked()
                handle = try openFileLocked()
                _ = try handle.seekToEnd()
            }
            try handle.write(contentsOf: data)
        } catch {
            try? fileHandle?.close()
            fileHandle = nil
        }
    }

    private func openFileLocked() throws -> FileHandle {
        if let fileHandle {
            return fileHandle
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        fileHandle = handle
        return handle
    }

    private func rotateLocked() throws {
        try? fileHandle?.close()
        fileHandle = nil

        if FileManager.default.fileExists(atPath: rotatedFileURL.path) {
            try FileManager.default.removeItem(at: rotatedFileURL)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.moveItem(at: fileURL, to: rotatedFileURL)
        }
    }
}
