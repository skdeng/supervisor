import Foundation

/// The helper's side of MCP over stdio: turns one JSON-RPC 2.0 line into at most one reply line.
///
/// Reaching the app is left to the two closures passed to `respond`, which keeps this type free
/// of sockets and processes. Batches are not supported; each line holds one message.
struct AgentBridgeProtocol {
    static let serverName = "supervisor"
    /// The MCP protocol versions this server speaks, oldest first.
    static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18"]
    /// Answered when the client's `initialize` names a version this server does not speak.
    static var newestProtocolVersion: String {
        supportedProtocolVersions[supportedProtocolVersions.count - 1]
    }
    /// A request line longer than this is refused unread.
    static let maximumRequestBytes = 1 << 20
    /// A tool result longer than this many characters is cut.
    static let maximumResultCharacters = 100_000
    static let truncationNote = "\n[Result cut: it was longer than \(maximumResultCharacters) characters.]"

    /// Reported as `serverInfo.version`.
    var serverVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "0"

    /// Seconds to wait before answering the first `initialize` request. A client does not
    /// start its first turn until every server it configured has connected, so the wait holds
    /// that turn back.
    var initializeHold: TimeInterval = 0
    /// Performs the wait; replaced in tests.
    var pause: (TimeInterval) -> Void = { usleep(UInt32(max(0, $0) * 1_000_000)) }
    private var hasHeldInitialize = false

    /// The reply to a request line the reader refused for its length.
    static func oversizedRequestReply() -> Data {
        encode(.failure(id: nil, code: ErrorCode.invalidRequest, message: "Request too large"))
    }

    /// The reply to `line`, or nil when it needs none (a notification).
    mutating func respond(
        to line: Data,
        listTools: () -> BridgeReply,
        callTool: (_ name: String, _ arguments: JSONValue) -> BridgeReply
    ) -> Data? {
        guard line.count <= Self.maximumRequestBytes else {
            return Self.oversizedRequestReply()
        }
        let decoder = JSONDecoder()
        guard let message = try? decoder.decode(Message.self, from: line) else {
            // Valid JSON of another shape (a batch, a bare value) is an invalid request;
            // anything else did not parse.
            let isJSON = (try? decoder.decode(JSONValue.self, from: line)) != nil
            return Self.encode(.failure(
                id: nil,
                code: isJSON ? ErrorCode.invalidRequest : ErrorCode.parseError,
                message: isJSON ? "Invalid request" : "Parse error"
            ))
        }

        // A message without an `id` is a notification: it is never answered and never acted on.
        guard message.hasID else { return nil }
        guard let id = message.id, let method = message.method else {
            return Self.encode(.failure(
                id: message.id,
                code: ErrorCode.invalidRequest,
                message: "Invalid request"
            ))
        }

        switch method {
        case "initialize":
            holdFirstInitialize()
            return Self.encode(.success(id: id, result: initializeResult(message.params)))
        case "ping":
            return Self.encode(.success(id: id, result: .object([:])))
        case "tools/list":
            return Self.encode(toolList(id: id, reply: listTools()))
        case "tools/call":
            return Self.encode(toolCall(id: id, params: message.params, callTool: callTool))
        default:
            return Self.encode(.failure(
                id: id,
                code: ErrorCode.methodNotFound,
                message: "Method not found"
            ))
        }
    }

    // MARK: Methods

    private mutating func holdFirstInitialize() {
        guard !hasHeldInitialize else { return }
        hasHeldInitialize = true
        if initializeHold > 0 { pause(initializeHold) }
    }

    private func initializeResult(_ params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let agreed = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.newestProtocolVersion
        return .object([
            "protocolVersion": .string(agreed),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(serverVersion),
            ]),
        ])
    }

    private func toolList(id: RequestID, reply: BridgeReply) -> Response {
        if reply.isError {
            return .failure(
                id: id,
                code: ErrorCode.serverError,
                message: reply.text ?? "The tool list is unavailable."
            )
        }
        let tools = (reply.tools ?? []).map { tool in
            JSONValue.object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
            ])
        }
        return .success(id: id, result: .object(["tools": .array(tools)]))
    }

    private func toolCall(
        id: RequestID,
        params: JSONValue?,
        callTool: (_ name: String, _ arguments: JSONValue) -> BridgeReply
    ) -> Response {
        guard let name = params?["name"]?.stringValue else {
            return .failure(id: id, code: ErrorCode.invalidParams, message: "Invalid params")
        }
        let arguments: JSONValue
        switch params?["arguments"] {
        case nil, .null?:
            arguments = .object([:])
        case let value? where value.objectValue != nil:
            arguments = value
        default:
            return .failure(id: id, code: ErrorCode.invalidParams, message: "Invalid params")
        }

        let reply = callTool(name, arguments)
        return .success(id: id, result: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(Self.bounded(reply.text ?? "")),
                ]),
            ]),
            "isError": .bool(reply.isError),
        ]))
    }

    private static func bounded(_ text: String) -> String {
        guard text.count > maximumResultCharacters else { return text }
        return String(text.prefix(maximumResultCharacters)) + truncationNote
    }

    // MARK: Encoding

    private enum ErrorCode {
        static let parseError = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
        static let serverError = -32000
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let internalError = Data(
        #"{"error":{"code":-32603,"message":"Internal error"},"id":null,"jsonrpc":"2.0"}"#.utf8
    )

    private static func encode(_ response: Response) -> Data {
        (try? encoder.encode(response)) ?? internalError
    }

    /// A JSON-RPC request id: a number or a string, echoed exactly as received. Integers keep
    /// full 64-bit precision, which a `Double` would not.
    private enum RequestID: Codable, Equatable {
        case integer(Int64)
        case number(Double)
        case string(String)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .integer(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .string(value): try container.encode(value)
            }
        }
    }

    /// An incoming message, read leniently so a malformed member never hides the `id` the error
    /// reply must carry.
    private struct Message: Decodable {
        private enum Keys: String, CodingKey {
            case id, method, params
        }

        /// Whether the `id` member is present at all; a null or malformed `id` still counts.
        let hasID: Bool
        let id: RequestID?
        let method: String?
        let params: JSONValue?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            hasID = container.contains(.id)
            id = try? container.decode(RequestID.self, forKey: .id)
            method = try? container.decode(String.self, forKey: .method)
            params = try? container.decode(JSONValue.self, forKey: .params)
        }
    }

    private struct Response: Encodable {
        private enum Keys: String, CodingKey {
            case jsonrpc, id, result, error
        }

        private struct Failure: Encodable {
            let code: Int
            let message: String
        }

        let id: RequestID?
        let result: JSONValue?
        private let errorBody: Failure?

        static func success(id: RequestID, result: JSONValue) -> Response {
            Response(id: id, result: result, errorBody: nil)
        }

        static func failure(id: RequestID?, code: Int, message: String) -> Response {
            Response(id: id, result: nil, errorBody: Failure(code: code, message: message))
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode("2.0", forKey: .jsonrpc)
            if let id {
                try container.encode(id, forKey: .id)
            } else {
                try container.encodeNil(forKey: .id)
            }
            try container.encodeIfPresent(result, forKey: .result)
            try container.encodeIfPresent(errorBody, forKey: .error)
        }
    }
}
