import Darwin
import Foundation
import Testing

@testable import SuperVisor

@Suite("Unix socket listener")
struct UnixSocketListenerTests {
    private func makeListener(
        at path: String,
        onConnection: @escaping @Sendable (Int32) -> Void
    ) -> UnixSocketListener {
        UnixSocketListener(
            path: path,
            queue: DispatchQueue(label: "unix-socket-listener-tests"),
            onConnection: onConnection
        )
    }

    private func mode(of path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    /// Reads up to `count` bytes, bounded so a failing test cannot hang.
    private func readBytes(from descriptor: Int32, count: Int) -> String {
        var reader = BridgeLineReader(descriptor: descriptor, limit: count)
        guard case let .line(data) = reader.next(timeout: 5) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("The owner receives each connection and can exchange bytes over it")
    func ownerReceivesDescriptor() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")

        let listener = makeListener(at: path) { connection in
            defer { close(connection) }
            var reader = BridgeLineReader(descriptor: connection, limit: 64)
            guard case let .line(data) = reader.next(timeout: 5) else { return }
            _ = BridgeWire.writeLine(Data("echo:".utf8) + data, to: connection)
        }
        try listener.start()
        defer { listener.stop() }

        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        #expect(BridgeWire.writeLine(Data("hello".utf8), to: client))
        #expect(readBytes(from: client, count: 64) == "echo:hello")
    }

    @Test("Connections are served one at a time, in order, on the given queue")
    func connectionsAreSerialized() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")
        let probe = ConcurrencyProbe()
        let threads = Recorder<Bool>()

        let listener = makeListener(at: path) { connection in
            probe.enter()
            threads.record(Thread.isMainThread)
            usleep(100_000)
            probe.leave()
            close(connection)
        }
        try listener.start()
        defer { listener.stop() }

        let clients = (0..<3).compactMap { _ in UnixSocket.connect(to: path) }
        defer { clients.forEach { close($0) } }
        #expect(clients.count == 3)

        let deadline = Date().addingTimeInterval(5)
        while probe.startedCount < 3, Date() < deadline { usleep(10_000) }
        #expect(probe.startedCount == 3)
        #expect(probe.peakConcurrency == 1)
    }

    @Test("Accepted descriptors are blocking and closed across exec")
    func acceptedDescriptorsAreConfigured() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")
        let flags = Recorder<(status: Int32, descriptor: Int32)>()

        let listener = makeListener(at: path) { connection in
            flags.record((fcntl(connection, F_GETFL), fcntl(connection, F_GETFD)))
            close(connection)
        }
        try listener.start()
        defer { listener.stop() }

        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let deadline = Date().addingTimeInterval(5)
        while flags.all.isEmpty, Date() < deadline { usleep(10_000) }

        let observed = try #require(flags.all.first)
        #expect(observed.status & O_NONBLOCK == 0)
        #expect(observed.descriptor & FD_CLOEXEC != 0)
    }

    @Test("A connection whose peer closed before it was accepted still arrives exempt from SIGPIPE")
    func goneClientConnectionIsExempt() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")
        let exemptions = Recorder<Int32>()
        let firstHandled = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)

        // The first connection holds the accept queue until `releaseFirst` is signalled, so the
        // second client is gone by the time its connection is accepted. The wait is bounded, and
        // the signal is sent from a `defer` that runs before the listener's `stop`, which waits
        // for the queue.
        let listener = makeListener(at: path) { connection in
            var value: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &value, &length)
            let isFirst = exemptions.all.isEmpty
            exemptions.record(value)
            close(connection)
            if isFirst {
                firstHandled.signal()
                _ = releaseFirst.wait(timeout: .now() + 10)
            }
        }
        try listener.start()
        defer { listener.stop() }
        defer { releaseFirst.signal() }

        let first = try #require(UnixSocket.connect(to: path))
        defer { close(first) }
        try #require(firstHandled.wait(timeout: .now() + 5) == .success)
        let second = try #require(UnixSocket.connect(to: path))
        close(second)
        usleep(100_000)
        releaseFirst.signal()

        let deadline = Date().addingTimeInterval(5)
        while exemptions.all.count < 2, Date() < deadline { usleep(10_000) }
        #expect(exemptions.all == [1, 1])
    }

    @Test("The socket file is mode 0600 inside a folder created 0700")
    func permissions() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        // A folder that does not exist yet, so the listener creates it.
        let nested = folder.path("inner")
        let path = nested + "/s.sock"

        let listener = makeListener(at: path) { close($0) }
        try listener.start()
        defer { listener.stop() }

        let socketMode = try #require(mode(of: path))
        #expect(socketMode & S_IFMT == S_IFSOCK)
        #expect(socketMode & 0o777 == 0o600)
        let folderMode = try #require(mode(of: nested))
        #expect(folderMode & 0o777 == 0o700)
    }

    @Test("A stale socket file is replaced")
    func staleSocketIsReplaced() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")

        // Bind and close without unlinking: the file remains and refuses connections.
        var address = try #require(UnixSocket.address(for: path))
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        #expect(bound == 0)
        #expect(mode(of: path) != nil)
        #expect(UnixSocket.connect(to: path) == nil)

        let accepted = Recorder<Bool>()
        let listener = makeListener(at: path) { connection in
            accepted.record(true)
            close(connection)
        }
        try listener.start()
        defer { listener.stop() }

        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let deadline = Date().addingTimeInterval(5)
        while accepted.all.isEmpty, Date() < deadline { usleep(10_000) }
        #expect(accepted.all.count == 1)
    }

    @Test("Stop removes the socket file, refuses new connections, and is safe twice")
    func stopRemovesTheSocket() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")

        let listener = makeListener(at: path) { close($0) }
        try listener.start()
        #expect(mode(of: path) != nil)

        listener.stop()
        #expect(mode(of: path) == nil)
        #expect(UnixSocket.connect(to: path) == nil)

        listener.stop()
        #expect(mode(of: path) == nil)
    }

    @Test("Stopping a listener that never started leaves a file at its path alone")
    func stopWithoutStartIsInert() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")
        try Data("other".utf8).write(to: URL(fileURLWithPath: path))

        makeListener(at: path) { close($0) }.stop()
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Starting twice keeps the first socket bound")
    func startTwiceIsIdempotent() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")
        let accepted = Recorder<Bool>()

        let listener = makeListener(at: path) { connection in
            accepted.record(true)
            close(connection)
        }
        try listener.start()
        try listener.start()
        defer { listener.stop() }

        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let deadline = Date().addingTimeInterval(5)
        while accepted.all.isEmpty, Date() < deadline { usleep(10_000) }
        #expect(accepted.all.count == 1)
    }

    @Test("A stopped listener can start again")
    func restartAfterStop() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("s.sock")
        let accepted = Recorder<Bool>()

        let listener = makeListener(at: path) { connection in
            accepted.record(true)
            close(connection)
        }
        try listener.start()
        listener.stop()
        try listener.start()
        defer { listener.stop() }

        let client = try #require(UnixSocket.connect(to: path))
        defer { close(client) }
        let deadline = Date().addingTimeInterval(5)
        while accepted.all.isEmpty, Date() < deadline { usleep(10_000) }
        #expect(accepted.all.count == 1)
    }

    @Test("A path that does not fit sun_path throws before touching the file system")
    func overLongPathThrows() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let nested = folder.path("inner")
        let path = nested + "/" + String(repeating: "a", count: UnixSocket.maximumPathBytes) + ".sock"

        let listener = makeListener(at: path) { close($0) }
        #expect(throws: UnixSocketListener.Failure.pathTooLong) {
            try listener.start()
        }
        #expect(!FileManager.default.fileExists(atPath: nested))
    }

    @Test("A path of exactly the longest fitting length binds")
    func longestFittingPathBinds() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let prefix = folder.path("") + "/"
        let nameLength = UnixSocket.maximumPathBytes - 1 - prefix.utf8.count
        try #require(nameLength > 0)
        let path = prefix + String(repeating: "b", count: nameLength)
        #expect(path.utf8.count == UnixSocket.maximumPathBytes - 1)

        let listener = makeListener(at: path) { close($0) }
        try listener.start()
        defer { listener.stop() }
        #expect(mode(of: path) != nil)

        let tooLong = path + "b"
        #expect(throws: UnixSocketListener.Failure.pathTooLong) {
            try makeListener(at: tooLong) { close($0) }.start()
        }
    }
}
