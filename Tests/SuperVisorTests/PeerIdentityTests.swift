import Darwin
import Foundation
import Testing

@testable import SuperVisor

@Suite("Peer identity")
struct PeerIdentityTests {
    /// A child process that stays alive until `terminate()`.
    private final class SleepingChild {
        private let process = Process()

        var processIdentifier: pid_t { process.processIdentifier }

        init() throws {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
        }

        func terminate() {
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// The audit token of whoever is on the far end of a connection to a listener in this
    /// process, for a client that `connect` starts.
    private func peerToken(
        connecting connect: (_ socketPath: String) throws -> () -> Void
    ) throws -> (token: audit_token_t, cleanUp: () -> Void)? {
        let folder = ScratchFolder()
        let path = folder.path("p.sock")
        let captured = Recorder<audit_token_t>()
        let listener = UnixSocketListener(
            path: path,
            queue: DispatchQueue(label: "peer-identity-tests")
        ) { connection in
            if let token = PeerIdentity.auditToken(of: connection) { captured.record(token) }
            close(connection)
        }
        try listener.start()
        let stopClient = try connect(path)
        let cleanUp = {
            stopClient()
            listener.stop()
            folder.remove()
        }

        let deadline = Date().addingTimeInterval(10)
        while captured.all.isEmpty, Date() < deadline { usleep(10_000) }
        guard let token = captured.all.first else {
            cleanUp()
            return nil
        }
        return (token, cleanUp)
    }

    // MARK: Audit tokens

    @Test("Across a socket pair, the peer's token names this process")
    func tokenOfSocketPairPeer() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }

        let token = try #require(PeerIdentity.auditToken(of: pair.first))
        #expect(PeerIdentity.processIdentifier(of: token) == getpid())
    }

    @Test("A descriptor that is not a socket has no peer token")
    func tokenOfNonSocket() {
        #expect(PeerIdentity.auditToken(of: -1) == nil)
        #expect(PeerIdentity.auditToken(of: STDIN_FILENO) == nil)
    }

    @Test("The pid read from a token is the connecting process's, whichever process that is")
    func tokenNamesAnotherProcess() throws {
        let netcat = "/usr/bin/nc"
        try #require(FileManager.default.isExecutableFile(atPath: netcat))
        let process = Process()
        let hold = Pipe()

        let peer = try #require(try peerToken { path in
            process.executableURL = URL(fileURLWithPath: netcat)
            process.arguments = ["-U", path]
            process.standardInput = hold
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return {
                process.terminate()
                process.waitUntilExit()
            }
        })
        defer { peer.cleanUp() }

        #expect(PeerIdentity.processIdentifier(of: peer.token) == process.processIdentifier)
        #expect(PeerIdentity.processIdentifier(of: peer.token) != getpid())
    }

    // MARK: Code requirement

    @Test("The test process satisfies its own designated requirement")
    func ownProcessSatisfiesRequirement() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        let token = try #require(PeerIdentity.auditToken(of: pair.first))
        #expect(PeerIdentity.satisfiesOwnRequirement(token))
    }

    @Test("A different program does not satisfy it, though it runs as the same user")
    func otherProgramFailsRequirement() throws {
        let netcat = "/usr/bin/nc"
        try #require(FileManager.default.isExecutableFile(atPath: netcat))
        let process = Process()
        let hold = Pipe()

        let peer = try #require(try peerToken { path in
            process.executableURL = URL(fileURLWithPath: netcat)
            process.arguments = ["-U", path]
            process.standardInput = hold
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            return {
                process.terminate()
                process.waitUntilExit()
            }
        })
        defer { peer.cleanUp() }

        #expect(!PeerIdentity.satisfiesOwnRequirement(peer.token))
    }

    @Test("A token naming no running process does not satisfy the requirement")
    func staleTokenFailsRequirement() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        var token = try #require(PeerIdentity.auditToken(of: pair.first))
        // Same pid, wrong process-version counter: a recycled pid must not pass.
        token.val.7 &+= 1
        #expect(!PeerIdentity.satisfiesOwnRequirement(token))

        #expect(!PeerIdentity.satisfiesOwnRequirement(audit_token_t()))
    }

    // MARK: Ancestry

    @Test("A process descends from itself and from its parent")
    func selfAndParent() throws {
        let me = getpid()
        #expect(PeerIdentity.descends(me, from: me))

        let parent = getppid()
        try #require(parent > 1, "the test process has been orphaned")
        #expect(PeerIdentity.descends(me, from: parent))
        #expect(!PeerIdentity.descends(parent, from: me))
    }

    @Test("The depth limit counts parents")
    func depthLimit() throws {
        let parent = getppid()
        try #require(parent > 1, "the test process has been orphaned")
        #expect(PeerIdentity.descends(getpid(), from: getpid(), maximumDepth: 0))
        #expect(!PeerIdentity.descends(getpid(), from: parent, maximumDepth: 0))
        #expect(PeerIdentity.descends(getpid(), from: parent, maximumDepth: 1))
    }

    @Test("A child descends from this process, and this process does not descend from a sibling child")
    func children() throws {
        let first = try SleepingChild()
        defer { first.terminate() }
        let second = try SleepingChild()
        defer { second.terminate() }

        #expect(PeerIdentity.descends(first.processIdentifier, from: getpid()))
        #expect(!PeerIdentity.descends(getpid(), from: first.processIdentifier))
        #expect(!PeerIdentity.descends(second.processIdentifier, from: first.processIdentifier))
        #expect(!PeerIdentity.descends(first.processIdentifier, from: second.processIdentifier))
    }

    @Test("An exited process has no ancestry")
    func exitedProcess() throws {
        let child = try SleepingChild()
        let pid = child.processIdentifier
        child.terminate()
        #expect(!PeerIdentity.descends(pid, from: getpid()))
    }

    @Test("Pids that cannot name a process or a root never match")
    func invalidPids() {
        let me = getpid()
        for invalid: pid_t in [-1, 0, .min, .max] {
            #expect(!PeerIdentity.descends(invalid, from: me), "process \(invalid)")
            #expect(!PeerIdentity.descends(me, from: invalid), "ancestor \(invalid)")
        }
        // Every process descends from launchd, which would make it a root that admits everyone.
        #expect(!PeerIdentity.descends(me, from: 1))
        #expect(!PeerIdentity.descends(1, from: 1))
    }

    // MARK: Depth and start time

    @Test("Depth counts the parents between a process and an ancestor")
    func depthCountsParents() throws {
        let me = getpid()
        #expect(PeerIdentity.depth(of: me, below: me) == 0)

        let parent = getppid()
        try #require(parent > 1, "the test process has been orphaned")
        #expect(PeerIdentity.depth(of: me, below: parent) == 1)
        #expect(PeerIdentity.depth(of: parent, below: me) == nil)

        let child = try SleepingChild()
        defer { child.terminate() }
        #expect(PeerIdentity.depth(of: child.processIdentifier, below: me) == 1)
        #expect(PeerIdentity.depth(of: child.processIdentifier, below: parent) == 2)
        #expect(PeerIdentity.depth(of: child.processIdentifier, below: parent, maximumDepth: 1) == nil)
        #expect(PeerIdentity.depth(of: child.processIdentifier, below: parent, maximumDepth: 2) == 2)
    }

    @Test("A process's start time is stable, in the past, and absent once it has exited")
    func startTime() throws {
        let me = try #require(ProcessAncestry.startTime(of: getpid()))
        #expect(ProcessAncestry.startTime(of: getpid()) == me)
        #expect(Double(me.seconds) < Date().timeIntervalSince1970)
        #expect(Double(me.seconds) > Date().timeIntervalSince1970 - 10 * 365 * 24 * 3600)

        let child = try SleepingChild()
        let started = try #require(ProcessAncestry.startTime(of: child.processIdentifier))
        #expect(started != me)
        #expect((started.seconds, started.microseconds) >= (me.seconds, me.microseconds))
        let pid = child.processIdentifier
        child.terminate()
        #expect(ProcessAncestry.startTime(of: pid) == nil)
        #expect(ProcessAncestry.startTime(of: -1) == nil)
    }

    @Test("A root whose start time differs from the one recorded is not an ancestor, whatever its pid")
    func reusedPidIsNotTheRoot() throws {
        let me = getpid()
        let recorded = try #require(ProcessAncestry.startTime(of: me))
        #expect(PeerIdentity.depth(of: me, below: me, ancestorStarted: recorded) == 0)
        #expect(PeerIdentity.descends(me, from: me, ancestorStarted: recorded))

        let other = ProcessStartTime(seconds: recorded.seconds + 1, microseconds: recorded.microseconds)
        #expect(PeerIdentity.depth(of: me, below: me, ancestorStarted: other) == nil)
        #expect(!PeerIdentity.descends(me, from: me, ancestorStarted: other))

        let parent = getppid()
        try #require(parent > 1, "the test process has been orphaned")
        let parentStarted = try #require(ProcessAncestry.startTime(of: parent))
        #expect(PeerIdentity.depth(of: me, below: parent, ancestorStarted: parentStarted) == 1)
        #expect(PeerIdentity.depth(of: me, below: parent, ancestorStarted: recorded) == nil)
    }
}
