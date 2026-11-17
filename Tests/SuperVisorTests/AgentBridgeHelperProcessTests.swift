import Darwin
import Foundation
import Testing

@testable import SuperVisor

/// Runs the built `SuperVisor` executable as the bridge helper, against a real server in this
/// process, and drives it over stdin and stdout the way an agent CLI would.
@Suite("Agent bridge helper process")
struct AgentBridgeHelperProcessTests {
    private static let echoTool = BridgeTool(
        name: "echo",
        description: "Echoes its message.",
        inputSchema: .object(["type": .string("object")])
    )

    /// The helper running with its three pipes.
    private final class Helper {
        let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private var reader: BridgeLineReader

        /// The server in these tests is this test runner, which is not this app's code, so the
        /// helper is told to trust any server unless `verifyingServer` asks for the real check.
        init(
            executable: URL,
            environment: [String: String],
            verifyingServer: Bool = false
        ) throws {
            var environment = environment.merging(BuiltExecutable.frameworkEnvironment) { current, _ in current }
            if !verifyingServer {
                environment[AgentBridgeHelper.trustAnyServerVariable] = "1"
            }
            process.executableURL = executable
            process.arguments = [AgentBridgeHelper.flag]
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            reader = BridgeLineReader(
                descriptor: output.fileHandleForReading.fileDescriptor,
                limit: 4 * 1024 * 1024
            )
            try process.run()
        }

        func send(_ line: String) {
            _ = BridgeWire.writeLine(Data(line.utf8), to: input.fileHandleForWriting.fileDescriptor)
        }

        func sendRaw(_ data: Data) {
            _ = BridgeWire.writeLine(data, to: input.fileHandleForWriting.fileDescriptor)
        }

        /// The next stdout line decoded as JSON; nil when it is not one line of JSON in time.
        func receive(timeout: TimeInterval = 20) -> JSONValue? {
            guard case let .line(data) = reader.next(timeout: timeout) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }

        /// Closes stdin and reports whether the helper exited by itself, within ten seconds,
        /// with status 0 and left no further output behind.
        func finish() -> (exitedCleanly: Bool, strayOutput: Bool) {
            try? input.fileHandleForWriting.close()
            guard process.waitForExit(timeout: 10) else {
                process.stopAndReap()
                return (false, false)
            }
            let stray = reader.next(timeout: 5) != .closed
            return (
                process.terminationReason == .exit && process.terminationStatus == 0,
                stray
            )
        }

        func terminate() {
            process.stopAndReap()
        }
    }

    // MARK: Over stdio

    @Test("The helper serves initialize, tools/list, and tools/call over stdio and writes nothing else to stdout",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func relaysOverStdio() async throws {
        let executable = try #require(BuiltExecutable.url)
        let folder = ScratchFolder()
        defer { folder.remove() }

        let calls = Recorder<String>()
        let server = AgentBridgeServer(
            path: folder.path("b.sock"),
            version: BuiltExecutable.version,
            peerIsTrusted: { _ in true },
            rootIsTrusted: { _ in true }
        ) { token, tool, arguments in
            calls.record("\(tool)|\(token)")
            return BridgeReply(text: "echo:" + (arguments["message"]?.stringValue ?? ""))
        }
        try server.start()
        defer { server.stop() }
        let run = BridgeRun(
            token: AgentBridgeServer.makeToken(),
            rootProcess: getpid(),
            tools: [Self.echoTool]
        )
        server.register(run)

        let helper = try Helper(executable: executable, environment: [
            AgentBridgeHelper.tokenVariable: run.token,
            AgentBridgeHelper.socketVariable: folder.path("b.sock"),
        ])
        defer { helper.terminate() }

        helper.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let initialized = try #require(helper.receive())
        #expect(initialized["id"] == .number(1))
        #expect(initialized["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(initialized["result"]?["serverInfo"]?["name"] == .string("supervisor"))

        helper.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)

        helper.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listed = try #require(helper.receive())
        #expect(listed["id"] == .number(2))
        #expect(listed["result"]?["tools"] == .array([
            .object([
                "name": .string("echo"),
                "description": .string("Echoes its message."),
                "inputSchema": .object(["type": .string("object")]),
            ]),
        ]))

        helper.send(#"{"jsonrpc":"2.0","id":"call-3","method":"tools/call","params":{"name":"echo","arguments":{"message":"over the socket"}}}"#)
        let called = try #require(helper.receive())
        #expect(called["id"] == .string("call-3"))
        #expect(called["result"] == .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("echo:over the socket")]),
            ]),
            "isError": .bool(false),
        ]))
        #expect(calls.all == ["echo|\(run.token)"])

        helper.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"other","arguments":{}}}"#)
        let refused = try #require(helper.receive())
        #expect(refused["id"] == .number(4))
        #expect(refused["result"] == .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("That tool is not available to this run."),
                ]),
            ]),
            "isError": .bool(true),
        ]))
        #expect(calls.all.count == 1)

        helper.send(#"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)
        #expect(try #require(helper.receive())["id"] == .number(5))

        let outcome = helper.finish()
        #expect(outcome.exitedCleanly)
        #expect(!outcome.strayOutput)
    }

    @Test("The helper keeps serving after an over-long request line and refuses nothing else",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func survivesOversizedLine() throws {
        let executable = try #require(BuiltExecutable.url)
        let helper = try Helper(executable: executable, environment: [
            AgentBridgeHelper.tokenVariable: AgentBridgeServer.makeToken(),
            AgentBridgeHelper.socketVariable: "/nonexistent/b.sock",
        ])
        defer { helper.terminate() }

        helper.sendRaw(Data(repeating: UInt8(ascii: "x"), count: AgentBridgeProtocol.maximumRequestBytes + 4_096))
        let tooLarge = try #require(helper.receive())
        #expect(tooLarge["error"]?["code"] == .number(-32600))

        helper.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        #expect(try #require(helper.receive())["id"] == .number(1))

        helper.send("not json")
        #expect(try #require(helper.receive())["error"]?["code"] == .number(-32700))

        let outcome = helper.finish()
        #expect(outcome.exitedCleanly)
        #expect(!outcome.strayOutput)
    }

    @Test("With no app listening, a call comes back as a tool error that names no path and no token",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func unreachableApp() throws {
        let executable = try #require(BuiltExecutable.url)
        let token = AgentBridgeServer.makeToken()
        let helper = try Helper(executable: executable, environment: [
            AgentBridgeHelper.tokenVariable: token,
            AgentBridgeHelper.socketVariable: "/nonexistent-folder/b.sock",
        ])
        defer { helper.terminate() }

        helper.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        let called = try #require(helper.receive())
        #expect(called["result"] == .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("SuperVisor is not reachable.")]),
            ]),
            "isError": .bool(true),
        ]))

        helper.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let listed = try #require(helper.receive())
        #expect(listed["error"]?["code"] == .number(-32000))
        #expect(listed["error"]?["message"] == .string("SuperVisor is not reachable."))

        let outcome = helper.finish()
        #expect(outcome.exitedCleanly)
        #expect(!outcome.strayOutput)
    }

    @Test("Without a token in its environment the helper offers no tools, refuses a call, and never contacts the app",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func missingToken() throws {
        let executable = try #require(BuiltExecutable.url)
        let folder = ScratchFolder()
        defer { folder.remove() }
        let connections = Recorder<Bool>()
        let listener = UnixSocketListener(
            path: folder.path("b.sock"),
            queue: DispatchQueue(label: "helper-missing-token")
        ) { connection in
            connections.record(true)
            close(connection)
        }
        try listener.start()
        defer { listener.stop() }

        let helper = try Helper(executable: executable, environment: [
            AgentBridgeHelper.socketVariable: folder.path("b.sock"),
        ])
        defer { helper.terminate() }

        helper.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let listed = try #require(helper.receive())
        #expect(listed["id"] == .number(1))
        #expect(listed["result"] == .object(["tools": .array([])]))
        #expect(listed["error"] == nil)

        helper.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo"}}"#)
        let called = try #require(helper.receive())
        #expect(called["result"] == .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("That tool is not available to this run."),
                ]),
            ]),
            "isError": .bool(true),
        ]))
        #expect(connections.all.isEmpty)
        #expect(helper.finish().exitedCleanly)
        #expect(connections.all.isEmpty)
    }

    @Test("The helper holds its first initialize for the settle time, once, and answers everything else at once",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func holdsFirstInitialize() throws {
        let executable = try #require(BuiltExecutable.url)
        let helper = try Helper(executable: executable, environment: [
            AgentBridgeHelper.settleVariable: "1500",
        ])
        defer { helper.terminate() }
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#

        func seconds(answering line: String) throws -> TimeInterval {
            let started = Date()
            helper.send(line)
            _ = try #require(helper.receive())
            return Date().timeIntervalSince(started)
        }

        #expect(try seconds(answering: #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#) < 1.0)
        let first = try seconds(answering: initialize)
        #expect(first >= 1.4)
        #expect(first < 6)
        #expect(try seconds(answering: initialize) < 1.0)
        #expect(try seconds(answering: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#) < 1.0)
        #expect(helper.finish().exitedCleanly)
    }

    @Test("A settle value that is not a whole number of milliseconds from 0 to 15000 is no wait")
    func settleValues() {
        func settle(_ value: String?) -> Int {
            AgentBridgeHelper.settleMilliseconds(
                environment: value.map { [AgentBridgeHelper.settleVariable: $0] } ?? [:]
            )
        }

        #expect(settle("6000") == 6_000)
        #expect(settle("0") == 0)
        #expect(settle("1") == 1)
        #expect(settle("15000") == 15_000)
        #expect(settle("007") == 7)
        for refused in [
            nil, "", " ", "15001", "99999", "100000", "-1", "-6000", "+6000", " 6000", "6000 ",
            "6000.5", "6e3", "abc", "6 000", "٦٠٠٠", "6000\n",
        ] {
            #expect(settle(refused) == 0, "\(refused ?? "nil")")
        }
    }

    @Test("The helper does not send its token to a server that is not this app's code",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func refusesUnverifiedServer() throws {
        let executable = try #require(BuiltExecutable.url)
        let folder = ScratchFolder()
        defer { folder.remove() }
        // This test runner stands in for an impostor: a different program from the helper.
        let received = Recorder<String>()
        let listener = UnixSocketListener(
            path: folder.path("b.sock"),
            queue: DispatchQueue(label: "helper-impostor")
        ) { connection in
            defer { close(connection) }
            switch BridgeWire.readLine(from: connection, limit: 4_096, timeout: 1.5) {
            case let .line(data): received.record(String(decoding: data, as: UTF8.self))
            case .closed: received.record("<closed without data>")
            case .tooLong, .timedOut, .failed: received.record("<no line>")
            }
        }
        try listener.start()
        defer { listener.stop() }

        let token = AgentBridgeServer.makeToken()
        let helper = try Helper(
            executable: executable,
            environment: [
                AgentBridgeHelper.tokenVariable: token,
                AgentBridgeHelper.socketVariable: folder.path("b.sock"),
            ],
            verifyingServer: true
        )
        defer { helper.terminate() }

        helper.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{}}}"#)
        let called = try #require(helper.receive())
        #expect(called["result"] == .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("SuperVisor could not be verified.")]),
            ]),
            "isError": .bool(true),
        ]))

        let deadline = Date().addingTimeInterval(5)
        while received.all.isEmpty, Date() < deadline { usleep(10_000) }
        #expect(received.all == ["<closed without data>"])
        #expect(!received.all.joined().contains(token))
        #expect(helper.finish().exitedCleanly)
    }

    // MARK: In process

    @Test("The helper's server check passes for this app's own code and fails for another program")
    func serverVerification() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        // The far end of a socket pair is this process, which satisfies its own requirement.
        #expect(AgentBridgeHelper.isTrustedServer(pair.first, environment: [:]))
        #expect(!AgentBridgeHelper.isTrustedServer(-1, environment: [:]))

        let netcat = "/usr/bin/nc"
        try #require(FileManager.default.isExecutableFile(atPath: netcat))
        let folder = ScratchFolder()
        defer { folder.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: netcat)
        process.arguments = ["-l", "-U", folder.path("n.sock")]
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.stopAndReap() }

        var other: Int32?
        let deadline = Date().addingTimeInterval(5)
        while other == nil, Date() < deadline {
            other = UnixSocket.connect(to: folder.path("n.sock"))
            if other == nil { usleep(20_000) }
        }
        let connection = try #require(other)
        defer { close(connection) }
        #expect(!AgentBridgeHelper.isTrustedServer(connection, environment: [:]))
        #expect(!AgentBridgeHelper.isTrustedServer(connection, environment: [
            "SUPERVISOR_BRIDGE_TRUST_ANY_SERVER": "yes",
        ]))
        #if DEBUG
        #expect(AgentBridgeHelper.isTrustedServer(connection, environment: [
            AgentBridgeHelper.trustAnyServerVariable: "1",
        ]))
        #endif
    }

    @Test("A busy answer is retried up to three times with a growing pause, and nothing else is")
    func busyRetries() {
        let pauses = Recorder<TimeInterval>()
        let attempts = Recorder<Int>()
        var script: [BridgeReply] = [.busy("busy"), .busy("busy"), BridgeReply(text: "done")]
        let reply = AgentBridgeHelper.retryingWhenBusy(
            pause: { pauses.record($0) },
            attempt: {
                attempts.record(attempts.all.count)
                return script.removeFirst()
            }
        )
        #expect(reply == BridgeReply(text: "done"))
        #expect(attempts.all.count == 3)
        #expect(pauses.all == [0.1, 0.2])

        let stubbornPauses = Recorder<TimeInterval>()
        let stubbornAttempts = Recorder<Int>()
        let stubborn = AgentBridgeHelper.retryingWhenBusy(
            pause: { stubbornPauses.record($0) },
            attempt: {
                stubbornAttempts.record(0)
                return .busy("busy")
            }
        )
        #expect(stubborn == .busy("busy"))
        #expect(stubbornAttempts.all.count == 4, "one attempt and three retries")
        #expect(stubbornPauses.all == [0.1, 0.2, 0.4])

        let refusalAttempts = Recorder<Int>()
        let refusal = AgentBridgeHelper.retryingWhenBusy(
            pause: { _ in Issue.record("a refusal is not retried") },
            attempt: {
                refusalAttempts.record(0)
                return .failure("SuperVisor refused this connection.")
            }
        )
        #expect(refusal == .failure("SuperVisor refused this connection."))
        #expect(refusalAttempts.all.count == 1)
    }

    @Test("The flag is recognized after the program name and nowhere before it")
    func flagDetection() {
        #expect(AgentBridgeHelper.isRequested(in: ["/path/SuperVisor", "--agent-bridge"]))
        #expect(AgentBridgeHelper.isRequested(in: ["SuperVisor", "--other", "--agent-bridge"]))
        #expect(!AgentBridgeHelper.isRequested(in: ["SuperVisor"]))
        #expect(!AgentBridgeHelper.isRequested(in: ["--agent-bridge"]))
        #expect(!AgentBridgeHelper.isRequested(in: ["SuperVisor", "--agent-bridge-x"]))
        #expect(!AgentBridgeHelper.isRequested(in: []))
    }

    @Test("The socket path is under Application Support unless the environment names another")
    func socketPath() {
        let standard = NSHomeDirectory() + "/Library/Application Support/SuperVisor/agent-bridge.sock"
        #expect(AgentBridgeHelper.defaultSocketPath == standard)
        #expect(AgentBridgeHelper.socketPath(environment: [:]) == standard)
        #expect(AgentBridgeHelper.socketPath(environment: ["HOME": "/elsewhere"]) == standard)
        #expect(AgentBridgeHelper.socketPath(environment: [
            AgentBridgeHelper.socketVariable: "/tmp/other.sock",
        ]) == "/tmp/other.sock")
        #expect(AgentBridgeHelper.socketPath(environment: [
            AgentBridgeHelper.socketVariable: "",
        ]) == standard)
    }
}
