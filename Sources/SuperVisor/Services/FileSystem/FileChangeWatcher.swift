import Foundation

/// Calls `onChange` whenever the file or directory at `url` is written, replaced, created, or
/// removed. For a directory, adding or removing a direct child counts as a write.
///
/// A vnode `DispatchSource` watches an open descriptor — an *inode*, not a path. A writer that
/// updates a file atomically (write a temporary, `rename(2)` it into place) leaves that
/// descriptor pointing at the old, now-unlinked inode, and no later write is ever reported. So
/// a `.rename` / `.delete` / `.revoke` event tears the watch down and re-arms it on whatever
/// currently lives at the path. While nothing lives there, the parent directory is watched
/// instead and the file watch re-arms the moment the file reappears — so a watcher started
/// before its file exists still works.
///
/// Callbacks are coalesced over `debounce`: a writer that rewrites a file in several `write(2)`
/// calls, or replaces it (delete + create), would otherwise deliver an event per syscall.
///
/// `onChange` runs on a private serial queue, not the main actor.
final class FileChangeWatcher: @unchecked Sendable {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void

    /// Every stored property below is read and written only on this queue, which is what makes
    /// the `@unchecked Sendable` conformance sound.
    private let queue = DispatchQueue(label: "com.supervisor.file-change-watcher")

    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var pendingNotification: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var isRunning = false

    /// Used only when neither the file nor its parent directory can be opened: there is no
    /// descriptor to hang a vnode watch on, so the path has to be revisited on a timer.
    private static let missingParentRetryInterval: TimeInterval = 60

    init(url: URL, debounce: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        // `DispatchSource.cancel()` is safe to call from any thread; the cancel handlers close
        // the descriptors.
        fileSource?.cancel()
        directorySource?.cancel()
        pendingNotification?.cancel()
        retry?.cancel()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isRunning else { return }
            isRunning = true
            arm()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            isRunning = false
            teardownFile()
            teardownDirectory()
            pendingNotification?.cancel()
            pendingNotification = nil
            retry?.cancel()
            retry = nil
        }
    }

    // MARK: - Queue-confined internals

    private func arm() {
        guard isRunning else { return }
        retry?.cancel()
        retry = nil

        if armFile() {
            teardownDirectory()
        } else {
            armDirectory()
        }
    }

    /// Watch the file itself. Returns false when the path currently holds no openable file.
    private func armFile() -> Bool {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            let events = source.data
            // The inode this descriptor names is gone. The path may already hold a replacement,
            // but this watch can never see it, so rebuild against whatever is there now.
            if !events.intersection([.delete, .rename, .revoke]).isEmpty {
                teardownFile()
                arm()
            }
            scheduleNotification()
        }
        source.setCancelHandler { close(descriptor) }

        fileSource = source
        source.resume()
        return true
    }

    /// Watch the parent directory until the file appears.
    private func armDirectory() {
        teardownDirectory()

        let directory = url.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRetry()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, isRunning else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            teardownDirectory()
            if armFile() {
                scheduleNotification()
            }
        }
        source.setCancelHandler { close(descriptor) }

        directorySource = source
        source.resume()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.arm() }
        retry = item
        queue.asyncAfter(deadline: .now() + Self.missingParentRetryInterval, execute: item)
    }

    private func scheduleNotification() {
        pendingNotification?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, isRunning else { return }
            pendingNotification = nil
            onChange()
        }
        pendingNotification = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func teardownFile() {
        fileSource?.cancel()
        fileSource = nil
    }

    private func teardownDirectory() {
        directorySource?.cancel()
        directorySource = nil
    }
}
