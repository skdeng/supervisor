import Darwin
import Foundation
import Testing

@testable import SuperVisor

@Suite("Agent bridge server")
struct AgentBridgeServerTests {
    private static let version = "1.0-test"

    private static let echoTool = BridgeTool(
        name: "echo",
        description: "Echoes its message.",
        inputSchema: .object(["type": .string("object")])
    )
    private static let otherTool = BridgeTool(
        name: "other",
        description: "Another tool.",
        inputSchema: .object(["type": .string("object")])
    )

    private static let unknownRun = "SuperVisor does not recognize this run."
    private static let refused = "SuperVisor refused this connection."
    private static let unreadable = "SuperVisor could not read the request."
    private static let toolUnavailable = "That tool is not available to this run."

    /// A running server on a socket in a scratch folder, with a handler that records its calls.
    private final class Fixture: @unchecked Sendable {
        let folder = ScratchFolder()
        let server: AgentBridgeServer
        let probe: ConcurrencyProbe
        let calls: Recorder<String>
        let peers: Recorder<pid_t>
        let roots: Recorder<pid_t>
        var path: String { folder.path("b.sock") }

        /// `trusted` replaces the check that a caller runs this app's code, and `rootTrusted`
        /// the check that a run's root is the signed agent CLI; both pass unless a test says
        /// otherwise, apart from the real caller check when `trusted` is nil.
        init(
            trusted: (@Sendable (audit_token_t) -> Bool)? = nil,
            rootTrusted: @escaping @Sendable (pid_t) -> Bool = { _ in true },
            recordedStartTime: (@Sendable (pid_t) -> ProcessStartTime?)? = nil,
            callTimeout: TimeInterval = 270,
            handlerDelay: Duration = .zero,
            handlerFails: Bool = false,
            handlerText: (@Sendable (JSONValue) -> String)? = nil
        ) throws {
            let probe = ConcurrencyProbe()
            let calls = Recorder<String>()
            let peers = Recorder<pid_t>()
            let roots = Recorder<pid_t>()
            let socketPath = folder.path("b.sock")

            let peerCheck: @Sendable (audit_token_t) -> Bool
            if let trusted {
                peerCheck = { token in
                    peers.record(PeerIdentity.processIdentifier(of: token))
                    return trusted(token)
                }
            } else {
                peerCheck = PeerIdentity.satisfiesOwnRequirement
            }

            let handler: AgentBridgeServer.Handler = { token, tool, arguments in
                probe.enter()
                defer { probe.leave() }
                calls.record("\(tool)|\(token)")
                if handlerDelay > .zero {
                    try? await Task.sleep(for: handlerDelay)
                }
                let text = handlerText?(arguments)
                    ?? "echo:" + (arguments["message"]?.stringValue ?? "")
                return handlerFails ? BridgeReply.failure(text) : BridgeReply(text: text)
            }

            self.probe = probe
            self.calls = calls
            self.peers = peers
            self.roots = roots
            server = AgentBridgeServer(
                path: socketPath,
                version: AgentBridgeServerTests.version,
                peerIsTrusted: peerCheck,
                rootIsTrusted: { pid in
                    roots.record(pid)
                    return rootTrusted(pid)
                },
                rootStartTime: recordedStartTime ?? ProcessAncestry.startTime(of:),
                callTimeout: callTimeout,
                handler: handler
            )
            do {
                try server.start()
            } catch {
                folder.remove()
                throw error
            }
        }

        func tearDown() {
            server.stop()
            folder.remove()
        }

        /// Registers a run whose root is this test process unless told otherwise.
        @discardableResult
        func register(
            root: pid_t? = getpid(),
            tools: [BridgeTool] = [AgentBridgeServerTests.echoTool]
        ) -> BridgeRun {
            let run = BridgeRun(token: AgentBridgeServer.makeToken(), rootProcess: root, tools: tools)
            server.register(run)
            return run
        }
    }

    private func call(
        _ run: BridgeRun,
        tool: String = "echo",
        message: String = "hi",
        version: String = AgentBridgeServerTests.version,
        token: String? = nil
    ) -> BridgeRequest {
        BridgeRequest(
            token: token ?? run.token,
            version: version,
            kind: .call,
            tool: tool,
            arguments: .object(["message": .string(message)])
        )
    }

    private func list(_ run: BridgeRun) -> BridgeRequest {
        BridgeRequest(token: run.token, version: Self.version, kind: .list, tool: nil, arguments: nil)
    }

    // MARK: Relay

    @Test("A run's own process gets its tool list and a relayed call, through the real code-signing check")
    func relaysListAndCall() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let run = fixture.register(tools: [Self.echoTool, Self.otherTool])

        let listed = try #require(await BridgeTestClient.exchange(list(run), at: fixture.path))
        #expect(listed == BridgeReply(tools: [Self.echoTool, Self.otherTool]))
        #expect(fixture.calls.all.isEmpty)

        let answered = try #require(
            await BridgeTestClient.exchange(call(run, message: "relay me"), at: fixture.path)
        )
        #expect(answered == BridgeReply(text: "echo:relay me"))
        #expect(fixture.calls.all == ["echo|\(run.token)"])
        #expect(fixture.server.lastPeerDepth == 0, "the caller is the run's root itself")
    }

    @Test("A handler's error reply reaches the caller with its error flag")
    func relaysErrorReply() async throws {
        let fixture = try Fixture(trusted: { _ in true }, handlerFails: true)
        defer { fixture.tearDown() }
        let run = fixture.register()

        let reply = try #require(await BridgeTestClient.exchange(call(run, message: "bad"), at: fixture.path))
        #expect(reply == .failure("echo:bad"))
    }

    @Test("A direct child of the run's root is accepted, and its depth is recorded")
    func descendantIsAccepted() async throws {
        let parent = getppid()
        try #require(parent > 1, "the test process has been orphaned")
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: parent)

        let reply = try #require(await BridgeTestClient.exchange(call(run, message: "d"), at: fixture.path))
        #expect(reply == BridgeReply(text: "echo:d"))
        #expect(fixture.server.lastPeerDepth == 1)
    }

    @Test("The trust check receives the connecting process's token, before the request is read and again after the ancestry walk")
    func trustCheckSeesThePeer() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()

        _ = await BridgeTestClient.exchange(list(run), at: fixture.path)
        #expect(fixture.peers.all == [getpid(), getpid()])
    }

    // MARK: Refusals

    @Test("An unregistered token is refused, and nothing runs")
    func unknownToken() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        fixture.register()
        let stranger = BridgeRun(token: AgentBridgeServer.makeToken(), rootProcess: getpid(), tools: [Self.echoTool])

        let reply = try #require(await BridgeTestClient.exchange(call(stranger), at: fixture.path))
        #expect(reply == .failure(Self.unknownRun))
        #expect(fixture.calls.all.isEmpty)
        #expect(fixture.peers.all.count == 1, "the peer is examined once, before its request")
    }

    @Test("A token that differs from a registered one in a single character is refused")
    func nearMissToken() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()

        var nearMiss = Array(run.token)
        nearMiss[nearMiss.count - 1] = nearMiss.last == "0" ? "1" : "0"
        var firstOff = Array(run.token)
        firstOff[0] = firstOff.first == "0" ? "1" : "0"
        for forged in [String(nearMiss), String(firstOff)] {
            let reply = try #require(await BridgeTestClient.exchange(call(run, token: forged), at: fixture.path))
            #expect(reply == .failure(Self.unknownRun))
        }
        #expect(fixture.calls.all.isEmpty)

        let genuine = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(!genuine.isError)
    }

    @Test("A retired token is refused from then on")
    func retiredToken() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()

        let before = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(!before.isError)

        fixture.server.retire(token: run.token)
        let after = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(after == .failure(Self.unknownRun))
        let listed = try #require(await BridgeTestClient.exchange(list(run), at: fixture.path))
        #expect(listed == .failure(Self.unknownRun))
        #expect(fixture.calls.all.count == 1)
    }

    @Test("A helper from another version is told to start a new run")
    func versionMismatch() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()

        let reply = try #require(
            await BridgeTestClient.exchange(call(run, version: "1.0-other"), at: fixture.path)
        )
        #expect(reply == .failure("SuperVisor was updated while this run was going. Start a new run."))
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A caller the trust check rejects is refused, and nothing runs")
    func untrustedPeer() async throws {
        let fixture = try Fixture(trusted: { _ in false })
        defer { fixture.tearDown() }
        let run = fixture.register()

        for request in [list(run), call(run)] {
            let reply = try #require(await BridgeTestClient.exchange(request, at: fixture.path))
            #expect(reply == .failure(Self.refused))
        }
        #expect(fixture.calls.all.isEmpty)
        #expect(fixture.peers.all.count == 2)
    }

    @Test("A different program that holds the right token and runs under the root is refused by the real signature check")
    func otherProgramFailsSignatureCheck() throws {
        let netcat = "/usr/bin/nc"
        try #require(FileManager.default.isExecutableFile(atPath: netcat))
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // The root is this process, and `nc` is its child: only the signature check can refuse it.
        let run = fixture.register()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: netcat)
        process.arguments = ["-U", fixture.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let request = try JSONEncoder().encode(call(run))
        #expect(BridgeWire.writeLine(request, to: input.fileHandleForWriting.fileDescriptor))
        var reader = BridgeLineReader(
            descriptor: output.fileHandleForReading.fileDescriptor,
            limit: BridgeWire.maximumReplyLine
        )
        guard case let .line(line) = reader.next(timeout: 10) else {
            Issue.record("no reply reached the other program")
            return
        }
        #expect(try JSONDecoder().decode(BridgeReply.self, from: line) == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A caller outside the run's process tree is refused even when it is trusted code")
    func callerNotUnderRoot() async throws {
        let sibling = Process()
        sibling.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sibling.arguments = ["30"]
        try sibling.run()
        defer {
            sibling.terminate()
            sibling.waitUntilExit()
        }

        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: sibling.processIdentifier)

        for request in [list(run), call(run)] {
            let reply = try #require(await BridgeTestClient.exchange(request, at: fixture.path))
            #expect(reply == .failure(Self.refused))
        }
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A tool the run was not given is refused, whichever run offers it")
    func toolNotOffered() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let narrow = fixture.register(tools: [Self.echoTool])
        let wide = fixture.register(tools: [Self.echoTool, Self.otherTool])

        let refused = try #require(
            await BridgeTestClient.exchange(call(narrow, tool: "other"), at: fixture.path)
        )
        #expect(refused == .failure(Self.toolUnavailable))
        #expect(fixture.calls.all.isEmpty)

        let allowed = try #require(
            await BridgeTestClient.exchange(call(wide, tool: "other"), at: fixture.path)
        )
        #expect(!allowed.isError)
        #expect(fixture.calls.all == ["other|\(wide.token)"])
    }

    @Test("A request that is not well formed is refused")
    func malformedRequests() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()
        let token = run.token

        let bodies: [String] = [
            "not json",
            "{}",
            #"{"token":"\#(token)","version":"\#(Self.version)","kind":"call"}"#,
            #"{"token":"\#(token)","version":"\#(Self.version)","kind":"call","tool":"Echo"}"#,
            #"{"token":"\#(token.uppercased())","version":"\#(Self.version)","kind":"list"}"#,
            #"{"token":"\#(token)","version":"","kind":"list"}"#,
            #"{"token":"\#(token)","version":"\#(Self.version)","kind":"list","tool":"echo"}"#,
            #"{"token":"\#(token)","version":"\#(Self.version)","kind":"call","tool":"echo","arguments":[1]}"#,
        ]
        for body in bodies {
            let reply = try #require(
                BridgeTestClient.exchangeRaw(Data(body.utf8), at: fixture.path),
                "\(body)"
            )
            #expect(reply == .failure(Self.unreadable), "\(body)")
        }
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A request line over 64 KiB is refused")
    func overLongRequest() throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        fixture.register()

        let junk = Data(repeating: UInt8(ascii: "a"), count: BridgeWire.maximumRequestLine + 1)
        let reply = try #require(BridgeTestClient.exchangeRaw(junk, at: fixture.path))
        #expect(reply == .failure(Self.unreadable))
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A valid request padded to the 64 KiB limit is still served")
    func requestAtTheLimit() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()

        var request = call(run, message: "")
        let base = try JSONEncoder().encode(request).count
        request = call(run, message: String(repeating: "m", count: BridgeWire.maximumRequestLine - base))
        let encoded = try JSONEncoder().encode(request)
        #expect(encoded.count == BridgeWire.maximumRequestLine)

        let reply = try #require(await BridgeTestClient.exchange(request, at: fixture.path))
        #expect(!reply.isError)
        #expect(reply.text?.count == "echo:".count + BridgeWire.maximumRequestLine - base)
    }

    // MARK: Order of the checks

    @Test("A caller that is not this app's code is refused at once, without waiting for a request")
    func untrustedPeerRefusedBeforeReading() throws {
        let fixture = try Fixture(trusted: { _ in false })
        defer { fixture.tearDown() }
        fixture.register()

        let started = Date()
        let silent = try #require(UnixSocket.connect(to: fixture.path))
        defer { close(silent) }
        // A server that read first would answer only after its request timeout of a second.
        let outcome = BridgeWire.readLine(
            from: silent,
            limit: BridgeWire.maximumReplyLine,
            timeout: 0.5
        )
        guard case let .line(line) = outcome else {
            Issue.record("no refusal arrived within half a second: \(outcome)")
            return
        }
        #expect(try JSONDecoder().decode(BridgeReply.self, from: line) == .failure(Self.refused))
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A caller that is not this app's code gets the same answer whatever it sends")
    func untrustedPeerLearnsNothing() async throws {
        let fixture = try Fixture(trusted: { _ in false })
        defer { fixture.tearDown() }
        let run = fixture.register()
        let stranger = BridgeRun(token: AgentBridgeServer.makeToken(), rootProcess: nil, tools: [])

        let requests: [(String, BridgeRequest)] = [
            ("genuine token", call(run)),
            ("unknown token", call(stranger)),
            ("other version", call(run, version: "9.9.9")),
            ("tool not offered", call(run, tool: "other")),
            ("list", list(run)),
        ]
        for (label, request) in requests {
            let reply = try #require(await BridgeTestClient.exchange(request, at: fixture.path), "\(label)")
            #expect(reply == .failure(Self.refused), "\(label)")
        }
        let garbage = try #require(BridgeTestClient.exchangeRaw(Data("not json".utf8), at: fixture.path))
        #expect(garbage == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A trusted caller that sends nothing is refused after the one-second request timeout")
    func silentTrustedPeerTimesOut() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        fixture.register()

        let silent = try #require(UnixSocket.connect(to: fixture.path))
        defer { close(silent) }
        let started = Date()
        let outcome = BridgeWire.readLine(
            from: silent,
            limit: BridgeWire.maximumReplyLine,
            timeout: 5
        )
        let elapsed = Date().timeIntervalSince(started)
        guard case let .line(line) = outcome else {
            Issue.record("no refusal arrived: \(outcome)")
            return
        }
        #expect(try JSONDecoder().decode(BridgeReply.self, from: line) == .failure(Self.unreadable))
        #expect(AgentBridgeServer.requestTimeout == 1)
        #expect(elapsed >= 0.9)
        #expect(elapsed < 2.5)
    }

    @Test("The caller is judged again after the ancestry walk, and a changed verdict refuses it")
    func peerJudgedAfterTheWalk() async throws {
        let judgements = Recorder<Int>()
        let fixture = try Fixture(trusted: { _ in
            judgements.record(0)
            return judgements.all.count == 1
        })
        defer { fixture.tearDown() }
        let run = fixture.register()

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure(Self.refused))
        #expect(judgements.all.count == 2)
        #expect(fixture.calls.all.isEmpty)
    }

    // MARK: Ancestry depth

    @Test("A caller two parents below the root is refused, and its depth is still recorded")
    func grandchildRefused() async throws {
        let parent = getppid()
        let grandparent = ProcessAncestry.parentPID(of: parent)
        try #require(parent > 1 && (grandparent ?? 0) > 1, "the test process has no grandparent")
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: grandparent)

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
        #expect(fixture.server.lastPeerDepth == 2)
        #expect(AgentBridgeServer.maximumPeerDepth == 1)
    }

    // MARK: Root process trust

    @Test("A root process that fails the trust check is never recorded, and the run is refused")
    func untrustedRootAtRegistration() async throws {
        let fixture = try Fixture(trusted: { _ in true }, rootTrusted: { _ in false })
        defer { fixture.tearDown() }
        let run = fixture.register(root: getpid())

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
        #expect(fixture.roots.all == [getpid()])
    }

    @Test("A root process set after launch that fails the trust check is ignored")
    func untrustedRootAfterLaunch() async throws {
        let fixture = try Fixture(trusted: { _ in true }, rootTrusted: { _ in false })
        defer { fixture.tearDown() }
        let run = fixture.register(root: nil)
        fixture.server.setRootProcess(getpid(), for: run.token)

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
        #expect(fixture.roots.all == [getpid()])
    }

    @Test("The trust check is given the root's pid, and a trusted root is served")
    func trustedRootIsServed() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: nil)
        fixture.server.setRootProcess(getpid(), for: run.token)

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(!reply.isError)
        #expect(fixture.roots.all == [getpid()])
    }

    @Test("A caller below a pid whose process started at another time than the recorded root is refused")
    func reusedRootPidIsRefused() async throws {
        let fixture = try Fixture(trusted: { _ in true }, recordedStartTime: { pid in
            guard let started = ProcessAncestry.startTime(of: pid) else { return nil }
            // The process now found at this pid is not the one that was recorded.
            return ProcessStartTime(seconds: started.seconds - 60, microseconds: started.microseconds)
        })
        defer { fixture.tearDown() }
        let run = fixture.register()

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A root process that has already exited is ignored")
    func exitedRootIsIgnored() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let gone = child.processIdentifier

        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: nil)
        fixture.server.setRootProcess(gone, for: run.token)

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure(Self.refused))
        #expect(fixture.calls.all.isEmpty)
    }

    // MARK: Waiting for the root process

    @Test("A root process recorded shortly after the connection starts is accepted")
    func rootProcessRecordedLate() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: nil)

        async let reply = BridgeTestClient.exchange(call(run, message: "late"), at: fixture.path)
        try await Task.sleep(for: .milliseconds(400))
        fixture.server.setRootProcess(getpid(), for: run.token)

        let answered = try #require(await reply)
        #expect(answered == BridgeReply(text: "echo:late"))
    }

    @Test("A root process that is never recorded is refused after about two seconds")
    func rootProcessNeverRecorded() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: nil)

        let started = Date()
        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        let elapsed = Date().timeIntervalSince(started)
        #expect(reply == .failure(Self.refused))
        #expect(elapsed >= 1.9)
        #expect(elapsed < 5)
        #expect(fixture.calls.all.isEmpty)
    }

    @Test("A run retired while its connection waits for the root process is refused")
    func retiredWhileWaiting() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register(root: nil)

        async let reply = BridgeTestClient.exchange(call(run), at: fixture.path)
        try await Task.sleep(for: .milliseconds(300))
        fixture.server.retire(token: run.token)
        fixture.server.setRootProcess(getpid(), for: run.token)

        let answered = try #require(await reply)
        #expect(answered.isError)
        #expect(fixture.calls.all.isEmpty)
    }

    // MARK: Concurrency

    @Test("A silent connection does not hold up another caller")
    func silentConnection() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()

        let silent = try #require(UnixSocket.connect(to: fixture.path))
        defer { close(silent) }

        let started = Date()
        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(!reply.isError)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("Two slow calls run at the same time")
    func slowCallsOverlap() async throws {
        let fixture = try Fixture(trusted: { _ in true }, handlerDelay: .milliseconds(600))
        defer { fixture.tearDown() }
        let run = fixture.register()

        let started = Date()
        async let first = BridgeTestClient.exchange(call(run, message: "one"), at: fixture.path)
        async let second = BridgeTestClient.exchange(call(run, message: "two"), at: fixture.path)
        let replies = await [first, second]

        #expect(replies.compactMap { $0?.text }.sorted() == ["echo:one", "echo:two"])
        #expect(fixture.probe.peakConcurrency == 2)
        #expect(Date().timeIntervalSince(started) < 1.1)
    }

    @Test("A ninth simultaneous connection is turned away while eight are being served")
    func connectionCap() async throws {
        let fixture = try Fixture(trusted: { _ in true }, handlerDelay: .seconds(2))
        defer { fixture.tearDown() }
        let run = fixture.register()

        var busy = [Task<BridgeReply?, Never>]()
        for index in 0..<AgentBridgeServer.maximumConcurrentConnections {
            busy.append(Task {
                await BridgeTestClient.exchange(call(run, message: "\(index)"), at: fixture.path)
            })
        }
        let deadline = Date().addingTimeInterval(10)
        while fixture.probe.startedCount < AgentBridgeServer.maximumConcurrentConnections,
              Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.probe.startedCount == AgentBridgeServer.maximumConcurrentConnections)

        let ninth = try #require(await BridgeTestClient.exchange(list(run), at: fixture.path))
        #expect(ninth == .busy("SuperVisor is busy. Try again."))
        #expect(ninth.isBusy == true)

        var served = 0
        for task in busy {
            if let reply = await task.value, !reply.isError { served += 1 }
        }
        #expect(served == AgentBridgeServer.maximumConcurrentConnections)

        let afterwards = try #require(await BridgeTestClient.exchange(list(run), at: fixture.path))
        #expect(!afterwards.isError)
    }

    // MARK: Results

    @Test("A call that outlasts the call timeout is answered with a timeout, not left hanging")
    func callTimeout() async throws {
        let fixture = try Fixture(
            trusted: { _ in true },
            callTimeout: 0.4,
            handlerDelay: .seconds(30)
        )
        defer { fixture.tearDown() }
        let run = fixture.register()

        let started = Date()
        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure("The tool did not finish in time."))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A result too large for a reply line is replaced by an error the helper can read")
    func oversizedResult() async throws {
        let fixture = try Fixture(trusted: { _ in true }, handlerText: { _ in
            String(repeating: "x", count: BridgeWire.maximumReplyLine + 1)
        })
        defer { fixture.tearDown() }
        let run = fixture.register()

        let reply = try #require(await BridgeTestClient.exchange(call(run), at: fixture.path))
        #expect(reply == .failure("The result was too large."))
    }

    // MARK: Lifecycle

    @Test("Tokens are 32 lowercase hex characters and never repeat")
    func tokens() {
        let tokens = (0..<200).map { _ in AgentBridgeServer.makeToken() }
        #expect(Set(tokens).count == tokens.count)
        for token in tokens {
            #expect(token.range(of: #"\A[0-9a-f]{32}\z"#, options: .regularExpression) != nil, "\(token)")
        }
    }

    @Test("Stopping removes the socket and forgets every run")
    func stopForgetsRuns() async throws {
        let fixture = try Fixture(trusted: { _ in true })
        defer { fixture.tearDown() }
        let run = fixture.register()
        let path = fixture.path

        let before = try #require(await BridgeTestClient.exchange(call(run), at: path))
        #expect(!before.isError)

        fixture.server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await BridgeTestClient.exchange(call(run), at: path) == nil)

        try fixture.server.start()
        let after = try #require(await BridgeTestClient.exchange(call(run), at: path))
        #expect(after == .failure(Self.unknownRun))
    }

    @Test("A path that does not fit a socket address fails to start")
    func startFailsForLongPath() {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let server = AgentBridgeServer(
            path: folder.path(String(repeating: "s", count: 120)),
            version: Self.version
        ) { _, _, _ in BridgeReply() }
        #expect(throws: UnixSocketListener.Failure.pathTooLong) {
            try server.start()
        }
    }
}
