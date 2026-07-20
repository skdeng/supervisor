import CoreServices
import Foundation

/// Calls `onChange` when anything below `url` changes, using one recursive FSEvents stream.
///
/// Unlike a vnode `DispatchSource`, FSEvents follows changes through arbitrarily nested
/// directories. Events are coalesced because one logical write can arrive as several low-level
/// notifications. `onChange` runs on a private serial queue, not the main actor.
final class DirectoryTreeWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let callback: @Sendable () -> Void

        init(callback: @escaping @Sendable () -> Void) {
            self.callback = callback
        }
    }

    private static let streamCallback: FSEventStreamCallback = {
        _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().callback()
    }

    private let url: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.supervisor.directory-tree-watcher")

    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?
    private var pendingNotification: DispatchWorkItem?
    private var isRunning = false

    init(url: URL, debounce: TimeInterval = 0.25, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        pendingNotification?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isRunning else { return }
            isRunning = true
            createStream()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            isRunning = false
            pendingNotification?.cancel()
            pendingNotification = nil
            destroyStream()
        }
    }

    // MARK: - Queue-confined internals

    private func createStream() {
        guard isRunning, stream == nil else { return }

        let box = CallbackBox { [weak self] in self?.scheduleNotification() }
        callbackBox = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            Self.streamCallback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        ) else {
            callbackBox = nil
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            destroyStream()
        }
    }

    private func destroyStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }

    private func scheduleNotification() {
        guard isRunning else { return }
        pendingNotification?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, isRunning else { return }
            pendingNotification = nil
            onChange()
        }
        pendingNotification = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
