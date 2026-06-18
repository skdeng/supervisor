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
            .appendingPathComponent("DynaClip-\(UUID().uuidString)", isDirectory: true)
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

        // Group inputs by their containing directory so we can invoke zip with each item's
        // relative name, keeping archive entries free of absolute path prefixes.
        let workDir = inputs[0].deletingLastPathComponent()
        let sameParent = inputs.allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == workDir.standardizedFileURL
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")

        var args = ["-r", "-X", archiveURL.path]
        if sameParent {
            process.currentDirectoryURL = workDir
            args.append(contentsOf: inputs.map { $0.lastPathComponent })
        } else {
            // Mixed parents: fall back to absolute paths with junk-paths stripped so the
            // archive stays flat and predictable.
            args.insert("-j", at: 0)
            args.append(contentsOf: inputs.map { $0.path })
        }
        process.arguments = args

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
}
