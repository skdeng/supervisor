import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

/// In-memory model for staged local files and their actions. The store owns screenshot
/// discovery, thumbnail generation, Quick Look, transient feedback, and agent operations.
@MainActor
final class FileShelfStore: ObservableObject {
    struct Feedback: Equatable {
        let message: String
        let isError: Bool
    }

    struct AgentVerb: Identifiable {
        let id: String
        let title: String
        let systemImage: String

        fileprivate let applicableContentTypes: [UTType]
        fileprivate let ask: String
        fileprivate let resultTitle: String

        fileprivate func applies(to contentType: UTType) -> Bool {
            applicableContentTypes.contains { contentType.conforms(to: $0) }
        }
    }

    private static let agentVerbCatalog: [AgentVerb] = [
        AgentVerb(
            id: "summarize",
            title: "Summarize",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            applicableContentTypes: [.text, .sourceCode, .pdf],
            ask: "produce a concise bullet-point summary of its contents, at most 200 words.",
            resultTitle: "Summary"
        ),
        AgentVerb(
            id: "explain",
            title: "Explain",
            systemImage: "questionmark.bubble",
            applicableContentTypes: [.text, .sourceCode, .pdf],
            ask: "explain what the file is and call out any errors or problems it shows.",
            resultTitle: "Explanation"
        ),
        AgentVerb(
            id: "extractText",
            title: "Extract Text",
            systemImage: "text.viewfinder",
            applicableContentTypes: [.image, .pdf],
            ask: "transcribe all legible text verbatim.",
            resultTitle: "Extracted Text"
        ),
    ]

    /// Staged items, newest first.
    @Published private(set) var files: [StagedFile] = []
    /// Currently selected item ids for multi-select actions.
    @Published var selection: Set<UUID> = []
    /// Set briefly true right after a drop so the compact badge can pulse/peek.
    @Published private(set) var didJustReceive: Bool = false
    /// Screenshot currently receiving the compact arrival treatment.
    @Published private(set) var arrivalItem: StagedFile?
    /// Item whose contents are being recognized by Vision.
    @Published private(set) var recognizingID: UUID?
    /// Latest success or error message shown in the expanded surface.
    @Published private(set) var feedback: Feedback?

    let operations = OperationCenter()

    private struct ActiveAgentDispatch {
        let service: AgentTaskService
        let operation: LiveOperation
        let fileID: UUID
        let activationGeneration: UUID
    }

    private let quickLook = QuickLookController()
    private let screenshotMonitor = ScreenshotMonitor()
    private var pulseTask: Task<Void, Never>?
    private var arrivalTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var activationGeneration = UUID()
    private var activeAgentDispatches: [UUID: ActiveAgentDispatch] = [:]
    private let maximumScreenshotItems = 8

    @Published private(set) var activeOperationCount = 0

    /// Callbacks wired by the module so the store can drive the engine without importing it.
    var onCompactPresenceChanged: (() -> Void)?
    var onDropPeek: (() -> Void)?
    var onScreenshotPeek: (() -> Void)?

    var isEmpty: Bool { files.isEmpty }
    var count: Int { files.count }
    var hasActiveOperations: Bool { activeOperationCount > 0 }
    private var hasCompactPresence: Bool {
        !files.isEmpty || hasActiveOperations || arrivalItem != nil
    }

    func beginActivation() {
        activationGeneration = UUID()
        screenshotMonitor.onScreenshots = { [weak self] urls in
            self?.receiveScreenshots(urls)
        }
        screenshotMonitor.start()
    }

    func endActivation() {
        screenshotMonitor.stop()
        screenshotMonitor.onScreenshots = nil
        cancelAllOperations()
        clearAll()
        operations.removeAll()
        pulseTask?.cancel()
        pulseTask = nil
        arrivalTask?.cancel()
        arrivalTask = nil
        feedbackTask?.cancel()
        feedbackTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        didJustReceive = false
        arrivalItem = nil
        recognizingID = nil
        feedback = nil
        quickLook.close()
        activationGeneration = UUID()
    }

    /// Items targeted by an action: explicit ids, the current selection, or the full shelf.
    func actionFiles(ids: Set<UUID>? = nil) -> [StagedFile] {
        if let ids {
            return files.filter { ids.contains($0.id) }
        }
        if !selection.isEmpty {
            return files.filter { selection.contains($0.id) }
        }
        return files
    }

    func actionURLs(ids: Set<UUID>? = nil) -> [URL] {
        actionFiles(ids: ids).map(\.url)
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
        let staged = stage(urls: urls, source: .dropped)
        guard !staged.isEmpty else { return false }
        pulseAndPeek()
        return true
    }

    private func addGeneratedResult(_ url: URL) -> Bool {
        let staged = stage(
            urls: [url],
            source: .generated,
            appOwnedGeneratedArtifacts: true
        )
        guard !staged.isEmpty else { return false }
        pulseAndPeek()
        return true
    }

    private func receiveScreenshots(_ urls: [URL]) {
        let entries = urls.map { url -> (url: URL, addedAt: Date) in
            let values = try? url.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
            ])
            return (
                url,
                values?.creationDate ?? values?.contentModificationDate ?? Date()
            )
        }
        let staged = stage(entries: entries, source: .screenshot)
        guard let newest = staged.max(by: { $0.addedAt < $1.addedAt }) else { return }
        presentArrival(newest)
    }

    private func stage(
        urls: [URL],
        source: ItemSource,
        appOwnedGeneratedArtifacts: Bool = false
    ) -> [StagedFile] {
        stage(
            entries: urls.map { ($0, Date()) },
            source: source,
            appOwnedGeneratedArtifacts: appOwnedGeneratedArtifacts
        )
    }

    private func stage(
        entries: [(url: URL, addedAt: Date)],
        source: ItemSource,
        appOwnedGeneratedArtifacts: Bool = false
    ) -> [StagedFile] {
        var knownPaths = Set(files.map { $0.url.standardizedFileURL.path })
        var fresh: [(url: URL, addedAt: Date)] = []
        for entry in entries {
            let resolved = entry.url.resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: resolved.path),
                  knownPaths.insert(resolved.path).inserted
            else { continue }
            fresh.append((resolved, entry.addedAt))
        }
        guard !fresh.isEmpty else { return [] }

        let hadCompactPresence = hasCompactPresence
        var staged = fresh.map {
            StagedFile(
                url: $0.url,
                addedAt: $0.addedAt,
                source: source,
                isAppOwnedGeneratedArtifact: appOwnedGeneratedArtifacts
            )
        }
        if source == .screenshot {
            staged.sort { $0.addedAt > $1.addedAt }
        }
        files.insert(contentsOf: staged, at: 0)

        for file in staged {
            generateThumbnail(for: file)
        }

        if source == .screenshot {
            let screenshots = files
                .filter { $0.source == .screenshot }
                .sorted { $0.addedAt > $1.addedAt }
            let overflow = Set(screenshots.dropFirst(maximumScreenshotItems).map(\.id))
            remove(ids: overflow)
        }

        if hadCompactPresence != hasCompactPresence {
            onCompactPresenceChanged?()
        }
        return staged.filter { stagedFile in
            files.contains { $0.id == stagedFile.id }
        }
    }

    // MARK: Removal

    func remove(_ id: UUID) {
        remove(ids: [id])
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removedFiles = files.filter { ids.contains($0.id) }
        guard !removedFiles.isEmpty else { return }
        let hadCompactPresence = hasCompactPresence

        for file in removedFiles {
            file.activeOperation?.cancel()
        }
        files.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let recognizingID, ids.contains(recognizingID) {
            recognitionTask?.cancel()
            recognitionTask = nil
            self.recognizingID = nil
        }
        for file in removedFiles where file.isAppOwnedGeneratedArtifact {
            AppManagedFileStorage.removeGeneratedArtifact(file.url)
        }

        if hadCompactPresence != hasCompactPresence {
            onCompactPresenceChanged?()
        }
    }

    func removeSelected() {
        remove(ids: selection)
    }

    func clearAll() {
        guard !files.isEmpty else { return }
        let removedFiles = files
        let hadCompactPresence = hasCompactPresence
        for file in removedFiles {
            file.activeOperation?.cancel()
        }
        files.removeAll()
        selection.removeAll()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizingID = nil
        for file in removedFiles where file.isAppOwnedGeneratedArtifact {
            AppManagedFileStorage.removeGeneratedArtifact(file.url)
        }
        if hadCompactPresence != hasCompactPresence {
            onCompactPresenceChanged?()
        }
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

    func copyToPasteboard(ids: Set<UUID>? = nil) {
        let targets = actionFiles(ids: ids)
        guard !targets.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if targets.count == 1,
           let file = targets.first,
           file.contentType.conforms(to: .image) {
            guard let image = NSImage(contentsOf: file.url),
                  pasteboard.writeObjects([image])
            else {
                showFeedback("Couldn’t copy the image.", isError: true)
                return
            }
            showFeedback("Image copied")
            return
        }

        let urls = targets.map { $0.url as NSURL }
        guard pasteboard.writeObjects(urls) else {
            showFeedback("Couldn’t copy the selected files.", isError: true)
            return
        }
        showFeedback(targets.count == 1 ? "File copied" : "Files copied")
    }

    func copyRecognizedText(id: UUID) {
        guard recognizingID == nil,
              let file = files.first(where: { $0.id == id }),
              file.contentType.conforms(to: .image) || file.contentType.conforms(to: .pdf)
        else { return }

        recognizingID = id
        recognitionTask?.cancel()
        recognitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let text = try await ScreenshotTextRecognizer.recognizeText(at: file.url)
                guard !Task.isCancelled else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    throw FileShelfActionError.copyRecognizedTextFailed
                }
                self.showFeedback("Text copied")
            } catch is CancellationError {
                // Removing the item or deactivating the module cancels recognition.
            } catch {
                self.present(error)
            }
            if self.recognizingID == id {
                self.recognizingID = nil
            }
            self.recognitionTask = nil
        }
    }

    func moveToTrash(ids: Set<UUID>? = nil) {
        let targets = actionFiles(ids: ids)
        guard !targets.isEmpty else { return }

        var movedIDs: Set<UUID> = []
        var identityFailed = false
        var firstError: Error?
        for file in targets {
            guard let expectedIdentity = file.fileIdentity,
                  FileSystemIdentity.regularFile(at: file.url) == expectedIdentity
            else {
                identityFailed = true
                continue
            }
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(
                    at: file.url,
                    resultingItemURL: &trashedURL
                )
                movedIDs.insert(file.id)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        remove(ids: movedIDs)
        if identityFailed {
            showFeedback(FileShelfActionError.fileChanged.localizedDescription, isError: true)
        } else if let firstError {
            present(firstError)
        } else if !movedIDs.isEmpty {
            showFeedback(
                movedIDs.count == 1
                    ? "Moved to Trash"
                    : "\(movedIDs.count) items moved to Trash"
            )
        }
    }

    func airDrop(ids: Set<UUID>? = nil, anchor: NSView? = nil) {
        let urls = actionURLs(ids: ids)
        do {
            try FileActionService.airDrop(urls, from: anchor)
        } catch {
            present(error)
        }
    }

    func revealInFinder(ids: Set<UUID>? = nil) {
        let urls = actionURLs(ids: ids)
        FileActionService.revealInFinder(urls)
    }

    func quickLook(ids: Set<UUID>? = nil, startAt index: Int = 0) {
        let urls = actionURLs(ids: ids)
        quickLook.preview(urls, startingAt: index)
    }

    func quickLookSingle(_ id: UUID) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        // Preview the whole shelf but start on the clicked item for fast navigation.
        quickLook.preview(files.map(\.url), startingAt: idx)
    }

    func agentVerbs(for id: UUID) -> [AgentVerb] {
        guard let file = files.first(where: { $0.id == id }), !file.isDirectory else {
            return []
        }
        return Self.agentVerbCatalog.filter { $0.applies(to: file.contentType) }
    }

    func dispatchAgentVerb(_ verb: AgentVerb, on id: UUID) {
        guard let file = files.first(where: { $0.id == id }),
              !file.isDirectory,
              file.activeOperation == nil,
              let configuredVerb = Self.agentVerbCatalog.first(where: { $0.id == verb.id }),
              configuredVerb.applies(to: file.contentType)
        else { return }

        let service = AgentTaskService()
        let operation = operations.begin(
            title: configuredVerb.title,
            detail: file.displayName,
            onCancel: { service.cancel() }
        )
        file.activeOperation = operation

        let fileURL = file.url
        let sourceIdentity = file.fileIdentity
        let sourceDisplayName = file.displayName
        let generation = activationGeneration
        registerActiveDispatch(
            service: service,
            operation: operation,
            fileID: file.id,
            generation: generation
        )

        Task { [self, file] in
            defer {
                if operation.isActive {
                    operation.finishCancellation()
                }
                finishActiveDispatch(operationID: operation.id, file: file)
            }

            do {
                guard let sourceIdentity else {
                    throw AgentTaskError.unreadableSource
                }
                let result = try await service.run(
                    request: configuredVerb.ask,
                    sourceURL: fileURL,
                    expectedIdentity: sourceIdentity
                )
                guard operation.state == .running else {
                    throw AgentTaskError.cancelled
                }

                let resultURL = try await Task.detached(priority: .utility) {
                    try AppManagedFileStorage.writeResult(
                        result.text,
                        sourceBasename: sourceDisplayName,
                        resultTitle: configuredVerb.resultTitle
                    )
                }.value
                guard operation.state == .running,
                      isCurrentSource(
                        file,
                        operationID: operation.id,
                        expectedIdentity: sourceIdentity,
                        generation: generation
                      )
                else {
                    AppManagedFileStorage.removeGeneratedArtifact(resultURL)
                    throw AgentTaskError.cancelled
                }

                guard addGeneratedResult(resultURL) else {
                    AppManagedFileStorage.removeGeneratedArtifact(resultURL)
                    throw AgentResultError.couldNotStage
                }
                operation.succeed(costUSD: result.costUSD)
            } catch let error as AgentTaskError {
                if case .cancelled = error {
                    operation.finishCancellation()
                    return
                }
                if operation.state == .cancelling {
                    operation.finishCancellation()
                    return
                }
                operation.fail(error.localizedDescription)
                present(error)
            } catch {
                if operation.state == .cancelling {
                    operation.finishCancellation()
                    return
                }
                operation.fail(error.localizedDescription)
                present(error)
            }
        }
    }

    func cancelAllOperations() {
        let activeDispatches = Array(activeAgentDispatches.values)
        guard !activeDispatches.isEmpty else { return }

        for dispatch in activeDispatches {
            dispatch.operation.cancel()
            dispatch.service.cancel()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline,
              activeDispatches.contains(where: { $0.service.hasUnresolvedTask }) {
            for dispatch in activeDispatches {
                dispatch.service.pollForTermination()
            }
            Darwin.usleep(10_000)
        }

        for dispatch in activeDispatches {
            if dispatch.service.hasUnresolvedTask {
                dispatch.service.forceStopForTeardown()
            }
            dispatch.operation.finishCancellation()
        }

        let hadActiveOperations = hasActiveOperations
        for file in files {
            if let operation = file.activeOperation,
               activeAgentDispatches[operation.id] != nil {
                file.activeOperation = nil
            }
        }
        activeAgentDispatches.removeAll()
        activeOperationCount = 0
        if hadActiveOperations {
            onCompactPresenceChanged?()
        }
    }

    /// Compress the targeted items into a zip, then stage the resulting archive back onto
    /// the shelf so it can immediately be dragged out or AirDropped.
    func compress(ids: Set<UUID>? = nil) {
        let urls = actionURLs(ids: ids)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            do {
                let archive = try await FileActionService.compress(urls)
                guard let self else {
                    try? FileManager.default.removeItem(at: archive)
                    return
                }
                guard self.add(urls: [archive]) else {
                    try? FileManager.default.removeItem(at: archive)
                    return
                }
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

    // MARK: Agent lifecycle

    private func registerActiveDispatch(
        service: AgentTaskService,
        operation: LiveOperation,
        fileID: UUID,
        generation: UUID
    ) {
        let wasEmpty = activeAgentDispatches.isEmpty
        activeAgentDispatches[operation.id] = ActiveAgentDispatch(
            service: service,
            operation: operation,
            fileID: fileID,
            activationGeneration: generation
        )
        activeOperationCount = activeAgentDispatches.count
        if wasEmpty {
            onCompactPresenceChanged?()
        }
    }

    private func finishActiveDispatch(operationID: UUID, file: StagedFile) {
        guard activeAgentDispatches.removeValue(forKey: operationID) != nil else { return }
        if file.activeOperation?.id == operationID {
            file.activeOperation = nil
        }
        activeOperationCount = activeAgentDispatches.count
        if activeAgentDispatches.isEmpty {
            onCompactPresenceChanged?()
        }
    }

    private func isCurrentSource(
        _ file: StagedFile,
        operationID: UUID,
        expectedIdentity: FileSystemIdentity,
        generation: UUID
    ) -> Bool {
        guard activationGeneration == generation,
              let dispatch = activeAgentDispatches[operationID],
              dispatch.fileID == file.id,
              dispatch.activationGeneration == generation,
              let current = files.first(where: { $0.id == file.id })
        else { return false }
        return current === file && current.fileIdentity == expectedIdentity
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

    // MARK: Screenshot arrival

    private func presentArrival(_ item: StagedFile) {
        let hadCompactPresence = hasCompactPresence
        arrivalItem = item
        if hadCompactPresence != hasCompactPresence {
            onCompactPresenceChanged?()
        }
        onScreenshotPeek?()

        arrivalTask?.cancel()
        arrivalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.2))
            guard let self, !Task.isCancelled else { return }
            self.arrivalTask = nil
            let hadCompactPresence = self.hasCompactPresence
            self.arrivalItem = nil
            if hadCompactPresence != self.hasCompactPresence {
                self.onCompactPresenceChanged?()
            }
        }
    }

    // MARK: Feedback

    private func present(_ error: Error) {
        showFeedback(error.localizedDescription, isError: true)
    }

    private func showFeedback(_ message: String, isError: Bool = false) {
        feedback = Feedback(message: message, isError: isError)
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            if self.feedback?.message == message {
                self.feedback = nil
            }
            self.feedbackTask = nil
        }
    }
}

private enum AgentResultError: LocalizedError {
    case couldNotStage

    var errorDescription: String? {
        "Could not add the agent result to the shelf."
    }
}

private enum FileShelfActionError: LocalizedError {
    case copyRecognizedTextFailed
    case fileChanged

    var errorDescription: String? {
        switch self {
        case .copyRecognizedTextFailed:
            return "Couldn’t copy recognized text."
        case .fileChanged:
            return "The file changed after it was staged, so it was not moved to Trash."
        }
    }
}
