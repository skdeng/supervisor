import Darwin
import Foundation
import UniformTypeIdentifiers

/// Watches the directory where macOS saves screenshots and emits only files carrying the
/// system screenshot metadata attribute. Filename matching is deliberately avoided: names are
/// localized and user-configurable, while the metadata survives those changes.
///
/// The monitor also watches `com.apple.screencapture.plist`, rebasing itself without ingesting
/// existing files when the user changes the destination in Screenshot settings.
@MainActor
final class ScreenshotMonitor {
    var onScreenshots: (([URL]) -> Void)?

    private var directoryWatcher: FileChangeWatcher?
    private var preferencesWatcher: FileChangeWatcher?
    private var retryTask: Task<Void, Never>?

    private var directoryURL: URL?
    private var knownPaths: Set<String> = []
    private var pendingSince: [String: Date] = [:]
    /// Prevents a temporarily unreadable directory from replaying its entire screenshot history
    /// if access becomes available after activation.
    private var acceptCapturesAfter = Date.distantFuture
    private var isRunning = false

    private static let screenshotAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
    private static let pendingLifetime: TimeInterval = 3
    private static let maximumFileSize: Int64 = 512 * 1024 * 1024

    private static var preferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.screencapture.plist")
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let watcher = FileChangeWatcher(url: Self.preferencesURL, debounce: 0.3) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reconfigureIfNeeded()
                }
            }
        }
        preferencesWatcher = watcher
        watcher.start()

        reconfigureIfNeeded(force: true)
    }

    func stop() {
        isRunning = false
        directoryWatcher?.stop()
        directoryWatcher = nil
        preferencesWatcher?.stop()
        preferencesWatcher = nil
        retryTask?.cancel()
        retryTask = nil
        directoryURL = nil
        knownPaths.removeAll()
        pendingSince.removeAll()
        acceptCapturesAfter = .distantFuture
    }

    // MARK: Directory configuration

    private func reconfigureIfNeeded(force: Bool = false) {
        guard isRunning else { return }
        let destination = Self.configuredScreenshotDirectory()
        guard force || destination != directoryURL else { return }

        directoryWatcher?.stop()
        directoryWatcher = nil
        retryTask?.cancel()
        retryTask = nil

        directoryURL = destination
        pendingSince.removeAll()
        acceptCapturesAfter = Date()
        knownPaths = Set(Self.contents(of: destination).map(\.path))

        let watcher = FileChangeWatcher(url: destination, debounce: 0.35) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scan()
                }
            }
        }
        directoryWatcher = watcher
        watcher.start()
    }

    private static func configuredScreenshotDirectory() -> URL {
        let fallback = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

        guard let data = try? Data(contentsOf: preferencesURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any],
              let rawLocation = dictionary["location"] as? String,
              !rawLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallback.standardizedFileURL
        }

        let expanded = NSString(string: rawLocation).expandingTildeInPath
        if let fileURL = URL(string: expanded), fileURL.isFileURL {
            return fileURL.standardizedFileURL
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
    }

    // MARK: Discovery

    private func scan() {
        guard isRunning, let directoryURL else { return }
        let now = Date()
        let current = Self.contents(of: directoryURL)
        let currentPaths = Set(current.map(\.path))

        knownPaths.formIntersection(currentPaths)
        pendingSince = pendingSince.filter { currentPaths.contains($0.key) }

        var captures: [(url: URL, date: Date)] = []
        var needsRetry = false

        for url in current where !knownPaths.contains(url.path) {
            let firstSeen = pendingSince[url.path] ?? now
            pendingSince[url.path] = firstSeen

            if Self.isCompleteScreenshot(url, inside: directoryURL) {
                let values = try? url.resourceValues(forKeys: [
                    .creationDateKey,
                    .contentModificationDateKey,
                ])
                let capturedAt = values?.creationDate ?? values?.contentModificationDate ?? now
                if capturedAt >= acceptCapturesAfter.addingTimeInterval(-1) {
                    captures.append((url, capturedAt))
                }
                knownPaths.insert(url.path)
                pendingSince.removeValue(forKey: url.path)
            } else if now.timeIntervalSince(firstSeen) >= Self.pendingLifetime {
                // A normal file created in the same directory should not remain a candidate
                // forever. Screenshot files receive their metadata as part of the save.
                knownPaths.insert(url.path)
                pendingSince.removeValue(forKey: url.path)
            } else {
                needsRetry = true
            }
        }

        if !captures.isEmpty {
            let sorted = captures.sorted { $0.date < $1.date }.map(\.url)
            onScreenshots?(sorted)
        }
        if needsRetry {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.scan()
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentTypeKey,
            .fileSizeKey,
            .totalFileSizeKey,
        ]
        return (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isCompleteScreenshot(_ url: URL, inside directory: URL) -> Bool {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == directory.standardizedFileURL else {
            return false
        }

        guard let values = try? standardized.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .contentTypeKey,
            .fileSizeKey,
            .totalFileSizeKey,
        ]),
        values.isRegularFile == true,
        values.isSymbolicLink != true
        else {
            return false
        }

        let type = values.contentType
            ?? UTType(filenameExtension: standardized.pathExtension)
            ?? .data
        guard type.conforms(to: .image) || type.conforms(to: .pdf) else { return false }

        let size = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        guard size > 0, size <= maximumFileSize else { return false }

        return standardized.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, screenshotAttribute, nil, 0, 0, 0) >= 0
        }
    }
}
