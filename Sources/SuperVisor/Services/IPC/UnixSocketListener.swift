import Darwin
import Foundation

/// Listens on a Unix-domain socket and hands each accepted connection's descriptor to its owner.
///
/// The socket file is mode 0600 inside a folder created 0700. Each connection arrives blocking,
/// close-on-exec, and exempt from SIGPIPE. `onConnection` runs on `queue`, one connection at a
/// time, and owns the descriptor it is given: it closes it.
final class UnixSocketListener: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// The path does not fit `sun_path` (104 bytes including the terminating NUL).
        case pathTooLong
        case socketFailed(errno: Int32)
        case bindFailed(errno: Int32)
        case listenFailed(errno: Int32)
    }

    private let path: String
    private let queue: DispatchQueue
    private let onConnection: @Sendable (Int32) -> Void

    // Access is confined to `queue`.
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(
        path: String,
        queue: DispatchQueue,
        onConnection: @escaping @Sendable (Int32) -> Void
    ) {
        self.path = path
        self.queue = queue
        self.onConnection = onConnection
    }

    deinit {
        if descriptor >= 0 {
            source?.cancel()
            close(descriptor)
            unlink(path)
        }
    }

    /// Binds and listens, replacing a socket file left behind by an earlier process. A no-op
    /// while already listening. Must not be called from `queue`.
    func start() throws {
        try queue.sync { try startOnQueue() }
    }

    /// Stops accepting, closes the listening descriptor, and removes the socket file. Waits for a
    /// connection being handed off at that moment. Safe to call twice. Must not be called from
    /// `queue`.
    func stop() {
        queue.sync {
            guard descriptor >= 0 else { return }
            source?.cancel()
            source = nil
            close(descriptor)
            descriptor = -1
            unlink(path)
        }
    }

    private func startOnQueue() throws {
        guard descriptor < 0 else { return }
        guard var address = UnixSocket.address(for: path) else { throw Failure.pathTooLong }

        // The socket's folder may not exist yet. Bind fails with ENOENT rather than creating it,
        // so the listener creates it first; a failure to create it surfaces as the bind error.
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(path)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure.socketFailed(errno: errno) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        UnixSocket.exemptFromSIGPIPE(listener)

        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard didBind == 0 else {
            let bindError = errno
            close(listener)
            throw Failure.bindFailed(errno: bindError)
        }
        guard listen(listener, SOMAXCONN) == 0 else {
            let listenError = errno
            close(listener)
            unlink(path)
            throw Failure.listenFailed(errno: listenError)
        }

        _ = chmod(path, S_IRUSR | S_IWUSR)
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
        descriptor = listener

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        self.source = source
        source.resume()
    }

    private func acceptPendingConnections() {
        while descriptor >= 0 {
            let connection = accept(descriptor, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            UnixSocket.prepare(connection)
            onConnection(connection)
        }
    }
}
