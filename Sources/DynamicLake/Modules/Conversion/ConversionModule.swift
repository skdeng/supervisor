import SwiftUI

/// Media conversion module. Drops audio/video files onto a notch drop zone, picks a target
/// format and quality, and runs the user-installed `ffmpeg` via `Process` with live progress
/// parsed from ffmpeg's `-progress` stream. Output is written next to the source.
///
/// FFmpeg is LGPL/GPL: we never bundle it; we invoke the user's installation, and surface an
/// inline `brew install ffmpeg` note when none is found.
@MainActor
final class ConversionModule: NotchModule, ObservableObject {
    let moduleID = "conversion"
    let displayName = "Conversion"
    let order = 80

    // MARK: Tools

    /// Located ffmpeg/ffprobe, resolved on `activate`. nil → not installed.
    @Published private(set) var tools: FFmpegLocator.Tools?
    /// True once we've attempted to locate ffmpeg (so the UI doesn't flash the install note).
    @Published private(set) var didLocate = false

    var isFFmpegAvailable: Bool { tools != nil }

    // MARK: Tasks

    /// All tasks, newest first — active ones plus a bounded tail of recent finished/failed.
    @Published private(set) var tasks: [ConversionTask] = []

    /// User's current format/quality selections (persisted in-memory for the session).
    @Published var selectedFormat: TargetFormat = .mp3
    @Published var selectedQuality: ConversionQuality = .balanced
    /// The media kind the picker is currently scoped to, inferred from the last dropped or
    /// hovered file; controls which formats the picker offers.
    @Published var pickerKind: MediaKind = .audio

    /// How many recent terminal tasks to keep around after they finish.
    private let recentLimit = 6

    private var context: NotchContext?

    /// Serial conversion queue: one ffmpeg at a time. Pending tasks wait in `tasks` as
    /// `.queued` until the runner frees up.
    private var activeRunner: ConversionRunner?
    private var pendingTasks: [ConversionTask] = []
    private var runningTask: ConversionTask?

    /// Whether any compact contribution is currently showing, so we only call
    /// `setNeedsCompactRefresh()` on real transitions.
    private var compactVisible = false

    // MARK: Lifecycle

    func activate(_ context: NotchContext) {
        self.context = context
        // Locate ffmpeg off the main actor (it may spawn a login shell), then publish.
        Task { [weak self] in
            let located = await Task.detached(priority: .userInitiated) {
                FFmpegLocator.locate()
            }.value
            guard let self else { return }
            self.tools = located
            self.didLocate = true
        }
    }

    func deactivate() {
        activeRunner?.cancel()
        activeRunner = nil
        runningTask = nil
        pendingTasks.removeAll()
        context = nil
    }

    // MARK: Public intent (called from views)

    var activeTasks: [ConversionTask] { tasks.filter { $0.state.isActive } }
    var recentTasks: [ConversionTask] { tasks.filter { $0.state.isTerminal } }
    var hasActiveConversions: Bool { tasks.contains { $0.state.isActive } }

    /// Overall progress across active tasks for the compact ring (0…1, nil = indeterminate).
    var aggregateProgress: Double? {
        let active = activeTasks
        guard !active.isEmpty else { return nil }
        var sum = 0.0
        var counted = 0
        for t in active {
            if case let .running(fraction) = t.state, let f = fraction {
                sum += f
                counted += 1
            } else if case .queued = t.state {
                counted += 1 // contributes 0
            }
        }
        guard counted > 0 else { return nil }
        return sum / Double(counted)
    }

    /// Updates the format picker scope when a file is hovered/dropped so only valid target
    /// formats are offered. Switches the selected format to a sensible default if the
    /// current selection no longer matches the kind.
    func updatePickerKind(for url: URL) {
        let kind = MediaKind.of(url: url)
        guard kind != pickerKind else { return }
        pickerKind = kind
        if selectedFormat.kind != kind {
            selectedFormat = kind == .audio ? .mp3 : .mp4
        }
    }

    /// Enqueues conversions for the dropped files using the current format/quality, scoping
    /// each output format to the file's media kind so audio files never target a video
    /// container and vice-versa.
    func enqueue(urls: [URL]) {
        guard isFFmpegAvailable else {
            context?.requestPeek(2.5)
            return
        }
        var added = false
        for url in urls {
            let kind = MediaKind.of(url: url)
            // Use the selected format when it matches the file kind; otherwise pick a
            // sane default for that kind so mixed drops still do the right thing.
            let format: TargetFormat = (selectedFormat.kind == kind)
                ? selectedFormat
                : (kind == .audio ? .mp3 : .mp4)
            let job = ConversionJob(source: url, format: format, quality: selectedQuality)
            let task = ConversionTask(job: job)
            tasks.insert(task, at: 0)
            pendingTasks.append(task)
            added = true
        }
        if added {
            trimRecent()
            refreshCompactVisibility()
            pumpQueue()
            // Nudge the panel open so the user sees progress begin.
            context?.requestPeek(2.0)
        }
    }

    /// Cancels an in-flight or queued task.
    func cancel(_ task: ConversionTask) {
        if task === runningTask {
            activeRunner?.cancel()
        } else {
            pendingTasks.removeAll { $0 === task }
            task.markCancelled()
            refreshCompactVisibility()
        }
    }

    /// Reveals a finished file in Finder.
    func revealInFinder(_ task: ConversionTask) {
        guard case .finished = task.state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([task.job.output])
    }

    /// Clears all terminal (finished/failed/cancelled) tasks from the list.
    func clearRecent() {
        tasks.removeAll { $0.state.isTerminal }
        refreshCompactVisibility()
    }

    // MARK: Queue pump

    /// Starts the next pending task if the single conversion slot is free.
    private func pumpQueue() {
        guard runningTask == nil, let tools else { return }
        guard let next = pendingTasks.first else { return }
        pendingTasks.removeFirst()
        runningTask = next

        let runner = ConversionRunner(tools: tools, task: next, job: next.job)
        activeRunner = runner

        Task { [weak self] in
            await runner.run()
            guard let self else { return }
            self.runningTask = nil
            self.activeRunner = nil
            self.refreshCompactVisibility()
            self.pumpQueue()
        }
    }

    /// Keeps only the newest `recentLimit` terminal tasks while retaining all active ones.
    private func trimRecent() {
        let terminal = tasks.filter { $0.state.isTerminal }
        guard terminal.count > recentLimit else { return }
        let keep = Set(terminal.prefix(recentLimit).map { ObjectIdentifier($0) })
        tasks.removeAll { $0.state.isTerminal && !keep.contains(ObjectIdentifier($0)) }
    }

    /// Recomputes whether a compact contribution should be visible and tells the engine to
    /// re-lay-out the pill only when that visibility actually flips.
    private func refreshCompactVisibility() {
        let shouldShow = hasActiveConversions
        guard shouldShow != compactVisible else { return }
        compactVisible = shouldShow
        context?.setNeedsCompactRefresh()
    }

    // MARK: UI contributions

    func compactTrailing() -> AnyView? {
        guard hasActiveConversions else { return nil }
        return AnyView(ConversionCompactView(module: self))
    }

    func expandedSection() -> AnyView? {
        AnyView(ConversionExpandedView(module: self))
    }
}
