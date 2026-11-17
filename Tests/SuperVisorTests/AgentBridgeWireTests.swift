import Darwin
import Foundation
import Testing

@testable import SuperVisor

@Suite("Agent bridge wire")
struct AgentBridgeWireTests {
    private let token = String(repeating: "ab12", count: 8)

    private func request(
        token: String? = nil,
        version: String = "1.0.0",
        kind: BridgeRequest.Kind = .list,
        tool: String? = nil,
        arguments: JSONValue? = nil
    ) -> BridgeRequest {
        BridgeRequest(
            token: token ?? self.token,
            version: version,
            kind: kind,
            tool: tool,
            arguments: arguments
        )
    }

    // MARK: Well-formedness

    @Test("A token is exactly 32 lowercase hex characters")
    func tokenShape() {
        let valid = [
            String(repeating: "0", count: 32),
            "0123456789abcdef0123456789abcdef",
            AgentBridgeServer.makeToken(),
        ]
        for token in valid {
            #expect(request(token: token).isWellFormed, "\(token)")
        }

        let invalid = [
            "",
            String(repeating: "a", count: 31),
            String(repeating: "a", count: 33),
            String(repeating: "A", count: 32),
            String(repeating: "g", count: 32),
            "0123456789abcdef0123456789abcde ",
            "0123456789abcdef0123456789abcdef\n",
            "\n0123456789abcdef0123456789abcdef",
            "0123456789abcdef\n0123456789abcdef",
            String(repeating: "é", count: 32),
            String(repeating: "٠", count: 32),
        ]
        for token in invalid {
            #expect(!request(token: token).isWellFormed, "\(token.debugDescription)")
        }
    }

    @Test("A version is one to 64 characters")
    func versionShape() {
        #expect(request(version: "1").isWellFormed)
        #expect(request(version: String(repeating: "v", count: 64)).isWellFormed)
        #expect(!request(version: "").isWellFormed)
        #expect(!request(version: String(repeating: "v", count: 65)).isWellFormed)
    }

    @Test("A call names a tool of lowercase letters, digits, and underscores; a list names none")
    func toolShape() {
        let validTools = [
            "a", "echo", "read_page", "t2", "a_b_3", "mcp__server__tool",
            String(repeating: "a", count: 64),
        ]
        for tool in validTools {
            #expect(request(kind: .call, tool: tool).isWellFormed, "\(tool)")
        }

        let invalidTools = [
            "", "Echo", "1tool", "_tool", "tool-name", "tool name", "tool\n", "tool.", "../x",
            String(repeating: "a", count: 65), "tóol",
        ]
        for tool in invalidTools {
            #expect(!request(kind: .call, tool: tool).isWellFormed, "\(tool.debugDescription)")
        }

        #expect(!request(kind: .call, tool: nil).isWellFormed)
        #expect(request(kind: .list, tool: nil).isWellFormed)
        #expect(!request(kind: .list, tool: "echo").isWellFormed)
    }

    // MARK: Round trips

    @Test("A request survives encoding and decoding, arguments included")
    func requestRoundTrip() throws {
        let original = request(
            kind: .call,
            tool: "read_page",
            arguments: .object([
                "url": .string("https://example.com/\u{1F600}"),
                "depth": .number(3),
                "flags": .array([.bool(true), .null, .string("a\nb")]),
            ])
        )
        let data = try JSONEncoder().encode(original)
        #expect(!data.contains(UInt8(ascii: "\n")))
        #expect(try JSONDecoder().decode(BridgeRequest.self, from: data) == original)

        let list = request()
        let listData = try JSONEncoder().encode(list)
        #expect(try JSONDecoder().decode(BridgeRequest.self, from: listData) == list)
    }

    @Test("A request decodes from the documented field names")
    func requestFieldNames() throws {
        let json = #"{"token":"\#(token)","version":"2","kind":"call","tool":"echo","arguments":{"a":1}}"#
        let decoded = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        #expect(decoded == request(version: "2", kind: .call, tool: "echo", arguments: .object(["a": .number(1)])))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                BridgeRequest.self,
                from: Data(#"{"token":"\#(token)","version":"2","kind":"destroy"}"#.utf8)
            )
        }
    }

    @Test("A reply survives encoding and decoding, and leaves absent fields out")
    func replyRoundTrip() throws {
        let tool = BridgeTool(
            name: "echo",
            description: "d",
            inputSchema: .object(["type": .string("object")])
        )
        for original in [
            BridgeReply(tools: [tool]),
            BridgeReply(text: "hello"),
            BridgeReply.failure("no"),
            BridgeReply.busy("later"),
            BridgeReply(tools: [], text: "", isError: false),
        ] {
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(BridgeReply.self, from: data) == original)
        }

        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BridgeReply(text: "hello"))
        ) as? [String: Any]
        #expect(Set(object?.keys ?? [:].keys) == ["text", "isError"])

        let busy = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BridgeReply.busy("later"))
        ) as? [String: Any]
        #expect(busy?["isBusy"] as? Bool == true)
        #expect(BridgeReply.failure("later").isBusy == nil)
        #expect(BridgeReply.busy("later") != BridgeReply.failure("later"))
    }

    // MARK: JSON values

    @Test("JSON values decode to the matching case and encode back")
    func jsonValueRoundTrip() throws {
        let json = #"{"n":null,"b":true,"i":3,"f":-1.5,"s":"x","a":[1,"two",[]],"o":{"k":{}}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == .object([
            "n": .null, "b": .bool(true), "i": .number(3), "f": .number(-1.5), "s": .string("x"),
            "a": .array([.number(1), .string("two"), .array([])]),
            "o": .object(["k": .object([:])]),
        ]))
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == value)
    }

    @Test("A boolean is not read as a number, nor a number as a boolean")
    func jsonValueScalars() throws {
        let decoded = try JSONDecoder().decode(
            [JSONValue].self,
            from: Data("[true,false,1,0]".utf8)
        )
        #expect(decoded == [.bool(true), .bool(false), .number(1), .number(0)])
    }

    @Test("JSON value accessors return a value only for the matching kind")
    func jsonValueAccessors() {
        let value = JSONValue.object([
            "s": .string("x"), "i": .number(7), "f": .number(1.5), "big": .number(1e30),
            "nan": .number(.nan), "neg": .number(-3),
        ])
        #expect(value["s"]?.stringValue == "x")
        #expect(value["i"]?.stringValue == nil)
        #expect(value["i"]?.intValue == 7)
        #expect(value["neg"]?.intValue == -3)
        #expect(value["f"]?.intValue == nil)
        #expect(value["big"]?.intValue == nil)
        #expect(value["nan"]?.intValue == nil)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["s"] == nil)
        #expect(JSONValue.array([.string("x")])["0"] == nil)
        #expect(JSONValue.string("x").objectValue == nil)
        #expect(value.objectValue?.count == 6)
    }

    // MARK: Line framing

    @Test("A line is returned without its newline, and bytes after it wait for the next call")
    func readsLines() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        _ = Darwin.write(pair.first, "one\ntwo\n\nthree", 14)

        var reader = BridgeLineReader(descriptor: pair.second, limit: 100)
        #expect(reader.next(timeout: 2) == .line(Data("one".utf8)))
        #expect(reader.next(timeout: 2) == .line(Data("two".utf8)))
        #expect(reader.next(timeout: 2) == .line(Data()))

        _ = Darwin.write(pair.first, "\n", 1)
        #expect(reader.next(timeout: 2) == .line(Data("three".utf8)))
    }

    @Test("A line of exactly the limit is accepted and one byte more is refused")
    func limitBoundary() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        let exact = String(repeating: "a", count: 50)
        let over = String(repeating: "b", count: 51)
        let payload = Array("\(exact)\n\(over)\nafter\n".utf8)
        _ = Darwin.write(pair.first, payload, payload.count)

        var reader = BridgeLineReader(descriptor: pair.second, limit: 50)
        #expect(reader.next(timeout: 2) == .line(Data(exact.utf8)))
        #expect(reader.next(timeout: 2) == .tooLong)
        #expect(reader.next(timeout: 2) == .line(Data("after".utf8)))
    }

    @Test("An over-long line is refused without waiting for its end, and its tail is skipped")
    func tooLongWithoutNewline() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        let flood = [UInt8](repeating: UInt8(ascii: "x"), count: 5_000)
        _ = Darwin.write(pair.first, flood, flood.count)

        var reader = BridgeLineReader(descriptor: pair.second, limit: 1_000)
        #expect(reader.next(timeout: 2) == .tooLong)

        // More of the same line arrives, then its newline, then a good line.
        _ = Darwin.write(pair.first, flood, flood.count)
        let rest = Array("tail\nnext\n".utf8)
        _ = Darwin.write(pair.first, rest, rest.count)
        #expect(reader.next(timeout: 2) == .line(Data("next".utf8)))
    }

    @Test("A line far over the limit is refused without waiting for its end")
    func tooLongBoundsMemory() throws {
        let pair = try #require(SocketPair())
        let limit = BridgeWire.maximumRequestLine

        // The writer offers eight times the limit with no newline. A reader that waited for the
        // end of the line would never return: the socket buffer holds a fraction of that.
        let writer = DispatchGroup()
        writer.enter()
        Thread {
            let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 8_192)
            var written = 0
            while written < limit * 8 {
                let count = Darwin.write(pair.first, chunk, chunk.count)
                if count <= 0 { break }
                written += count
            }
            writer.leave()
        }.start()

        var reader = BridgeLineReader(descriptor: pair.second, limit: limit)
        #expect(reader.next(timeout: 5) == .tooLong)

        Darwin.close(pair.second)
        writer.wait()
        Darwin.close(pair.first)
    }

    @Test("A silent peer times out, and the timeout holds for the whole line, not each byte")
    func timesOut() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }

        var reader = BridgeLineReader(descriptor: pair.second, limit: 100)
        let started = Date()
        #expect(reader.next(timeout: 0.2) == .timedOut)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.19)
        #expect(elapsed < 2)

        // Bytes keep arriving, none of them a newline.
        let dripping = DispatchGroup()
        dripping.enter()
        Thread {
            for _ in 0..<12 {
                _ = Darwin.write(pair.first, "z", 1)
                usleep(50_000)
            }
            dripping.leave()
        }.start()
        let dripStarted = Date()
        #expect(reader.next(timeout: 0.4) == .timedOut)
        #expect(Date().timeIntervalSince(dripStarted) < 1.5)
        dripping.wait()
    }

    @Test("A peer that closes mid-line, or before any byte, reports closed")
    func closedPeer() throws {
        let pair = try #require(SocketPair())
        _ = Darwin.write(pair.first, "partial", 7)
        Darwin.close(pair.first)
        defer { Darwin.close(pair.second) }

        var reader = BridgeLineReader(descriptor: pair.second, limit: 100)
        #expect(reader.next(timeout: 2) == .closed)
        #expect(reader.next(timeout: 2) == .closed)
    }

    @Test("A line already buffered is returned even after the peer closes")
    func bufferedLineSurvivesClose() throws {
        let pair = try #require(SocketPair())
        _ = Darwin.write(pair.first, "last\n", 5)
        Darwin.close(pair.first)
        defer { Darwin.close(pair.second) }

        var reader = BridgeLineReader(descriptor: pair.second, limit: 100)
        #expect(reader.next(timeout: 2) == .line(Data("last".utf8)))
        #expect(reader.next(timeout: 2) == .closed)
    }

    @Test("A descriptor that cannot be read reports failure, with or without a timeout")
    func unreadableDescriptor() throws {
        // Reading a directory fails with EISDIR. A closed descriptor would do, but its number
        // may be reused by a test running in parallel.
        let directory = open("/", O_RDONLY)
        try #require(directory >= 0)
        defer { close(directory) }

        var timed = BridgeLineReader(descriptor: directory, limit: 100)
        #expect(timed.next(timeout: 1) == .failed)
        var untimed = BridgeLineReader(descriptor: directory, limit: 100)
        #expect(untimed.next(timeout: nil) == .failed)
    }

    @Test("A line larger than the socket buffer is written whole while the reader drains it")
    func writesPartialWrites() throws {
        let pair = try #require(SocketPair())
        defer { pair.close() }
        let payload = Data((0..<(1 << 20)).map { UInt8(ascii: "a") + UInt8($0 % 26) })

        let received = Recorder<Data>()
        let reading = Thread {
            var reader = BridgeLineReader(descriptor: pair.second, limit: BridgeWire.maximumReplyLine)
            if case let .line(data) = reader.next(timeout: 10) { received.record(data) }
        }
        reading.start()

        #expect(BridgeWire.writeLine(payload, to: pair.first))
        let deadline = Date().addingTimeInterval(10)
        while received.all.isEmpty, Date() < deadline { usleep(10_000) }
        #expect(received.all.first == payload)
    }

    @Test("Writing to a peer that has gone fails instead of raising SIGPIPE")
    func writeToClosedPeer() throws {
        let pair = try #require(SocketPair())
        Darwin.close(pair.second)
        defer { Darwin.close(pair.first) }
        #expect(!BridgeWire.writeLine(Data("hello".utf8), to: pair.first))
    }

    @Test("The limits are 64 KiB for a request and 2 MiB for a reply")
    func limits() {
        #expect(BridgeWire.maximumRequestLine == 65_536)
        #expect(BridgeWire.maximumReplyLine == 2_097_152)
    }
}
