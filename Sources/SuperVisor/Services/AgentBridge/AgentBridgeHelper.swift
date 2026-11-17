import Darwin
import Foundation

/// The helper process an agent run's tool client starts: this app's own executable, launched
/// with `--agent-bridge`. It speaks MCP over stdio and forwards each tool request to the running
/// app over a Unix socket. It holds no state and no secret beyond the run's token, which it is
/// handed in its environment, and it sends that token only to a server running this app's own
/// code.
///
/// Started with no token, it offers no tools and never contacts the app. Either way it can wait
/// before answering the first `initialize` (`settleVariable`), which holds back the first turn
/// of a client that waits for its configured servers to connect.
///
/// It runs before any UI exists and does not touch AppKit or the app's log. **Standard output
/// carries protocol lines and nothing else**: anything else written there corrupts the stream
/// the client is parsing.
enum AgentBridgeHelper {
    static let flag = "--agent-bridge"
    static let tokenVariable = "SUPERVISOR_BRIDGE_TOKEN"
    /// Names a socket path to use in place of the default, for a process whose home folder
    /// makes that path too long for `sun_path`.
    static let socketVariable = "SUPERVISOR_BRIDGE_SOCKET"
    /// Names how many milliseconds the helper waits before answering the first `initialize`,
    /// so a client that waits for its configured servers holds its first turn that long.
    static let settleVariable = "SUPERVISOR_BRIDGE_SETTLE_MS"
    static let maximumSettleMilliseconds = 15_000

    #if DEBUG
    /// Set to `1`, makes a debug build skip the check that the server runs this app's code.
    /// A process test serves the helper from the test runner, a different program, and could
    /// not otherwise reach it. Release builds have no such switch.
    static let trustAnyServerVariable = "SUPERVISOR_BRIDGE_TRUST_ANY_SERVER"
    #endif

    static let maximumBusyRetries = 3
    private static let busyBackoff: TimeInterval = 0.1

    /// How long one tool call may take to answer.
    private static let replyTimeout: TimeInterval = 300

    /// Answers every `tools/call` of a helper started with no token, which offers no tools.
    static let noToolSentence = "That tool is not available to this run."
    static let unreachableSentence = "SuperVisor is not reachable."
    static let unverifiedServerSentence = "SuperVisor could not be verified."

    /// The app's bridge socket. `NSHomeDirectory()` ignores `$HOME`.
    static var defaultSocketPath: String {
        NSHomeDirectory() + "/Library/Application Support/SuperVisor/agent-bridge.sock"
    }

    /// The socket this process connects to: `defaultSocketPath` unless the environment names
    /// another.
    static var socketPath: String {
        socketPath(environment: ProcessInfo.processInfo.environment)
    }

    static func socketPath(environment: [String: String]) -> String {
        if let override = environment[socketVariable], !override.isEmpty {
            return override
        }
        return defaultSocketPath
    }

    /// The bundle version a helper reports and the app expects.
    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// The wait named by `settleVariable`: a whole number of milliseconds from 0 to
    /// `maximumSettleMilliseconds`. Anything else, or no value, is 0.
    static func settleMilliseconds(environment: [String: String]) -> Int {
        guard let text = environment[settleVariable],
              text.range(of: #"\A[0-9]{1,5}\z"#, options: .regularExpression) != nil,
              let value = Int(text),
              value <= maximumSettleMilliseconds
        else { return 0 }
        return value
    }

    static func isRequested(in arguments: [String]) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// Whether the process on the far end of `descriptor` runs this app's own code. The token is
    /// the run's credential, so it goes only to a server that proves it is the app.
    static func isTrustedServer(
        _ descriptor: Int32,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        #if DEBUG
        if environment[trustAnyServerVariable] == "1" { return true }
        #endif
        guard let server = PeerIdentity.auditToken(of: descriptor) else { return false }
        return PeerIdentity.satisfiesOwnRequirement(server)
    }

    /// Runs `attempt`, running it again after a pause each time the app answers that it is busy,
    /// up to `maximumRetries` more times. `pause` receives the seconds to wait.
    static func retryingWhenBusy(
        maximumRetries: Int = maximumBusyRetries,
        pause: (TimeInterval) -> Void = { usleep(UInt32($0 * 1_000_000)) },
        attempt: () -> BridgeReply
    ) -> BridgeReply {
        var retries = 0
        while true {
            let reply = attempt()
            guard reply.isBusy == true, retries < maximumRetries else { return reply }
            pause(busyBackoff * Double(1 << retries))
            retries += 1
        }
    }

    /// Serves the client on stdin and stdout until stdin closes, then exits.
    static func run() -> Never {
        // A client that exits mid-write must surface as a failed write, not kill this process.
        signal(SIGPIPE, SIG_IGN)

        let environment = ProcessInfo.processInfo.environment
        let token = environment[tokenVariable] ?? ""
        let path = socketPath
        let version = bundleVersion
        var session = AgentBridgeProtocol()
        session.initializeHold = TimeInterval(settleMilliseconds(environment: environment)) / 1_000
        var input = BridgeLineReader(
            descriptor: STDIN_FILENO,
            limit: AgentBridgeProtocol.maximumRequestBytes
        )

        while true {
            let reply: Data?
            switch input.next(timeout: nil) {
            case let .line(line):
                reply = session.respond(
                    to: line,
                    listTools: {
                        // With no token the helper only holds a client back, and never
                        // contacts the app.
                        token.isEmpty ? BridgeReply(tools: []) : exchange(
                            BridgeRequest(
                                token: token, version: version, kind: .list,
                                tool: nil, arguments: nil
                            ),
                            path: path
                        )
                    },
                    callTool: { name, arguments in
                        token.isEmpty ? .failure(noToolSentence) : exchange(
                            BridgeRequest(
                                token: token, version: version, kind: .call,
                                tool: name, arguments: arguments
                            ),
                            path: path
                        )
                    }
                )
            case .tooLong:
                reply = AgentBridgeProtocol.oversizedRequestReply()
            case .closed:
                exit(0)
            case .timedOut, .failed:
                exit(1)
            }

            if let reply, !BridgeWire.writeLine(reply, to: STDOUT_FILENO) {
                exit(0)
            }
        }
    }

    /// One request and one reply, retried while the app is busy. Every failure becomes a fixed
    /// sentence: the token and the underlying errors never reach the client.
    private static func exchange(_ request: BridgeRequest, path: String) -> BridgeReply {
        guard let line = try? JSONEncoder().encode(request) else {
            return .failure("The tool request could not be encoded.")
        }
        return retryingWhenBusy { exchangeOnce(line, path: path) }
    }

    private static func exchangeOnce(_ line: Data, path: String) -> BridgeReply {
        guard let descriptor = UnixSocket.connect(to: path) else {
            return .failure(unreachableSentence)
        }
        defer { close(descriptor) }
        guard isTrustedServer(descriptor) else {
            return .failure(unverifiedServerSentence)
        }
        guard BridgeWire.writeLine(line, to: descriptor) else {
            return .failure(unreachableSentence)
        }

        switch BridgeWire.readLine(
            from: descriptor,
            limit: BridgeWire.maximumReplyLine,
            timeout: replyTimeout
        ) {
        case let .line(data):
            return (try? JSONDecoder().decode(BridgeReply.self, from: data))
                ?? .failure("SuperVisor sent a reply that could not be read.")
        case .tooLong:
            return .failure("The result was too large.")
        case .timedOut:
            return .failure("SuperVisor did not answer in time.")
        case .closed, .failed:
            return .failure(unreachableSentence)
        }
    }
}
