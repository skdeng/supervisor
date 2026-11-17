import Foundation
import Testing

@testable import SuperVisor

@Suite("Agent bridge protocol")
struct AgentBridgeProtocolTests {
    private static let echoTool = BridgeTool(
        name: "echo",
        description: "Echoes its message.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["message": .object(["type": .string("string")])]),
            "required": .array([.string("message")]),
        ])
    )

    /// Runs one line through the protocol and decodes the reply. `nil` means no reply was sent.
    private func respond(
        _ line: String,
        list: BridgeReply = BridgeReply(tools: [AgentBridgeProtocolTests.echoTool]),
        call: @escaping (String, JSONValue) -> BridgeReply = { _, _ in BridgeReply(text: "done") }
    ) throws -> JSONValue? {
        var session = AgentBridgeProtocol()
        session.serverVersion = "9.9.9"
        guard let data = session.respond(
            to: Data(line.utf8),
            listTools: { list },
            callTool: call
        ) else { return nil }
        #expect(!data.contains(UInt8(ascii: "\n")), "a reply is a single line")
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(reply["jsonrpc"] == .string("2.0"))
        return reply
    }

    private func rawReply(_ line: String) -> String {
        var session = AgentBridgeProtocol()
        let data = session.respond(
            to: Data(line.utf8),
            listTools: { BridgeReply(tools: []) },
            callTool: { _, _ in BridgeReply(text: "") }
        )
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: Holding the first initialize

    @Test("The first initialize request waits for the hold, once; nothing else waits")
    func initializeHold() {
        var session = AgentBridgeProtocol()
        let pauses = Recorder<TimeInterval>()
        session.initializeHold = 6
        session.pause = { pauses.record($0) }
        let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)

        // A notification is not a request, so it neither waits nor uses up the hold.
        _ = session.respond(
            to: Data(#"{"jsonrpc":"2.0","method":"initialize"}"#.utf8),
            listTools: { BridgeReply(tools: []) },
            callTool: { _, _ in BridgeReply(text: "") }
        )
        _ = session.respond(
            to: Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8),
            listTools: { BridgeReply(tools: []) },
            callTool: { _, _ in BridgeReply(text: "") }
        )
        #expect(pauses.all.isEmpty)

        let first = session.respond(to: initialize, listTools: { BridgeReply(tools: []) }, callTool: { _, _ in BridgeReply(text: "") })
        #expect(first != nil)
        #expect(pauses.all == [6])

        _ = session.respond(to: initialize, listTools: { BridgeReply(tools: []) }, callTool: { _, _ in BridgeReply(text: "") })
        _ = session.respond(
            to: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8),
            listTools: { BridgeReply(tools: []) },
            callTool: { _, _ in BridgeReply(text: "") }
        )
        #expect(pauses.all == [6])
    }

    @Test("With no hold nothing waits")
    func noHold() {
        var session = AgentBridgeProtocol()
        let pauses = Recorder<TimeInterval>()
        session.pause = { pauses.record($0) }

        _ = session.respond(
            to: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8),
            listTools: { BridgeReply(tools: []) },
            callTool: { _, _ in BridgeReply(text: "") }
        )

        #expect(pauses.all.isEmpty)
    }

    // MARK: initialize and notifications

    @Test("initialize answers with the client's protocol version, the server's identity, and a tools capability")
    func initialize() throws {
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#
        ))
        #expect(reply["id"] == .number(1))
        let result = try #require(reply["result"])
        #expect(result["protocolVersion"] == .string("2025-03-26"))
        #expect(result["capabilities"] == .object(["tools": .object([:])]))
        #expect(result["serverInfo"]?["name"] == .string("supervisor"))
        #expect(result["serverInfo"]?["version"] == .string("9.9.9"))
        #expect(reply["error"] == nil)
    }

    @Test("initialize answers with each supported version the client asks for")
    func initializeSupportedVersions() throws {
        #expect(AgentBridgeProtocol.supportedProtocolVersions == ["2024-11-05", "2025-03-26", "2025-06-18"])
        for version in AgentBridgeProtocol.supportedProtocolVersions {
            let reply = try #require(try respond(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)"}}"#
            ))
            #expect(reply["result"]?["protocolVersion"] == .string(version))
        }
    }

    @Test("initialize answers with the newest version when the client names none, a version not supported, or a non-string")
    func initializeNewestVersion() throws {
        #expect(AgentBridgeProtocol.newestProtocolVersion == "2025-06-18")
        let params = [
            #"{}"#, #"{"protocolVersion":5}"#, #"{"protocolVersion":null}"#,
            #"{"protocolVersion":"2099-01-01"}"#, #"{"protocolVersion":"2024-11-04"}"#,
            #"{"protocolVersion":"2025-06-18 "}"#, #"{"protocolVersion":""}"#,
        ]
        for params in params {
            let reply = try #require(try respond(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":\#(params)}"#
            ))
            #expect(reply["result"]?["protocolVersion"] == .string("2025-06-18"), "\(params)")
        }
        let withoutParams = try #require(try respond(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        ))
        #expect(withoutParams["result"]?["protocolVersion"] == .string("2025-06-18"))
    }

    @Test("The server version defaults to the bundle's short version")
    func serverVersionDefault() {
        let expected = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        #expect(AgentBridgeProtocol().serverVersion == expected)
    }

    @Test("Notifications get no reply, and never run a tool")
    func notificationsAreSilent() throws {
        #expect(try respond(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(try respond(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        #expect(try respond(#"{"jsonrpc":"2.0","method":"anything/else"}"#) == nil)
        #expect(try respond(#"{"jsonrpc":"2.0","method":"ping"}"#) == nil)

        let invoked = Recorder<String>()
        let reply = try respond(
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"echo","arguments":{}}}"#,
            call: { name, _ in
                invoked.record(name)
                return BridgeReply(text: "ran")
            }
        )
        #expect(reply == nil)
        #expect(invoked.all.isEmpty)
    }

    @Test("ping answers with an empty result")
    func ping() throws {
        let reply = try #require(try respond(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        #expect(reply["id"] == .number(3))
        #expect(reply["result"] == .object([:]))
    }

    // MARK: ids

    @Test("A numeric id is echoed as the same number, a string id as the same string")
    func idEcho() throws {
        let numeric = try #require(try respond(#"{"jsonrpc":"2.0","id":42,"method":"ping"}"#))
        #expect(numeric["id"] == .number(42))
        let zero = try #require(try respond(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#))
        #expect(zero["id"] == .number(0))
        let text = try #require(try respond(#"{"jsonrpc":"2.0","id":"req-7","method":"ping"}"#))
        #expect(text["id"] == .string("req-7"))
        let numericText = try #require(try respond(#"{"jsonrpc":"2.0","id":"7","method":"ping"}"#))
        #expect(numericText["id"] == .string("7"))
    }

    @Test("An integer id beyond 2^53 is echoed digit for digit")
    func largeIDEcho() {
        #expect(rawReply(#"{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}"#)
            .contains(#""id":9007199254740993"#))
        #expect(rawReply(#"{"jsonrpc":"2.0","id":-5,"method":"ping"}"#).contains(#""id":-5"#))
    }

    @Test("Errors echo the request's id too")
    func errorsEchoID() throws {
        let numeric = try #require(try respond(#"{"jsonrpc":"2.0","id":9,"method":"nope"}"#))
        #expect(numeric["id"] == .number(9))
        let text = try #require(try respond(#"{"jsonrpc":"2.0","id":"x","method":"nope"}"#))
        #expect(text["id"] == .string("x"))
    }

    // MARK: tools/list

    @Test("tools/list returns each tool's name, description, and schema")
    func toolsList() throws {
        let reply = try #require(try respond(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        let tools = try #require(reply["result"]?["tools"])
        #expect(tools == .array([
            .object([
                "name": .string("echo"),
                "description": .string("Echoes its message."),
                "inputSchema": Self.echoTool.inputSchema,
            ]),
        ]))
    }

    @Test("tools/list with no tools returns an empty list")
    func toolsListEmpty() throws {
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            list: BridgeReply(tools: nil)
        ))
        #expect(reply["result"]?["tools"] == .array([]))
    }

    @Test("A failed tool listing becomes a JSON-RPC error carrying the reason")
    func toolsListError() throws {
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            list: .failure("SuperVisor is not reachable.")
        ))
        #expect(reply["result"] == nil)
        #expect(reply["id"] == .number(2))
        #expect(reply["error"]?["code"] == .number(-32000))
        #expect(reply["error"]?["message"] == .string("SuperVisor is not reachable."))
    }

    // MARK: tools/call

    @Test("tools/call passes the name and arguments through and wraps the text")
    func toolsCall() throws {
        let seen = Recorder<String>()
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi","n":2}}}"#,
            call: { name, arguments in
                seen.record("\(name)|\(arguments["message"]?.stringValue ?? "")|\(arguments["n"]?.intValue ?? -1)")
                return BridgeReply(text: "echo: hi")
            }
        ))
        #expect(seen.all == ["echo|hi|2"])
        #expect(reply["id"] == .number(5))
        #expect(reply["result"] == .object([
            "content": .array([.object(["type": .string("text"), "text": .string("echo: hi")])]),
            "isError": .bool(false),
        ]))
    }

    @Test("tools/call carries a tool's error flag into the result, not into a JSON-RPC error")
    func toolsCallToolError() throws {
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo"}}"#,
            call: { _, _ in .failure("no such page") }
        ))
        #expect(reply["error"] == nil)
        #expect(reply["result"]?["isError"] == .bool(true))
        #expect(reply["result"]?["content"] == .array([
            .object(["type": .string("text"), "text": .string("no such page")]),
        ]))
    }

    @Test("tools/call without arguments, or with null arguments, runs the tool with an empty object")
    func toolsCallDefaultArguments() throws {
        let seen = Recorder<JSONValue>()
        for params in [#"{"name":"echo"}"#, #"{"name":"echo","arguments":null}"#] {
            _ = try respond(
                #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":\#(params)}"#,
                call: { _, arguments in
                    seen.record(arguments)
                    return BridgeReply(text: "")
                }
            )
        }
        #expect(seen.all == [.object([:]), .object([:])])
    }

    @Test("tools/call with a missing name or non-object arguments is an invalid-params error and runs nothing")
    func toolsCallInvalidParams() throws {
        let invoked = Recorder<String>()
        let call: (String, JSONValue) -> BridgeReply = { name, _ in
            invoked.record(name)
            return BridgeReply(text: "ran")
        }
        let badRequests = [
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":3}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":"x"}}"#,
        ]
        for request in badRequests {
            let reply = try #require(try respond(request, call: call))
            #expect(reply["error"]?["code"] == .number(-32602), "\(request)")
            #expect(reply["id"] == .number(1))
        }
        #expect(invoked.all.isEmpty)
    }

    @Test("A result longer than 100,000 characters is cut, with a note saying so")
    func longTextIsCut() throws {
        let long = String(repeating: "a", count: 100_001)
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo"}}"#,
            call: { _, _ in BridgeReply(text: long) }
        ))
        let text = try #require(reply["result"]?["content"]).arrayValue.flatMap { $0.first }
        let body = try #require(text?["text"]?.stringValue)
        #expect(body.hasPrefix(String(repeating: "a", count: 100_000)))
        #expect(body.hasSuffix(AgentBridgeProtocol.truncationNote))
        #expect(body.count == 100_000 + AgentBridgeProtocol.truncationNote.count)
        #expect(AgentBridgeProtocol.truncationNote.contains("cut"))
    }

    @Test("A result of exactly 100,000 characters is returned whole")
    func textAtTheLimitIsKept() throws {
        let exact = String(repeating: "é", count: 100_000)
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo"}}"#,
            call: { _, _ in BridgeReply(text: exact) }
        ))
        let body = try #require(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(body == exact)
    }

    @Test("Newlines and quotes inside a result stay within one reply line")
    func replyIsOneLine() throws {
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo"}}"#,
            call: { _, _ in BridgeReply(text: "line one\nline \"two\"\r\n\u{2028}end") }
        ))
        let body = try #require(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(body == "line one\nline \"two\"\r\n\u{2028}end")
    }

    // MARK: malformed input

    @Test("An unknown method with an id is a method-not-found error")
    func unknownMethod() throws {
        let reply = try #require(try respond(#"{"jsonrpc":"2.0","id":8,"method":"resources/list"}"#))
        #expect(reply["error"]?["code"] == .number(-32601))
        #expect(reply["id"] == .number(8))
        #expect(reply["result"] == nil)
    }

    @Test("Unparseable input is a parse error with a null id")
    func parseError() throws {
        for line in ["not json", "", "{", #"{"jsonrpc":"2.0","id":1,"method":"ping""#, "\u{0}"] {
            let reply = try #require(try respond(line), "\(line)")
            #expect(reply["error"]?["code"] == .number(-32700), "\(line)")
            #expect(reply["id"] == .null)
        }
    }

    @Test("JSON that is not a request object is an invalid-request error")
    func invalidRequest() throws {
        for line in [#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, "5", #""text""#, "null"] {
            let reply = try #require(try respond(line), "\(line)")
            #expect(reply["error"]?["code"] == .number(-32600), "\(line)")
            #expect(reply["id"] == .null)
        }
    }

    @Test("A request with an id but no method keeps its id in the error")
    func missingMethod() throws {
        let reply = try #require(try respond(#"{"jsonrpc":"2.0","id":4}"#))
        #expect(reply["error"]?["code"] == .number(-32600))
        #expect(reply["id"] == .number(4))
    }

    @Test("A null or non-scalar id is an invalid request, not a notification")
    func invalidID() throws {
        for line in [
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#,
        ] {
            let reply = try #require(try respond(line), "\(line)")
            #expect(reply["error"]?["code"] == .number(-32600), "\(line)")
            #expect(reply["id"] == .null)
        }
    }

    @Test("A line over 1 MiB is refused with an invalid-request error, unread")
    func oversizedLine() throws {
        let padding = String(repeating: "x", count: AgentBridgeProtocol.maximumRequestBytes)
        let invoked = Recorder<String>()
        let reply = try #require(try respond(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"p":"\#(padding)"}}}"#,
            call: { name, _ in
                invoked.record(name)
                return BridgeReply(text: "")
            }
        ))
        #expect(reply["error"]?["code"] == .number(-32600))
        #expect(reply["id"] == .null)
        #expect(invoked.all.isEmpty)

        let helperReply = try JSONDecoder().decode(
            JSONValue.self,
            from: AgentBridgeProtocol.oversizedRequestReply()
        )
        #expect(helperReply == reply)
    }

    @Test("A line of exactly 1 MiB is still parsed")
    func lineAtTheLimit() throws {
        let prefix = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"p":""#
        let suffix = #""}}"#
        let padding = AgentBridgeProtocol.maximumRequestBytes - prefix.utf8.count - suffix.utf8.count
        let reply = try #require(try respond(prefix + String(repeating: "x", count: padding) + suffix))
        #expect(reply["result"] == .object([:]))
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }
}
