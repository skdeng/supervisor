import AppKit
import Foundation

/// File operations the shelf performs on staged items: AirDrop, Reveal in Finder, and
/// Compress to a `.zip`. All system I/O runs off the main actor; UI-touching calls
/// (AirDrop's sharing service, Finder reveal) hop to the main actor internally.
enum FileActionService {
    enum ActionError: LocalizedError {
        case airDropUnavailable
        case nothingToCompress
        case zipFailed(code: Int32)
        case zipLaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .airDropUnavailable:
                return "AirDrop is not available for the selected items."
            case .nothingToCompress:
                return "No files to compress."
            case let .zipFailed(code):
                return "Compression failed (zip exited with code \(code))."
            case let .zipLaunchFailed(message):
                return "Could not start compression: \(message)."
            }
        }
    }

    // MARK: AirDrop

    /// Present the system AirDrop sheet for `urls`. AirDrop has no completion callback, so
    /// this resolves once the share is handed to the system. The `anchor` view, when given,
    /// lets the system position the picker near the shelf.
    @MainActor
    static func airDrop(_ urls: [URL], from anchor: NSView?) throws {
        guard !urls.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: urls)
        else {
            throw ActionError.airDropUnavailable
        }
        service.perform(withItems: urls)
    }

    /// Whether AirDrop can be performed for the given URLs right now.
    @MainActor
    static func canAirDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else {
            return false
        }
        return service.canPerform(withItems: urls)
    }

    // MARK: Reveal in Finder

    @MainActor
    static func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Compress

    /// Compress `urls` into a single `.zip` written to a unique temp directory, and return
    /// the resulting archive URL. Runs `/usr/bin/zip` under an `NSFileCoordinator` read
    /// coordination so concurrent writers do not corrupt the inputs. Off-main-actor safe.
    static func compress(_ urls: [URL]) async throws -> URL {
        let inputs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !inputs.isEmpty else { throw ActionError.nothingToCompress }

        let archiveName = Self.archiveName(for: inputs)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let archiveURL = outDir.appendingPathComponent(archiveName)

        try await runZip(inputs: inputs, archiveURL: archiveURL)
        return archiveURL
    }

    /// Derive a sensible archive name: the single item's name when compressing one file/dir,
    /// otherwise a dated "Archive" bundle name.
    private static func archiveName(for inputs: [URL]) -> String {
        if inputs.count == 1 {
            let base = inputs[0].deletingPathExtension().lastPathComponent
            let name = base.isEmpty ? "Archive" : base
            return "\(name).zip"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Archive \(formatter.string(from: Date())).zip"
    }

    /// Coordinate read access to the inputs, then run `zip -r -X` with paths relative to a
    /// common parent so the archive contains clean entries rather than absolute paths.
    private static func runZip(inputs: [URL], archiveURL: URL) async throws {
        let coordinator = NSFileCoordinator()

        // Build accessor intents for every input so the coordinator serializes against
        // any in-flight writers before zip reads them.
        let intents = inputs.map {
            NSFileAccessIntent.readingIntent(with: $0, options: [])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coordinator.coordinate(with: intents, queue: .main) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        // Run zip from the deepest directory that contains every input, passing each input's
        // path RELATIVE to it. This keeps archive entries clean, preserves the directory
        // structure of any folder inputs, and — because relative paths under a shared root are
        // unique — never collides the way `-j` (junk paths) does on duplicate basenames such as
        // the ubiquitous `.DS_Store` (which aborts the whole zip with "cannot repeat names").
        //
        // Security: the input paths are attacker-influenced (a dropped file's name is arbitrary),
        // so guard the zip argv. `-y` stores symlinks as links instead of following them, so a
        // symlink hidden in a dragged folder can't exfiltrate a file outside it into the archive.
        // A `--` end-of-options marker plus a `./` prefix on every path ensures a name beginning
        // with `-` (e.g. `-T`, `--unzip-command=…`, `-x`) is always parsed as a file, never a zip
        // option — closing an argument-injection path that reaches command execution via `-TT`.
        let workDir = Self.commonAncestor(of: inputs)
        let relativePaths = inputs.map { "./" + Self.relativePath(of: $0, under: workDir) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-r", "-X", "-y", archiveURL.path, "--"] + relativePaths

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ActionError.zipFailed(code: proc.terminationStatus))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ActionError.zipLaunchFailed(error.localizedDescription))
            }
        }
    }

    /// The deepest directory that contains every input. Falls back to `/` for inputs that share
    /// no common ancestor (e.g. items on different volumes).
    private static func commonAncestor(of urls: [URL]) -> URL {
        let parentComponents = urls.map {
            $0.standardizedFileURL.deletingLastPathComponent().pathComponents
        }
        guard var shared = parentComponents.first else { return URL(fileURLWithPath: "/") }
        for components in parentComponents.dropFirst() {
            var end = 0
            while end < shared.count, end < components.count, shared[end] == components[end] {
                end += 1
            }
            shared = Array(shared.prefix(end))
        }
        var url = URL(fileURLWithPath: "/")
        for component in shared.dropFirst() { url.appendPathComponent(component) }
        return url
    }

    /// `url`'s path relative to `base` (an ancestor), `/`-joined for use as a zip input argument.
    /// Falls back to the last path component if `base` is not actually a prefix of `url`.
    private static func relativePath(of url: URL, under base: URL) -> String {
        let baseComponents = base.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count > baseComponents.count,
              Array(urlComponents.prefix(baseComponents.count)) == baseComponents else {
            return url.lastPathComponent
        }
        return urlComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }
}
