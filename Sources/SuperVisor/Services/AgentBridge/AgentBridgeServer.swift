import Darwin
import Foundation
import Security

/// What a run may ask for, decided by whoever started the run.
struct BridgeRun: Sendable {
    /// The run's credential, from `AgentBridgeServer.makeToken()`.
    let token: String
    /// The agent process the app started for this run, set once it has launched. A caller must
    /// descend from it. The server accepts a pid only for a process that satisfies its trust
    /// check, and records when that process started.
    var rootProcess: pid_t?
    let tools: [BridgeTool]
    var rootStartTime: ProcessStartTime?
}

/// The app's end of the bridge: accepts the helper's connections, verifies who is calling, and
/// relays tool requests to a handler.
///
/// A caller is examined before it is read: its process must run this app's own code. Only then
/// is its request read, and it is served only when the request is well formed, its token names a
/// registered run, the helper's version matches the app's, and the caller is a child of the
/// process the app started for that run (`maximumPeerDepth` parents below it). The caller's
/// signature is checked again after the ancestry walk, which proves the walked pid is still the
/// process that was verified. Every refusal is a fixed sentence; the log records the reason's
/// name alone.
final class AgentBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ token: String, _ tool: String, _ arguments: JSONValue) async
        -> BridgeReply

    static let maximumConcurrentConnections = 8
    static let requestTimeout: TimeInterval = 1
    static let rootProcessWait: TimeInterval = 2
    /// How many parents may separate a caller from the run's root process: 1 admits the root's
    /// direct children.
    static let maximumPeerDepth = 1
    /// How far above a caller the ancestry walk looks when measuring its depth for
    /// `lastPeerDepth`, whether or not the caller is within `maximumPeerDepth`.
    static let depthMeasurementLimit = 16
    static let updatedWhileRunningSentence =
        "SuperVisor was updated while this run was going. Start a new run."

    private enum Refusal: String, Sendable {
        case busy
        case requestUnreadable
        /// The caller closed the connection without sending a request. A helper does this when
        /// it cannot verify the app, as when the bundle it was started from is not the code the
        /// app is running.
        case callerLeft
        case requestTooLong
        case requestMalformed
        case runUnknown
        case versionMismatch
        case peerUnidentified
        case peerUntrusted
        case peerChanged
        case rootUntrusted
        case rootProcessUnset
        case peerNotDescendant
        case toolNotOffered
        case callTimedOut
        case resultTooLarge

        var sentence: String {
            switch self {
            case .busy: "SuperVisor is busy. Try again."
            case .requestUnreadable, .callerLeft, .requestTooLong, .requestMalformed:
                "SuperVisor could not read the request."
            case .runUnknown: "SuperVisor does not recognize this run."
            case .versionMismatch: AgentBridgeServer.updatedWhileRunningSentence
            case .peerUnidentified, .peerUntrusted, .peerChanged, .rootUntrusted,
                 .rootProcessUnset, .peerNotDescendant:
                "SuperVisor refused this connection."
            case .toolNotOffered: "That tool is not available to this run."
            case .callTimedOut: "The tool did not finish in time."
            case .resultTooLarge: "The result was too large."
            }
        }
    }

    private let path: String
    private let version: String
    private let peerIsTrusted: @Sendable (audit_token_t) -> Bool
    private let rootIsTrusted: @Sendable (pid_t) -> Bool
    private let rootStartTime: @Sendable (pid_t) -> ProcessStartTime?
    private let callTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "com.supervisor.agent-bridge.accept")
    private let connectionQueue = DispatchQueue(
        label: "com.supervisor.agent-bridge.connections",
        attributes: .concurrent
    )

    private let lock = NSLock()
    private var listener: UnixSocketListener?
    private var runs: [String: BridgeRun] = [:]
    private var activeConnections = 0
    private var lastRefusalError: [Refusal: Date] = [:]
    private var measuredPeerDepth: Int?

    /// How many parents separated the most recent caller whose ancestry reached its run's root
    /// from that root, whether or not the caller was admitted. Nil until one has.
    var lastPeerDepth: Int? { lock.withLock { measuredPeerDepth } }

    /// `peerIsTrusted` judges a caller's process and `rootIsTrusted` a run's root process;
    /// `rootStartTime` reads when a root process started, which is recorded and compared with
    /// the process found at that pid when a caller's ancestry is walked.
    /// `callTimeout` bounds one tool call; the helper gives up on a reply after five minutes,
    /// so a longer bound would answer no one. `requestTimeout` bounds the wait for a caller's
    /// request line.
    init(
        path: String,
        version: String,
        peerIsTrusted: @escaping @Sendable (audit_token_t) -> Bool =
            PeerIdentity.satisfiesOwnRequirement,
        rootIsTrusted: @escaping @Sendable (pid_t) -> Bool =
            AgentExecutableTrust.isTrusted(process:),
        rootStartTime: @escaping @Sendable (pid_t) -> ProcessStartTime? =
            ProcessAncestry.startTime(of:),
        callTimeout: TimeInterval = 270,
        requestTimeout: TimeInterval = AgentBridgeServer.requestTimeout,
        handler: @escaping Handler
    ) {
        self.path = path
        self.version = version
        self.peerIsTrusted = peerIsTrusted
        self.rootIsTrusted = rootIsTrusted
        self.rootStartTime = rootStartTime
        self.callTimeout = callTimeout
        self.requestTimeout = requestTimeout
        self.handler = handler
    }

    /// A run credential: 16 random bytes as 32 lowercase hex characters.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() throws {
        let alreadyStarted = lock.withLock { listener != nil }
        guard !alreadyStarted else { return }

        let listener = UnixSocketListener(path: path, queue: acceptQueue) { [weak self] connection in
            guard let self else {
                close(connection)
                return
            }
            self.accept(connection)
        }
        try listener.start()
        lock.withLock { self.listener = listener }
        AppLog.notice(.agentDispatch, "agent bridge listening")
    }

    func stop() {
        let stopped = lock.withLock {
            let current = listener
            listener = nil
            runs.removeAll()
            return current
        }
        guard let stopped else { return }
        stopped.stop()
        AppLog.notice(.agentDispatch, "agent bridge stopped")
    }

    /// Registers a run. A root process it already names is held to the same trust check as one
    /// set later.
    func register(_ run: BridgeRun) {
        var run = run
        run.rootStartTime = nil
        if let root = run.rootProcess {
            if let started = trustedStartTime(of: root) {
                run.rootStartTime = started
            } else {
                run.rootProcess = nil
            }
        }
        lock.withLock { runs[run.token] = run }
    }

    /// Records the process the app started for the run. A pid that does not satisfy the trust
    /// check, or that no longer exists, is ignored, and the run then has no root.
    func setRootProcess(_ pid: pid_t, for token: String) {
        guard let started = trustedStartTime(of: pid) else { return }
        lock.withLock {
            runs[token]?.rootProcess = pid
            runs[token]?.rootStartTime = started
        }
    }

    func retire(token: String) {
        lock.withLock { _ = runs.removeValue(forKey: token) }
    }

    private func trustedStartTime(of pid: pid_t) -> ProcessStartTime? {
        guard rootIsTrusted(pid), let started = rootStartTime(pid) else {
            log(.rootUntrusted)
            return nil
        }
        return started
    }

    // MARK: Connections

    private func accept(_ connection: Int32) {
        let admitted = lock.withLock {
            guard activeConnections < Self.maximumConcurrentConnections else { return false }
            activeConnections += 1
            return true
        }
        guard admitted else {
            UnixSocket.setSendTimeout(5, on: connection)
            refuse(connection, .busy)
            close(connection)
            return
        }

        connectionQueue.async { [self] in
            defer {
                close(connection)
                lock.withLock { activeConnections -= 1 }
            }
            UnixSocket.setSendTimeout(10, on: connection)
            serve(connection)
        }
    }

    private func serve(_ connection: Int32) {
        // The caller is judged before anything it sends is read, so a program that is not this
        // app's own code learns nothing about tokens, versions, or runs.
        guard let peer = PeerIdentity.auditToken(of: connection) else {
            return refuse(connection, .peerUnidentified)
        }
        guard peerIsTrusted(peer) else { return refuse(connection, .peerUntrusted) }

        let line: Data
        switch BridgeWire.readLine(
            from: connection,
            limit: BridgeWire.maximumRequestLine,
            timeout: requestTimeout
        ) {
        case let .line(data):
            line = data
        case .tooLong:
            return refuse(connection, .requestTooLong)
        case .timedOut:
            return refuse(connection, .requestUnreadable)
        case .closed, .failed:
            return log(.callerLeft)
        }

        guard let request = try? JSONDecoder().decode(BridgeRequest.self, from: line),
              request.isWellFormed,
              request.arguments == nil || request.arguments?.objectValue != nil
        else { return refuse(connection, .requestMalformed) }
        guard let registered = run(matching: request.token) else {
            return refuse(connection, .runUnknown)
        }
        guard request.version == version else { return refuse(connection, .versionMismatch) }

        guard let root = awaitRoot(of: registered.token) else {
            return refuse(connection, .rootProcessUnset)
        }
        let depth = PeerIdentity.depth(
            of: PeerIdentity.processIdentifier(of: peer),
            below: root.process,
            maximumDepth: Self.depthMeasurementLimit,
            ancestorStarted: root.started
        )
        if let depth { lock.withLock { measuredPeerDepth = depth } }
        guard let depth, depth <= Self.maximumPeerDepth else {
            return refuse(connection, .peerNotDescendant)
        }
        // The walk went by pid. Judging the same process again, by its audit token, shows the
        // pid still belongs to the caller that was verified.
        guard peerIsTrusted(peer) else { return refuse(connection, .peerChanged) }
        // The run may have been retired while the checks ran.
        guard let current = lock.withLock({ runs[registered.token] }) else {
            return refuse(connection, .runUnknown)
        }

        switch request.kind {
        case .list:
            send(BridgeReply(tools: current.tools), to: connection)
        case .call:
            guard let tool = request.tool, current.tools.contains(where: { $0.name == tool })
            else { return refuse(connection, .toolNotOffered) }
            let reply = invoke(
                token: current.token,
                tool: tool,
                arguments: request.arguments ?? .object([:])
            )
            send(reply, to: connection)
        }
    }

    /// The registered run whose token equals `candidate`. Every registered token is compared,
    /// each in constant time, so the time taken does not reveal how much of a guess matched.
    private func run(matching candidate: String) -> BridgeRun? {
        let guess = Array(candidate.utf8)
        return lock.withLock {
            var match: BridgeRun?
            for run in runs.values {
                let known = Array(run.token.utf8)
                var difference = known.count ^ guess.count
                for index in 0..<min(known.count, guess.count) {
                    difference |= Int(known[index] ^ guess[index])
                }
                if difference == 0 { match = run }
            }
            return match
        }
    }

    /// The run's root process and when it started, waiting briefly for the app to record them:
    /// the agent process may connect before the app has stored the pid of the process it just
    /// started.
    private func awaitRoot(of token: String) -> (process: pid_t, started: ProcessStartTime)? {
        let deadline = Date().addingTimeInterval(Self.rootProcessWait)
        while true {
            let snapshot = lock.withLock { runs[token] }
            guard let snapshot else { return nil }
            if let process = snapshot.rootProcess, let started = snapshot.rootStartTime {
                return (process, started)
            }
            guard Date() < deadline else { return nil }
            usleep(20_000)
        }
    }

    private func invoke(token: String, tool: String, arguments: JSONValue) -> BridgeReply {
        let outcome = CallOutcome()
        let finished = DispatchSemaphore(value: 0)
        let handler = handler
        // The connection thread waits on a semaphore so a slow call holds a dispatch thread,
        // never one of the cooperative pool's.
        let task = Task.detached {
            outcome.store(await handler(token, tool, arguments))
            finished.signal()
        }
        guard finished.wait(timeout: .now() + callTimeout) == .success,
              let reply = outcome.reply
        else {
            task.cancel()
            log(.callTimedOut)
            return .failure(Refusal.callTimedOut.sentence)
        }
        return reply
    }

    private func send(_ reply: BridgeReply, to connection: Int32) {
        var line = (try? JSONEncoder().encode(reply)) ?? Data()
        if line.isEmpty || line.count > BridgeWire.maximumReplyLine {
            log(.resultTooLarge)
            line = (try? JSONEncoder().encode(
                BridgeReply.failure(Refusal.resultTooLarge.sentence)
            )) ?? Data()
        }
        _ = BridgeWire.writeLine(line, to: connection)
    }

    private func refuse(_ connection: Int32, _ reason: Refusal) {
        log(reason)
        send(
            reason == .busy ? .busy(reason.sentence) : .failure(reason.sentence),
            to: connection
        )
    }

    /// Records a refusal by name. One line per reason per half minute reaches the log file; the
    /// rest go to the unified log's debug level, so a caller that keeps retrying cannot push
    /// useful lines out of the rotating file.
    private func log(_ reason: Refusal) {
        let now = Date()
        let shouldWriteToFile = lock.withLock {
            if let last = lastRefusalError[reason], now.timeIntervalSince(last) < 30 {
                return false
            }
            lastRefusalError[reason] = now
            return true
        }
        let message = "agent bridge refused: \(reason.rawValue)"
        if shouldWriteToFile {
            AppLog.error(.agentDispatch, message)
        } else {
            AppLog.debug(.agentDispatch, message)
        }
    }
}

/// Hands one reply from the task that produced it to the thread waiting for it.
private final class CallOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BridgeReply?

    var reply: BridgeReply? { lock.withLock { stored } }

    func store(_ reply: BridgeReply) {
        lock.withLock { stored = reply }
    }
}
