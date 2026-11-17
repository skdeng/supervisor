import Darwin
import Foundation
import Testing

@testable import SuperVisor

@MainActor
@Suite("Agent event socket")
struct AgentEventSocketTests {
    private static let approvalReply = #"{"decision":"ask"}"#

    private func payload(
        session: String = "s1",
        pid: Int = 4242,
        status: String = "processing"
    ) -> String {
        #"{"session_id":"\#(session)","cwd":"/tmp/project","event":"Stop","pid":\#(pid),"status":"\#(status)"}"#
    }

    /// Connects, sends `bytes`, half-closes so the server sees the end of the payload, and
    /// returns everything the server wrote back.
    private func send(_ bytes: Data, to path: String, halfClose: Bool = true) -> String {
        guard let descriptor = UnixSocket.connect(to: path) else { return "<no connection>" }
        defer { close(descriptor) }
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
                if count <= 0 { break }
                sent += count
            }
        }
        if halfClose { shutdown(descriptor, SHUT_WR) }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 256)
        var pending = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while poll(&pending, 1, 3_000) > 0 {
            let count = read(descriptor, &chunk, chunk.count)
            if count <= 0 { break }
            reply.append(chunk, count: count)
        }
        return String(decoding: reply, as: UTF8.self)
    }

    private func waitForEvents(
        _ received: Recorder<FleetHookEvent>,
        count: Int,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while received.all.count < count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A valid payload is delivered to onEvent on the main actor")
    func deliversEvent() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let socket = AgentEventSocket(socketPath: folder.path("e.sock"))
        let received = Recorder<FleetHookEvent>()
        socket.onEvent = { event in
            #expect(Thread.isMainThread)
            received.record(event)
        }
        socket.start()
        defer { socket.stop() }

        _ = send(Data(payload(session: "abc", pid: 77).utf8), to: folder.path("e.sock"))
        try await waitForEvents(received, count: 1)

        let event = try #require(received.all.first)
        #expect(event.sessionID == "abc")
        #expect(event.pid == 77)
        #expect(event.status == .processing)
        #expect(received.all.count == 1)
    }

    @Test("A payload that announces an approval wait gets the pass-through decision, and is still delivered")
    func approvalReply() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let socket = AgentEventSocket(socketPath: folder.path("e.sock"))
        let received = Recorder<FleetHookEvent>()
        socket.onEvent = { received.record($0) }
        socket.start()
        defer { socket.stop() }

        let reply = send(
            Data(payload(status: "waiting_for_approval").utf8),
            to: folder.path("e.sock")
        )
        #expect(reply == Self.approvalReply)
        try await waitForEvents(received, count: 1)
        #expect(received.all.first?.status == .waitingForApproval)
    }

    @Test("An approval wait is answered before the rest of a large payload arrives")
    func approvalReplyIsStreamed() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let socket = AgentEventSocket(socketPath: folder.path("e.sock"))
        socket.start()
        defer { socket.stop() }

        // The status field leads and the payload never finishes: the reply must not wait for it.
        let head = Data(#"{"status":"waiting_for_approval","tool_input":"#.utf8)
        let reply = send(head, to: folder.path("e.sock"), halfClose: false)
        #expect(reply == Self.approvalReply)
    }

    @Test("Garbage, truncated, and invalid payloads deliver nothing but still get the fixed reply")
    func malformedPayloads() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let socket = AgentEventSocket(socketPath: folder.path("e.sock"))
        let received = Recorder<FleetHookEvent>()
        socket.onEvent = { received.record($0) }
        socket.start()
        defer { socket.stop() }

        let bodies = [
            "garbage",
            #"{"session_id":"s1","cwd":"/tmp""#,
            payload(pid: 0),
            payload(session: ""),
            #"{"session_id":"s1","cwd":"/tmp","event":"Stop","pid":5,"status":"processing","message":"\#(String(repeating: "m", count: FleetHookEvent.maximumTextLength + 1))"}"#,
        ]
        for body in bodies {
            #expect(send(Data(body.utf8), to: folder.path("e.sock")) == Self.approvalReply, "\(body.prefix(40))")
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(received.all.isEmpty)
    }

    @Test("A payload over 64 KiB is dropped")
    func oversizedPayload() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let socket = AgentEventSocket(socketPath: folder.path("e.sock"))
        let received = Recorder<FleetHookEvent>()
        socket.onEvent = { received.record($0) }
        socket.start()
        defer { socket.stop() }

        let padding = String(repeating: "p", count: 70 * 1024)
        let body = #"{"session_id":"s1","cwd":"/tmp","event":"Stop","pid":5,"status":"processing","pad":"\#(padding)"}"#
        #expect(send(Data(body.utf8), to: folder.path("e.sock")) == Self.approvalReply)
        try await Task.sleep(for: .milliseconds(150))
        #expect(received.all.isEmpty)
    }

    @Test("Connections are served one after another")
    func serialDelivery() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let socket = AgentEventSocket(socketPath: folder.path("e.sock"))
        let received = Recorder<FleetHookEvent>()
        socket.onEvent = { received.record($0) }
        socket.start()
        defer { socket.stop() }

        for index in 1...5 {
            _ = send(Data(payload(session: "s\(index)", pid: 100 + index).utf8), to: folder.path("e.sock"))
        }
        try await waitForEvents(received, count: 5)
        #expect(Set(received.all.map(\.sessionID)) == ["s1", "s2", "s3", "s4", "s5"])
    }

    @Test("The socket file is mode 0600 in a folder created 0700, and stop removes it")
    func fileLifecycle() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let nested = folder.path("inner")
        let path = nested + "/e.sock"
        let socket = AgentEventSocket(socketPath: path)

        socket.start()
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFSOCK)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(nested, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)

        socket.start()
        #expect(UnixSocket.connect(to: path).map { close($0) } != nil)

        socket.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        socket.stop()
    }

    @Test("A stale socket file from an earlier process is replaced on start")
    func replacesStaleSocket() throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path("e.sock")
        var address = try #require(UnixSocket.address(for: path))
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(stale)
        #expect(UnixSocket.connect(to: path) == nil)

        let events = AgentEventSocket(socketPath: path)
        events.start()
        defer { events.stop() }
        let connection = try #require(UnixSocket.connect(to: path))
        close(connection)
    }

    @Test("A path that does not fit a socket address binds nothing, and a later start can retry")
    func overLongPath() {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let path = folder.path(String(repeating: "x", count: 120))
        let socket = AgentEventSocket(socketPath: path)
        socket.start()
        #expect(!FileManager.default.fileExists(atPath: path))
        socket.stop()
    }
}
