import Darwin
import Foundation

enum FleetHookStatus: String, Decodable, Sendable {
    case processing
    case runningTool = "running_tool"
    case waitingForInput = "waiting_for_input"
    case waitingForApproval = "waiting_for_approval"
    case notification
    case compacting
    case ended
    case unknown
}

struct FleetHookEvent: Decodable, Sendable {
    let sessionID: String
    let cwd: String
    let event: String
    let pid: Int32
    let tty: String?
    let status: FleetHookStatus
    let notificationType: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case event
        case pid
        case tty
        case status
        case notificationType = "notification_type"
        case message
    }

    var isValid: Bool {
        pid > 0
            && !sessionID.isEmpty
            && sessionID.count <= 256
            && cwd.count <= 4096
            && event.count <= 128
            && (tty?.count ?? 0) <= 64
            && (notificationType?.count ?? 0) <= 128
    }
}

/// Owns the local hook socket and delivers complete, validated events on the main actor.
@MainActor
final class AgentEventSocket {
    var onEvent: ((FleetHookEvent) -> Void)?

    static let defaultSocketPath = "/tmp/claude-island.sock"

    private let socketPath: String
    private var worker: Worker?

    init(socketPath: String = AgentEventSocket.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func start() {
        guard worker == nil else { return }
        let worker = Worker(socketPath: socketPath) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.onEvent?(event)
            }
        }
        self.worker = worker
        worker.start()
    }

    func stop() {
        worker?.stop()
        worker = nil
    }
}

private final class Worker: @unchecked Sendable {
    private static let maximumPayloadSize = 64 * 1024
    private static let approvalReply = Data(#"{"decision":"ask"}"#.utf8)

    private let socketPath: String
    private let deliver: @Sendable (FleetHookEvent) -> Void
    private let queue = DispatchQueue(label: "com.supervisor.agent-event-socket")

    // Access is confined to `queue`.
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var isRunning = false

    init(
        socketPath: String,
        deliver: @escaping @Sendable (FleetHookEvent) -> Void
    ) {
        self.socketPath = socketPath
        self.deliver = deliver
    }

    deinit {
        if listener >= 0 {
            close(listener)
        }
        unlink(socketPath)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isRunning else { return }
            isRunning = true
            openListener()
        }
    }

    func stop() {
        queue.sync {
            isRunning = false
            source?.cancel()
            source = nil
            if listener >= 0 {
                close(listener)
                listener = -1
            }
            unlink(socketPath)
            AppLog.debug(.swarm, "socket stopped and unlinked \(socketPath)")
        }
    }

    private func openListener() {
        unlink(socketPath)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            isRunning = false
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            isRunning = false
            return
        }
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { bytes in
                _ = pathBytes.withUnsafeBufferPointer {
                    memcpy(bytes, $0.baseAddress, pathBytes.count)
                }
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let didBind = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard didBind == 0 else {
            let bindError = errno
            close(descriptor)
            unlink(socketPath)
            isRunning = false
            AppLog.error(.swarm, "socket bind failed errno \(bindError)")
            return
        }
        guard listen(descriptor, SOMAXCONN) == 0 else {
            let listenError = errno
            close(descriptor)
            unlink(socketPath)
            isRunning = false
            AppLog.error(.swarm, "socket listen failed errno \(listenError)")
            return
        }

        _ = chmod(socketPath, S_IRUSR | S_IWUSR)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        listener = descriptor
        AppLog.notice(.swarm, "socket bound \(socketPath)")

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        self.source = source
        source.resume()
    }

    private func acceptPendingConnections() {
        guard isRunning, listener >= 0 else { return }
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            handle(connection)
        }
    }

    private func handle(_ connection: Int32) {
        defer { close(connection) }
        var repliedToApproval = false
        // Every exit path answers an unanswered connection with the pass-through decision. A
        // blocked PermissionRequest hook waits minutes for a reply, so even a payload whose
        // status field never arrived (truncation, the size cap, a malformed tail) must get the
        // answer; fire-and-forget clients have already closed and the write fails silently.
        defer {
            if !repliedToApproval {
                Self.writeApprovalReply(to: connection)
                AppLog.debug(.swarm, "approval fallback reply")
            }
        }

        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        var noPipe: Int32 = 1
        _ = setsockopt(
            connection,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
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
