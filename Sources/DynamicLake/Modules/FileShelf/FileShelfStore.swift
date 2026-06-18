import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// In-memory model for the DynaClip file shelf: the staged items, the current multi-select,
/// and the operations the UI invokes. Owns thumbnail generation and the Quick Look panel.
/// All mutation happens on the main actor; file I/O for compression hops off-actor inside
/// `FileActionService`.
@MainActor
final class FileShelfStore: ObservableObject {
    /// Staged items, newest first.
    @Published private(set) var files: [StagedFile] = []
    /// Currently selected item ids for multi-select actions.
    @Published var selection: Set<UUID> = []
    /// Set briefly true right after a drop so the compact badge can pulse/peek.
    @Published private(set) var didJustReceive: Bool = false
    /// Surfaced when an action fails; the expanded UI shows it transiently.
    @Published var lastError: String?

    private let quickLook = QuickLookController()
    private var pulseTask: Task<Void, Never>?

    /// Callbacks wired by the module so the store can drive the engine without importing it.
    var onCompactPresenceChanged: (() -> Void)?
    var onDropPeek: (() -> Void)?

    var isEmpty: Bool { files.isEmpty }
    var count: Int { files.count }

    /// The URLs targeted by an action: the selection if non-empty, else all staged files.
    func actionURLs() -> [URL] {
        let targeted = files.filter { selection.contains($0.id) }
        let source = targeted.isEmpty ? files : targeted
        return source.map(\.url)
    }

    /// URLs for a single item.
    func urls(for ids: Set<UUID>) -> [URL] {
        files.filter { ids.contains($0.id) }.map(\.url)
    }

    // MARK: Staging

    /// Add file URLs to the shelf, skipping duplicates (by resolved path). Returns whether
    /// anything new was added so the caller can drive a peek/pulse and compact refresh.
    @discardableResult
    func add(urls: [URL]) -> Bool {
        let existing = Set(files.map { $0.url.standardizedFileURL.path })
        let fresh = urls
            .map { $0.resolvingSymlinksInPath() }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .filter { !existing.contains($0.standardizedFileURL.path) }

        guard !fresh.isEmpty else { return false }

        let wasEmpty = files.isEmpty
        let staged = fresh.map { StagedFile(url: $0) }
        // Newest first.
        files.insert(contentsOf: staged, at: 0)

        for file in staged {
            generateThumbnail(for: file)
        }

        if wasEmpty {
            // Compact presence just appeared; the pill needs to re-lay-out.
            onCompactPresenceChanged?()
        }
        pulseAndPeek()
        return true
    }

    // MARK: Removal

    func remove(_ id: UUID) {
        remove(ids: [id])
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let willBeEmpty = files.filter { !ids.contains($0.id) }.isEmpty
        files.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if willBeEmpty {
            onCompactPresenceChanged?()
        }
    }

    func removeSelected() {
        remove(ids: selection)
    }

    func clearAll() {
        guard !files.isEmpty else { return }
        files.removeAll()
        selection.removeAll()
        onCompactPresenceChanged?()
    }

    // MARK: Selection

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func selectOnly(_ id: UUID) {
        selection = [id]
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: Actions

    func airDrop(ids: Set<UUID>? = nil, anchor: NSView? = nil) {
        let urls = ids.map { self.urls(for: $0) } ?? actionURLs()
        do {
            try FileActionService.airDrop(urls, from: anchor)
        } catch {
            present(error)
        }
    }

    func revealInFinder(ids: Set<UUID>? = nil) {
        let urls = ids.map { self.urls(for: $0) } ?? actionURLs()
        FileActionService.revealInFinder(urls)
    }

    func quickLook(ids: Set<UUID>? = nil, startAt index: Int = 0) {
        let urls = ids.map { self.urls(for: $0) } ?? actionURLs()
        quickLook.preview(urls, startingAt: index)
    }

    func quickLookSingle(_ id: UUID) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        // Preview the whole shelf but start on the clicked item for fast navigation.
        quickLook.preview(files.map(\.url), startingAt: idx)
    }

    /// Compress the targeted items into a zip, then stage the resulting archive back onto
    /// the shelf so it can immediately be dragged out or AirDropped.
    func compress(ids: Set<UUID>? = nil) {
        let urls = ids.map { self.urls(for: $0) } ?? actionURLs()
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            do {
                let archive = try await FileActionService.compress(urls)
                guard let self else { return }
                self.add(urls: [archive])
                self.clearSelection()
            } catch {
                self?.present(error)
            }
        }
    }

    // MARK: Thumbnails

    private func generateThumbnail(for file: StagedFile) {
        let url = file.url
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        // The Task is main-actor isolated (the store is @MainActor); the actual generation
        // suspends off-actor inside `ThumbnailService`, and the result is applied here back
        // on the main actor.
        Task { [weak file] in
            let image = await ThumbnailService.thumbnail(for: url, scale: scale)
            guard let file, let image else { return }
            file.thumbnail = image
        }
    }

    // MARK: Drop pulse / peek

    private func pulseAndPeek() {
        onDropPeek?()
        didJustReceive = true
        pulseTask?.cancel()
        pulseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            self.didJustReceive = false
        }
    }

    // MARK: Errors

    private func present(_ error: Error) {
        lastError = error.localizedDescription
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if self.lastError == error.localizedDescription {
                self.lastError = nil
            }
        }
    }
}
