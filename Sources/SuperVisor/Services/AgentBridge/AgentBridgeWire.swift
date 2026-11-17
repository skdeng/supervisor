import Darwin
import Foundation

/// A tool the bridge offers to a run.
struct BridgeTool: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

/// What the helper process asks of the app, as one line of JSON.
struct BridgeRequest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case list
        case call
    }

    /// The run's credential: 32 lowercase hex characters.
    let token: String
    /// The helper's bundle version.
    let version: String
    let kind: Kind
    /// The tool to run, for `.call`.
    let tool: String?
    let arguments: JSONValue?

    /// Whether every field has the shape the bridge accepts. Patterns are anchored with `\A` and
    /// `\z`: ICU's `$` also matches before a trailing line terminator.
    var isWellFormed: Bool {
        guard Self.matches(token, #"\A[0-9a-f]{32}\z"#),
              !version.isEmpty,
              version.count <= 64
        else { return false }
        switch kind {
        case .list:
            return tool == nil
        case .call:
            guard let tool else { return false }
            return Self.matches(tool, #"\A[a-z][a-z0-9_]{0,63}\z"#)
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// The app's answer to a `BridgeRequest`, as one line of JSON.
struct BridgeReply: Codable, Equatable, Sendable {
    /// The run's tools, for `.list`.
    var tools: [BridgeTool]?
    /// The result text, for `.call`; the explanation when `isError`.
    var text: String?
    var isError: Bool
    /// Set on the refusal for a connection the app had no room to serve; the helper retries it.
    var isBusy: Bool?

    init(
        tools: [BridgeTool]? = nil,
        text: String? = nil,
        isError: Bool = false,
        isBusy: Bool? = nil
    ) {
        self.tools = tools
        self.text = text
        self.isError = isError
        self.isBusy = isBusy
    }

    static func failure(_ text: String) -> BridgeReply {
        BridgeReply(text: text, isError: true)
    }

    static func busy(_ text: String) -> BridgeReply {
        BridgeReply(text: text, isError: true, isBusy: true)
    }
}

/// Newline-delimited framing for the helper's socket, and the limits that bound it.
enum BridgeWire {
    static let maximumRequestLine = 64 * 1024
    static let maximumReplyLine = 2 * 1024 * 1024

    /// Reads one line of at most `limit` bytes. Bytes the peer sends after the line are dropped
    /// with the reader, so this suits a connection that carries a single message; a stream
    /// uses a `BridgeLineReader` of its own.
    static func readLine(
        from descriptor: Int32,
        limit: Int,
        timeout: TimeInterval?
    ) -> BridgeLineReader.Outcome {
        var reader = BridgeLineReader(descriptor: descriptor, limit: limit)
        return reader.next(timeout: timeout)
    }

    /// Writes `payload` and a terminating newline, resuming after partial writes and `EINTR`.
    /// The descriptor must be blocking. Returns false when the peer is gone or stops reading.
    static func writeLine(_ payload: Data, to descriptor: Int32) -> Bool {
        var line = payload
        line.append(UInt8(ascii: "\n"))
        return line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(descriptor, base + sent, bytes.count - sent)
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Reads newline-terminated lines from a descriptor, each at most `limit` bytes long.
///
/// Bytes read past a line's end stay buffered for the next call. A line longer than the limit is
/// reported as soon as it is known to be over, and its remainder is discarded up to the next
/// newline so the following call resumes at a line boundary.
struct BridgeLineReader {
    enum Outcome: Equatable {
        case line(Data)
        case tooLong
        /// No complete line arrived within the timeout.
        case timedOut
        /// The peer closed before finishing a line.
        case closed
        case failed
    }

    private enum Chunk {
        case data
        case timedOut
        case closed
        case failed
    }

    private static let newline = UInt8(ascii: "\n")
    private static let chunkSize = 16 * 1024

    private let descriptor: Int32
    private let limit: Int
    private var buffer: [UInt8] = []
    /// Bytes before this index are known to hold no newline.
    private var scanned = 0
    private var isDiscarding = false

    init(descriptor: Int32, limit: Int) {
        self.descriptor = descriptor
        self.limit = limit
    }

    /// The next line. `timeout` bounds the whole wait for it; nil waits indefinitely.
    mutating func next(timeout: TimeInterval?) -> Outcome {
        let deadline = timeout.map {
            DispatchTime.now().uptimeNanoseconds + UInt64(max(0, $0) * 1_000_000_000)
        }
        while true {
            if isDiscarding {
                if let end = buffer.firstIndex(of: Self.newline) {
                    buffer.removeSubrange(0...end)
                    isDiscarding = false
                } else {
                    buffer.removeAll(keepingCapacity: true)
                }
                scanned = 0
            }

            if !isDiscarding {
                if let end = buffer[scanned...].firstIndex(of: Self.newline) {
                    let line = Data(buffer[0..<end])
                    buffer.removeSubrange(0...end)
                    scanned = 0
                    return end > limit ? .tooLong : .line(line)
                }
                scanned = buffer.count
                if buffer.count > limit {
                    buffer.removeAll(keepingCapacity: true)
                    scanned = 0
                    isDiscarding = true
                    return .tooLong
                }
            }

            switch readChunk(deadline: deadline) {
            case .data: continue
            case .timedOut: return .timedOut
            case .closed: return .closed
            case .failed: return .failed
            }
        }
    }

    private mutating func readChunk(deadline: UInt64?) -> Chunk {
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return .timedOut }
                let milliseconds = min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max))
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollDescriptor, 1, Int32(milliseconds))
                if ready == 0 { return .timedOut }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .failed
                }
            }

            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                return .data
            }
            if count == 0 { return .closed }
            if errno == EINTR || errno == EAGAIN { continue }
            return .failed
        }
    }
}
