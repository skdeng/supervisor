import Darwin
import Foundation

enum FleetHookStatus: String, Decodable, Sendable {
    case processing
    case runningTool = "running_tool"
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case notification
    case sessionStart = "session_start"
    case error
    case compacting
    case ended
    case unknown
}

struct FleetHookEvent: Decodable, Sendable {
    /// The longest a text field may be before the payload is rejected. The hook truncates well
    /// below this; the cap bounds what an arbitrary local writer to the socket can hand over.
    static let maximumTextLength = 1_024

    let sessionID: String
    let cwd: String
    let event: String
    let pid: Int32
    let tty: String?
    let status: FleetHookStatus
    let notificationType: String?
    let message: String?
    /// Text of the last assistant message of a finished turn. Model-generated, so it is
    /// length-checked here and sanitized again before it reaches a view.
    let lastAssistantMessage: String?
    /// Why a turn ended abnormally — `rate_limit`, `billing_error`, `authentication_failed`,
    /// and the rest of Claude Code's assistant-error cases.
    let error: String?
    let errorDetails: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case event
        case pid
        case tty
        case status
        case notificationType = "notification_type"
        case message
        case lastAssistantMessage = "last_assistant_message"
        case error
        case errorDetails = "error_details"
    }

    var isValid: Bool {
        pid > 0
            && !sessionID.isEmpty
            && sessionID.count <= 256
            && cwd.count <= 4096
            && event.count <= 128
            && (tty?.count ?? 0) <= 64
            && (notificationType?.count ?? 0) <= 128
            && (message?.count ?? 0) <= Self.maximumTextLength
            && (lastAssistantMessage?.count ?? 0) <= Self.maximumTextLength
            && (error?.count ?? 0) <= 128
            && (errorDetails?.count ?? 0) <= Self.maximumTextLength
    }
}

/// Owns the local hook socket and delivers complete, validated events on the main actor.
@MainActor
final class AgentEventSocket {
    var onEvent: ((FleetHookEvent) -> Void)?

    /// Lives beside the app's other managed state rather than in `/tmp`, so the path belongs to
    /// SuperVisor and cannot collide with another tool's socket. `sun_path` holds 104 bytes; a
    /// home directory long enough to overrun that fails the bind and is logged.
    static let defaultSocketPath = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("SuperVisor", isDirectory: true)
        .appendingPathComponent("agent-hooks.sock", isDirectory: false)
        .path

    private let socketPath: String
    private var listener: UnixSocketListener?

    init(socketPath: String = AgentEventSocket.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func start() {
        guard listener == nil else { return }
        let connections = EventConnectionHandler { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.onEvent?(event)
                }
            }
        }
        let listener = UnixSocketListener(
            path: socketPath,
            queue: DispatchQueue(label: "com.supervisor.agent-event-socket")
        ) { connection in
            connections.handle(connection)
        }
        do {
            try listener.start()
        } catch let failure as UnixSocketListener.Failure {
            switch failure {
            case .pathTooLong:
                AppLog.error(.swarm, "socket path too long")
            case let .socketFailed(code):
                AppLog.error(.swarm, "socket create failed errno \(code)")
            case let .bindFailed(code):
                AppLog.error(.swarm, "socket bind failed errno \(code)")
            case let .listenFailed(code):
                AppLog.error(.swarm, "socket listen failed errno \(code)")
            }
            return
        } catch {
            AppLog.error(.swarm, "socket start failed")
            return
        }
        self.listener = listener
        AppLog.notice(.swarm, "socket bound \(socketPath)")
    }

    func stop() {
        guard let listener else { return }
        listener.stop()
        self.listener = nil
        AppLog.debug(.swarm, "socket stopped and unlinked \(socketPath)")
    }
}

/// Reads one hook payload from each connection the listener hands over.
private final class EventConnectionHandler: Sendable {
    private static let maximumPayloadSize = 64 * 1024
    private static let approvalReply = Data(#"{"decision":"ask"}"#.utf8)

    private let deliver: @Sendable (FleetHookEvent) -> Void

    init(deliver: @escaping @Sendable (FleetHookEvent) -> Void) {
        self.deliver = deliver
    }

    func handle(_ connection: Int32) {
        defer { close(connection) }
        var repliedToApproval = false
        // Every exit path answers an unanswered connection with the pass-through decision. The
        // hooks this app installs never block, but the socket is reachable by any local client:
        // one that announces `waiting_for_approval` is waiting on a reply, so even a payload
        // whose status field never arrived (truncation, the size cap, a malformed tail) must get
        // the answer. Fire-and-forget clients have already closed and the write fails silently.
        defer {
            if !repliedToApproval {
                Self.writeApprovalReply(to: connection)
                AppLog.debug(.swarm, "approval fallback reply")
            }
        }

        var deadline = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(
            connection,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &deadline,
            socklen_t(MemoryLayout<timeval>.size)
        )

        var payload = Data()
        while payload.count < Self.maximumPayloadSize {
            var buffer = [UInt8](
                repeating: 0,
                count: min(4_096, Self.maximumPayloadSize - payload.count)
            )
            let count = recv(connection, &buffer, buffer.count, 0)
            if count > 0 {
                payload.append(buffer, count: count)
                if !repliedToApproval,
                   Self.rootStatus(in: payload)
                    == FleetHookStatus.waitingForApproval.rawValue {
                    Self.writeApprovalReply(to: connection)
                    repliedToApproval = true
                    AppLog.debug(.swarm, "approval streaming reply sent")
                }

                guard let object = try? JSONSerialization.jsonObject(with: payload),
                      let dictionary = object as? [String: Any]
                else { continue }

                if !repliedToApproval,
                   dictionary["status"] as? String
                    == FleetHookStatus.waitingForApproval.rawValue {
                    Self.writeApprovalReply(to: connection)
                    repliedToApproval = true
                    AppLog.debug(.swarm, "approval streaming reply sent")
                }

                guard let event = try? JSONDecoder().decode(
                    FleetHookEvent.self,
                    from: payload
                ), event.isValid else {
                    AppLog.error(.swarm, "dropped malformed socket payload")
                    return
                }
                deliver(event)
                return
            }
            if count == 0 {
                if !payload.isEmpty {
                    AppLog.error(.swarm, "dropped malformed socket payload")
                }
                return
            }
            if errno == EINTR { continue }
            if !payload.isEmpty {
                AppLog.error(.swarm, "dropped malformed socket payload")
            }
            return
        }
        AppLog.error(.swarm, "dropped oversized socket payload")
    }

    /// Reads the root `status` string without requiring the rest of the object to arrive. Hook
    /// payloads can carry large tool inputs after that field, while permission requests are
    /// already blocked waiting for this process to answer.
    private static func rootStatus(in data: Data) -> String? {
        let bytes = [UInt8](data)
        var index = 0
        skipWhitespace(in: bytes, index: &index)
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        index += 1

        while index < bytes.count {
            skipWhitespace(in: bytes, index: &index)
            guard let (key, afterKey) = parseJSONString(in: bytes, from: index) else {
                return nil
            }
            index = afterKey
            skipWhitespace(in: bytes, index: &index)
            guard index < bytes.count, bytes[index] == 0x3A else { return nil }
            index += 1
            skipWhitespace(in: bytes, index: &index)

            if key == "status" {
                return parseJSONString(in: bytes, from: index)?.value
            }

            guard let afterValue = endOfJSONValue(in: bytes, from: index) else {
                return nil
            }
            index = afterValue
            skipWhitespace(in: bytes, index: &index)
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x7D {
                return nil
            } else {
                return nil
            }
        }
        return nil
    }

    private static func parseJSONString(
        in bytes: [UInt8],
        from start: Int
    ) -> (value: String, next: Int)? {
        guard start < bytes.count, bytes[start] == 0x22 else { return nil }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let encoded = Data(bytes[start...index])
                guard let value = try? JSONDecoder().decode(String.self, from: encoded) else {
                    return nil
                }
                return (value, index + 1)
            }
            index += 1
        }
        return nil
    }

    private static func endOfJSONValue(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        var nesting = 0
        var isInsideString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
            } else {
                switch byte {
                case 0x22:
                    isInsideString = true
                case 0x7B, 0x5B:
                    nesting += 1
                case 0x7D:
                    if nesting == 0 { return index }
                    nesting -= 1
                case 0x5D:
                    guard nesting > 0 else { return nil }
                    nesting -= 1
                case 0x2C where nesting == 0:
                    return index
                default:
                    break
                }
            }
            index += 1
        }
        return nil
    }

    private static func skipWhitespace(in bytes: [UInt8], index: inout Int) {
        while index < bytes.count,
              bytes[index] == 0x20
                || bytes[index] == 0x09
                || bytes[index] == 0x0A
                || bytes[index] == 0x0D {
            index += 1
        }
    }

    private static func writeApprovalReply(to connection: Int32) {
        approvalReply.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(
                    connection,
                    baseAddress.advanced(by: sent),
                    bytes.count - sent
                )
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}
