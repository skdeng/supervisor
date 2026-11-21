import Foundation
import Testing

@testable import SuperVisor

/// Builders for the JSON an Instagram inbox page receives, with invented people and text.
private enum Inbox {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let baseSeconds = 1_789_000_000
    static let viewerFBID = "viewer-fbid"
    static let viewerID = "viewer-igid"

    static var maya: [String: Any] { user("maya.chen", fbid: "fbid-maya") }
    static var sam: [String: Any] { user("sam_ortiz", fbid: "fbid-sam") }
    static var pat: [String: Any] { user("pat.n", fbid: "fbid-pat") }

    /// Milliseconds since 1970 for `seconds` after the fixtures' base time.
    static func ms(_ seconds: Int) -> Int { (baseSeconds + seconds) * 1_000 }

    static func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(baseSeconds + seconds))
    }

    static func user(
        _ username: String?,
        fbid: Any,
        id: Any? = nil,
        fullName: String = "Pat Example"
    ) -> [String: Any] {
        var record: [String: Any] = ["interop_messaging_user_fbid": fbid, "full_name": fullName]
        record["id"] = id ?? "ig-\(fbid)"
        if let username { record["username"] = username }
        return record
    }

    static func message(
        _ id: Any,
        from sender: Any?,
        at seconds: Int,
        text: String? = nil,
        _ extra: [String: Any] = [:]
    ) -> [String: Any] {
        var node: [String: Any] = ["id": id, "timestamp_ms": ms(seconds), "tombstone_reason": NSNull()]
        if let sender { node["sender_fbid"] = sender }
        if let text { node["text_body"] = text }
        node.merge(extra) { _, new in new }
        return node
    }

    static func edges(_ nodes: [[String: Any]]) -> [String: Any] {
        ["edges": nodes.map { ["node": $0] }]
    }

    static func receipt(_ participant: Any, at seconds: Int) -> [String: Any] {
        ["participant_fbid": participant, "watermark_timestamp_ms": ms(seconds)]
    }

    static func chat(
        _ key: Any = "thread-1",
        fbid: Any? = nil,
        folder: String? = "PRIMARY",
        isGroup: Bool? = nil,
        title: String? = nil,
        activity: Int? = nil,
        markedUnread: Bool? = nil,
        users: [[String: Any]] = [],
        receipts: [[String: Any]]? = nil,
        messages: [[String: Any]]? = nil,
        withViewer: Bool = true
    ) -> [String: Any] {
        var record: [String: Any] = ["thread_key": key, "users": users]
        if let fbid { record["thread_fbid"] = fbid }
        if let folder { record["folder"] = folder }
        if let isGroup { record["is_group"] = isGroup }
        if let title { record["thread_title"] = title }
        if let activity { record["last_activity_timestamp_ms"] = ms(activity) }
        if let markedUnread { record["marked_as_unread"] = markedUnread }
        if let receipts { record["slide_read_receipts"] = receipts }
        if let messages { record["slide_messages"] = edges(messages) }
        if withViewer { record["viewer"] = ["id": viewerID, "interop_messaging_user_fbid": viewerFBID] }
        return record
    }

    /// A mailbox answer with each chat nested several levels deep, under keys the parser does
    /// not know.
    static func list(_ chats: [[String: Any]]) -> [String: Any] {
        [
            "data": [
                "fetch__SlideMailbox": [
                    "threads_by_folder": [
                        "edges": chats.map { ["node": ["as_ig_direct_thread": $0]] }
                    ]
                ]
            ],
            "extensions": ["is_final": true]
        ]
    }

    /// A message list that carries no thread key.
    static func detail(fbid: Any? = nil, _ nodes: [[String: Any]]) -> [String: Any] {
        var record: [String: Any] = ["slide_messages": edges(nodes)]
        if let fbid { record["thread_fbid"] = fbid }
        return ["data": ["thread_detail": ["thread": record]]]
    }

    static func nest(_ value: Any, levels: Int) -> Any {
        var result = value
        for _ in 0..<levels { result = ["wrapper": result] }
        return result
    }

    static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func parse(_ documents: [Any]) throws -> (threads: [DirectMessageThread], report: InstagramInboxParser.Report) {
        InstagramInboxParser.parse(try documents.map(json), now: now)
    }
}

@Suite("Instagram inbox parser")
struct InstagramInboxParserTests {
    // MARK: Lists and attribution

    @Test("A mailbox list yields chats newest first, with people attributed and messages oldest first")
    func listYieldsThreads() throws {
        let direct = Inbox.chat(
            "chat-a",
            activity: 400,
            users: [Inbox.maya],
            messages: [
                Inbox.message("m3", from: Inbox.viewerFBID, at: 300, text: "sounds good"),
                Inbox.message("m2", from: "fbid-maya", at: 200, text: "see you at 6"),
                Inbox.message("m1", from: "fbid-maya", at: 100, text: "dinner tonight?")
            ]
        )
        let group = Inbox.chat(
            "chat-b",
            isGroup: true,
            title: "Trail crew",
            activity: 500,
            users: [Inbox.maya, Inbox.sam, Inbox.pat],
            messages: [Inbox.message("b1", from: "fbid-sam", at: 450, text: "trailhead at 7")]
        )

        let result = try Inbox.parse([Inbox.list([direct, group])])

        #expect(result.threads.map(\.id) == ["chat-b", "chat-a"])
        let b = result.threads[0]
        #expect(b.participants == ["maya.chen", "sam_ortiz", "pat.n"])
        #expect(b.isGroup)
        #expect(b.title == "Trail crew")
        #expect(b.lastActivity == Inbox.date(500))
        #expect(b.messages.map(\.sender) == ["sam_ortiz"])

        let a = result.threads[1]
        #expect(a.participants == ["maya.chen"])
        #expect(!a.isGroup)
        #expect(a.title == nil)
        #expect(a.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(a.messages.map(\.isFromViewer) == [false, false, true])
        #expect(a.messages.map(\.sender) == ["maya.chen", "maya.chen", nil])
        #expect(a.messages.map(\.text) == ["dinner tonight?", "see you at 6", "sounds good"])
        #expect(a.messages.map(\.sent) == [Inbox.date(100), Inbox.date(200), Inbox.date(300)])

        #expect(result.report == InstagramInboxParser.Report(
            documents: 1, unreadableResponses: 0, threadsListed: 2,
            threadsOutsideFolders: 0, detailsUnmatched: 0, messages: 4
        ))
    }

    @Test("A chat seen without messages and again with them merges into one thread")
    func mergesRepeatedChat() throws {
        let first = Inbox.chat("chat-m", folder: nil, activity: 100, users: [Inbox.maya])
        let second = Inbox.chat(
            "chat-m", folder: "PRIMARY", title: "Brunch", activity: 900,
            messages: [
                Inbox.message("m1", from: "fbid-maya", at: 100, text: "pancakes?"),
                Inbox.message("m2", from: "fbid-maya", at: 200)
            ]
        )
        let third = Inbox.chat(
            "chat-m", folder: "GENERAL",
            messages: [
                Inbox.message("m2", from: "fbid-maya", at: 200, text: "second copy"),
                Inbox.message("m3", from: Inbox.viewerFBID, at: 300, text: "yes")
            ]
        )

        let result = try Inbox.parse([Inbox.list([first]), Inbox.list([second]), Inbox.list([third])])

        let thread = try #require(result.threads.first)
        #expect(result.threads.count == 1)
        #expect(thread.title == "Brunch")
        #expect(thread.lastActivity == Inbox.date(100))
        #expect(thread.participants == ["maya.chen"])
        #expect(thread.messages.map(\.id) == ["m1", "m2", "m3"])
        #expect(thread.messages[1].text == "second copy")
        #expect(result.report.threadsListed == 1)
        #expect(result.report.threadsOutsideFolders == 0)
        #expect(result.report.documents == 3)
    }

    @Test("A message list attaches by the thread id its own record carries", arguments: [true, false])
    func detailAttachesByOwnID(detailFirst: Bool) throws {
        let listed = Inbox.list([Inbox.chat("key-1", fbid: "fbid-thread-1", users: [Inbox.maya])])
        let detail = Inbox.detail(fbid: "fbid-thread-1", [
            Inbox.message("d2", from: "fbid-maya", at: 20, text: "two"),
            Inbox.message("d1", from: "fbid-maya", at: 10, text: "one")
        ])

        let result = try Inbox.parse(detailFirst ? [detail, listed] : [listed, detail])

        #expect(result.threads.map(\.id) == ["key-1"])
        #expect(result.threads[0].messages.map(\.id) == ["d1", "d2"])
        #expect(result.report.detailsUnmatched == 0)
    }

    @Test("A message list with no id of its own attaches by the thread id on its message nodes", arguments: [true, false])
    func detailAttachesByNodeThreadID(detailFirst: Bool) throws {
        let listed = Inbox.list([Inbox.chat("key-2", fbid: "fbid-thread-2", users: [Inbox.maya])])
        let detail = Inbox.detail([
            Inbox.message("d1", from: "fbid-maya", at: 10, text: "one"),
            Inbox.message("d2", from: "fbid-maya", at: 20, text: "two", ["thread_fbid": "fbid-thread-2"]),
            Inbox.message("d3", from: "fbid-maya", at: 30, text: "three", ["thread_fbid": "something-else"])
        ])

        let result = try Inbox.parse(detailFirst ? [detail, listed] : [listed, detail])

        #expect(result.threads.map(\.id) == ["key-2"])
        #expect(result.threads[0].messages.map(\.id) == ["d1", "d2", "d3"])
        #expect(result.report.detailsUnmatched == 0)
    }

    @Test("A message list attaches to the chat whose thread key equals its id")
    func detailAttachesByThreadKey() throws {
        let listed = Inbox.list([Inbox.chat("key-3", users: [Inbox.maya])])
        let detail = Inbox.detail([
            Inbox.message("d1", from: "fbid-maya", at: 10, text: "one", ["thread_fbid": "key-3"])
        ])

        let result = try Inbox.parse([listed, detail])

        #expect(result.threads[0].messages.map(\.id) == ["d1"])
        #expect(result.report.detailsUnmatched == 0)
    }

    @Test("A message list matching no chat is dropped and counted")
    func unmatchedDetailIsDropped() throws {
        let listed = Inbox.list([Inbox.chat("key-4", fbid: "fbid-thread-4")])
        let stray = Inbox.detail(fbid: "fbid-unknown", [Inbox.message("s1", from: "fbid-maya", at: 10, text: "lost")])
        let anonymous = Inbox.detail([Inbox.message("s2", from: "fbid-maya", at: 20, text: "lost")])

        let result = try Inbox.parse([listed, stray, anonymous])

        #expect(result.threads[0].messages.isEmpty)
        #expect(result.report.detailsUnmatched == 2)
        #expect(result.report.messages == 0)
    }

    @Test("Chats outside the accepted folders are dropped and counted, and their message lists go unmatched")
    func foldersFilterChats() throws {
        let chats = [
            Inbox.chat("pending", fbid: "fbid-pending", folder: "PENDING"),
            Inbox.chat("nofolder", fbid: "fbid-nofolder", folder: nil),
            Inbox.chat("lower", fbid: "fbid-lower", folder: "primary"),
            Inbox.chat("general", fbid: "fbid-general", folder: "GENERAL")
        ]
        let detail = Inbox.detail(fbid: "fbid-pending", [Inbox.message("p1", from: "fbid-maya", at: 10, text: "hi")])

        let result = try Inbox.parse([Inbox.list(chats), detail])

        #expect(Set(result.threads.map(\.id)) == ["lower", "general"])
        #expect(result.report.threadsListed == 4)
        #expect(result.report.threadsOutsideFolders == 2)
        #expect(result.report.detailsUnmatched == 1)
    }

    // MARK: Response text

    @Test("A guard prefix is stripped and newline-separated documents each count; garbage is unreadable")
    func responseTexts() throws {
        let chat = Inbox.chat("chat-p", fbid: "fbid-p", users: [Inbox.maya])
        let detail = Inbox.detail(fbid: "fbid-p", [Inbox.message("p1", from: "fbid-maya", at: 10, text: "hello")])
        let other = Inbox.chat("chat-q", users: [Inbox.sam])

        let listText = try Inbox.json(Inbox.list([chat]))
        let streamed = [
            try Inbox.json(["data": ["noise": 1]]),
            "",
            "  for (;;);  " + (try Inbox.json(detail)),
            (try Inbox.json(Inbox.list([other]))) + "\r"
        ].joined(separator: "\n")
        let responses = ["for (;;);" + listText, streamed, "<html>not json</html>", "", "   "]

        let result = InstagramInboxParser.parse(responses, now: Inbox.now)

        #expect(Set(result.threads.map(\.id)) == ["chat-p", "chat-q"])
        #expect(result.threads.first { $0.id == "chat-p" }?.messages.map(\.id) == ["p1"])
        #expect(result.report.documents == 4)
        #expect(result.report.unreadableResponses == 3)
    }

    @Test("Text that is not a JSON document is unreadable and nothing else")
    func nonJSONInput() {
        let responses = ["", "null", "123", "\"text\"", "{", "[1,2", "for (;;);", "\u{0}\u{1}", "{\"a\":1}x"]

        let result = InstagramInboxParser.parse(responses, now: Inbox.now)

        #expect(result.threads.isEmpty)
        #expect(result.report.unreadableResponses == responses.count)
        #expect(result.report.documents == 0)
    }

    @Test("Empty documents parse and hold nothing")
    func emptyDocuments() {
        let result = InstagramInboxParser.parse(["{}", "[]"], now: Inbox.now)

        #expect(result.threads.isEmpty)
        #expect(result.report.documents == 2)
        #expect(result.report.unreadableResponses == 0)
    }

    // MARK: Values

    @Test("Ids and timestamps are accepted as numbers and as strings")
    func numbersAndStrings() throws {
        let bigID = 9_007_199_254_740_993
        let chat: [String: Any] = [
            "thread_key": bigID,
            "thread_fbid": 8_800_000_001,
            "folder": "PRIMARY",
            "last_activity_timestamp_ms": String(Inbox.ms(500)),
            "viewer": ["id": 11, "interop_messaging_user_fbid": 12],
            "users": [Inbox.user("maya.chen", fbid: 7_001, id: 7_002)],
            "slide_read_receipts": [["participant_fbid": 12, "watermark_timestamp_ms": String(Inbox.ms(150))]],
            "slide_messages": Inbox.edges([
                ["id": 1_001, "sender_fbid": 7_001, "timestamp_ms": String(Inbox.ms(200)), "text_body": "numbers"],
                ["message_id": "mid.abc:1", "sender_fbid": "12", "timestamp_ms": Inbox.ms(100), "text_body": "strings"],
                ["id": "m-3", "sender_fbid": 7_002, "timestamp_ms": " \(Inbox.ms(300)) ", "text_body": "padded"]
            ])
        ]

        let result = try Inbox.parse([Inbox.list([chat])])

        let thread = try #require(result.threads.first)
        #expect(thread.id == "9007199254740993")
        #expect(thread.lastActivity == Inbox.date(500))
        #expect(thread.participants == ["maya.chen"])
        #expect(thread.messages.map(\.id) == ["mid.abc:1", "1001", "m-3"])
        #expect(thread.messages.map(\.isFromViewer) == [true, false, false])
        #expect(thread.messages.map(\.sender) == [nil, "maya.chen", "maya.chen"])
        #expect(thread.isUnread == true)
    }

    @Test("Booleans and floats are not ids, and the numbers 0 and 1 are not booleans")
    func typeStrictness() throws {
        let boolKey: [String: Any] = ["thread_key": true, "folder": "PRIMARY"]
        let floatKey: [String: Any] = ["thread_key": 1.5, "folder": "PRIMARY"]
        let numericFlag = Inbox.chat("flag-1", isGroup: nil, users: [Inbox.maya])
            .merging(["is_group": 1, "marked_as_unread": 1]) { _, new in new }
        let explicitFalse = Inbox.chat("flag-2", isGroup: false, users: [Inbox.maya, Inbox.sam, Inbox.pat])

        let result = try Inbox.parse([Inbox.list([boolKey, floatKey, numericFlag, explicitFalse])])

        #expect(Set(result.threads.map(\.id)) == ["flag-1", "flag-2"])
        let numeric = try #require(result.threads.first { $0.id == "flag-1" })
        #expect(!numeric.isGroup)
        #expect(numeric.isUnread == nil)
        let explicit = try #require(result.threads.first { $0.id == "flag-2" })
        #expect(!explicit.isGroup)
        #expect(result.report.threadsListed == 2)
    }

    @Test("A chat or message whose id is unacceptable is skipped")
    func unacceptableIDs() throws {
        let long = String(repeating: "k", count: 129)
        let edgeOfLimit = String(repeating: "k", count: 128)
        let chats = [
            Inbox.chat("has space"),
            Inbox.chat(long),
            Inbox.chat(edgeOfLimit),
            Inbox.chat("ok:1.2=_-", messages: [
                Inbox.message("mid/1", from: "fbid-maya", at: 10, text: "slash"),
                Inbox.message(long, from: "fbid-maya", at: 20, text: "long"),
                Inbox.message("good-1", from: "fbid maya", at: 30, text: "odd sender"),
                Inbox.message("", from: "fbid-maya", at: 40, text: "empty"),
                Inbox.message("good-2", from: Inbox.viewerFBID, at: 50, text: "kept"),
                Inbox.message("mid.$cAAB-1", from: Inbox.viewerFBID, at: 60, text: "dollar")
            ])
        ]

        let result = try Inbox.parse([Inbox.list(chats)])

        #expect(Set(result.threads.map(\.id)) == [edgeOfLimit, "ok:1.2=_-"])
        let thread = try #require(result.threads.first { $0.id == "ok:1.2=_-" })
        #expect(thread.messages.map(\.id) == ["good-1", "good-2", "mid.$cAAB-1"])
        #expect(thread.messages.map(\.isFromViewer) == [false, true, true])
        #expect(result.report.threadsListed == 2)
    }

    @Test("An unsent message is absent, an empty tombstone reason is not unsent, and a message unsent in any answer is dropped")
    func unsentMessages() throws {
        let chat = Inbox.chat("chat-u", messages: [
            Inbox.message("live", from: "fbid-maya", at: 10, text: "kept"),
            Inbox.message("gone", from: "fbid-maya", at: 20, text: "unsent", ["tombstone_reason": "DELETED"]),
            Inbox.message("blank-reason", from: "fbid-maya", at: 30, text: "kept too", ["tombstone_reason": ""]),
            Inbox.message("later-unsent", from: "fbid-maya", at: 40, text: "still shown here")
        ])
        let laterAnswer = Inbox.detail(fbid: "x", [
            Inbox.message("later-unsent", from: "fbid-maya", at: 40, ["tombstone_reason": "UNSENT"])
        ])

        let result = try Inbox.parse([Inbox.list([chat]), laterAnswer])

        #expect(result.threads[0].messages.map(\.id) == ["live", "blank-reason"])
    }

    @Test("A message with an unusable timestamp is skipped; the window runs from 2010 through a day past now")
    func timestampWindow() throws {
        let nowMilliseconds = Int(Inbox.now.timeIntervalSince1970 * 1_000)
        let day = 86_400_000
        let nodes: [[String: Any]] = [
            ["id": "edge-low", "timestamp_ms": 1_262_304_000_000, "text_body": "2010-01-01"],
            ["id": "before", "timestamp_ms": 1_262_303_999_999, "text_body": "too early"],
            ["id": "zero", "timestamp_ms": 0, "text_body": "zero"],
            ["id": "negative", "timestamp_ms": -5_000, "text_body": "negative"],
            ["id": "soon", "timestamp_ms": nowMilliseconds + 3_600_000, "text_body": "an hour ahead"],
            ["id": "edge-high", "timestamp_ms": nowMilliseconds + day, "text_body": "a day ahead"],
            ["id": "far", "timestamp_ms": nowMilliseconds + day + 1_000, "text_body": "too late"],
            ["id": "seconds", "timestamp_ms": 1_789_000_000, "text_body": "seconds, not ms"],
            ["id": "words", "timestamp_ms": "yesterday", "text_body": "words"],
            ["id": "boolean", "timestamp_ms": true, "text_body": "boolean"],
            ["id": "null", "timestamp_ms": NSNull(), "text_body": "null"],
            ["id": "missing", "text_body": "missing"],
            ["timestamp_ms": Inbox.ms(10), "text_body": "no id"]
        ]
        let chat = Inbox.chat("chat-t", messages: nodes)

        let result = try Inbox.parse([Inbox.list([chat])])

        #expect(result.threads[0].messages.map(\.id) == ["edge-low", "soon", "edge-high"])
    }

    // MARK: People

    @Test("A user name that is not 1 to 30 ASCII letters, digits, periods, or underscores never appears")
    func invalidUserNames() throws {
        let thirty = String(repeating: "b", count: 30)
        let users = [
            Inbox.user("bad name", fbid: "f1"),
            Inbox.user(String(repeating: "a", count: 31), fbid: "f2"),
            Inbox.user("zo\u{EB}", fbid: "f3"),
            Inbox.user("ok_name.1", fbid: "f4"),
            Inbox.user(thirty, fbid: "f5"),
            Inbox.user("", fbid: "f6"),
            Inbox.user(nil, fbid: "f7"),
            Inbox.user("tab\tname", fbid: "f8"),
            Inbox.user("line\nname", fbid: "f9")
        ]
        let senderDict: (String, Any) -> [String: Any] = { name, fbid in
            ["sender": ["id": "x", "name": "Display", "user_dict": ["username": name, "interop_messaging_user_fbid": fbid]]]
        }
        let chat = Inbox.chat("chat-n", users: users, messages: [
            Inbox.message("n1", from: "f1", at: 10, text: "a", senderDict("has space", "f1")),
            Inbox.message("n2", from: "f4", at: 20, text: "b"),
            Inbox.message("n3", from: "f3", at: 30, text: "c"),
            Inbox.message("n4", from: "f9", at: 40, text: "d", senderDict("line\nname", "f9")),
            Inbox.message("n5", from: "f10", at: 50, text: "e", senderDict("zo\u{EB}", "f10"))
        ])

        let result = try Inbox.parse([Inbox.list([chat])])

        let thread = try #require(result.threads.first)
        #expect(thread.participants == ["ok_name.1", thirty])
        #expect(thread.messages.map(\.sender) == [nil, "ok_name.1", nil, nil, nil])
    }

    @Test("Participants leave out the viewer, repeat no name, and stop at the limit")
    func participantsRules() throws {
        let viewerAsUser = Inbox.user("me.myself", fbid: Inbox.viewerFBID)
        let viewerByID = Inbox.user("me.again", fbid: "other-fbid", id: Inbox.viewerID)
        let many = (0..<25).map { Inbox.user("user\($0)", fbid: "fbid-\($0)") }
        let crowd = Inbox.chat("crowd", users: [viewerAsUser, viewerByID, Inbox.maya, Inbox.maya] + many)
        let pair = Inbox.chat("pair", users: [viewerAsUser, Inbox.maya])
        let trio = Inbox.chat("trio", users: [Inbox.maya, Inbox.sam])

        let result = try Inbox.parse([Inbox.list([crowd, pair, trio])])

        let crowdThread = try #require(result.threads.first { $0.id == "crowd" })
        #expect(crowdThread.participants.count == DirectMessageThread.maximumParticipants)
        #expect(Array(crowdThread.participants.prefix(3)) == ["maya.chen", "user0", "user1"])
        #expect(!crowdThread.participants.contains("me.myself"))
        #expect(!crowdThread.participants.contains("me.again"))
        #expect(crowdThread.isGroup)
        let pairThread = try #require(result.threads.first { $0.id == "pair" })
        #expect(pairThread.participants == ["maya.chen"])
        #expect(!pairThread.isGroup)
        let trioThread = try #require(result.threads.first { $0.id == "trio" })
        #expect(trioThread.isGroup)
    }

    @Test("A sender's name learned from a message list in one answer names that sender's messages everywhere")
    func userNamesAcrossDocuments() throws {
        let sender: [String: Any] = [
            "id": "ig-cam", "name": "Cam Lee",
            "user_dict": ["username": "cam_lee", "full_name": "Cam Lee", "interop_messaging_user_fbid": "fbid-cam"]
        ]
        let listed = Inbox.list([Inbox.chat("chat-c", fbid: "fbid-chat-c", users: [Inbox.maya])])
        let detail = Inbox.detail(fbid: "fbid-chat-c", [
            Inbox.message("c1", from: "fbid-cam", at: 10, text: "hi", ["sender": sender]),
            Inbox.message("c2", from: "fbid-cam", at: 20, text: "again"),
            Inbox.message("c3", from: "ig-cam", at: 30, text: "by the other id")
        ])

        let result = try Inbox.parse([listed, detail])

        let thread = try #require(result.threads.first)
        #expect(thread.messages.map(\.sender) == ["cam_lee", "cam_lee", "cam_lee"])
        #expect(thread.participants == ["maya.chen"])
    }

    @Test("The viewer's ids from any chat record decide which messages are the viewer's")
    func viewerAcrossRecords() throws {
        let withoutViewer = Inbox.chat("chat-v1", users: [Inbox.maya], messages: [
            Inbox.message("v1", from: Inbox.viewerFBID, at: 10, text: "mine"),
            Inbox.message("v2", from: Inbox.viewerID, at: 20, text: "mine by the other id"),
            Inbox.message("v3", from: "fbid-maya", at: 30, text: "theirs"),
            Inbox.message("v4", from: nil, at: 40, text: "no sender")
        ], withViewer: false)
        let withViewer = Inbox.chat("chat-v2")

        let result = try Inbox.parse([Inbox.list([withoutViewer]), Inbox.list([withViewer])])

        let thread = try #require(result.threads.first { $0.id == "chat-v1" })
        #expect(thread.messages.map(\.isFromViewer) == [true, true, false, false])
    }

    // MARK: Message content

    @Test("Control characters and bidirectional overrides are removed, and text, shared titles, and chat titles are cut")
    func cleansText() throws {
        let hostileTitle = "Cr\u{202E}ew\u{0000}\u{1B}"
        let chat = Inbox.chat("chat-s", title: hostileTitle, messages: [
            Inbox.message("s1", from: "fbid-maya", at: 10, text: "hi\u{0007}\u{202E}there\u{1B}[31m"),
            Inbox.message("s2", from: "fbid-maya", at: 20, text: String(repeating: "x", count: 1_500)),
            Inbox.message("s3", from: "fbid-maya", at: 30, text: "line one\n\n\n\nline   two"),
            Inbox.message("s4", from: "fbid-maya", at: 40, [
                "content": ["xma": ["header_title_text": String(repeating: "s", count: 300)]]
            ]),
            Inbox.message("s5", from: "fbid-maya", at: 50, text: "\u{202E}\u{200B}  ")
        ])
        let long = Inbox.chat("chat-l", title: String(repeating: "t", count: 100))

        let result = try Inbox.parse([Inbox.list([chat, long])])

        let thread = try #require(result.threads.first { $0.id == "chat-s" })
        #expect(thread.title == "Crew")
        #expect(thread.messages.map(\.text) == [
            "hithere[31m", String(repeating: "x", count: DirectMessage.textLimit), "line one\n\nline two", "", ""
        ])
        let shared = try #require(thread.messages[3].shared)
        #expect(shared.count == DirectMessage.sharedLimit)
        #expect(shared.hasSuffix("…"))
        #expect(thread.messages[4].shared == nil)
        let longTitle = try #require(result.threads.first { $0.id == "chat-l" }?.title)
        #expect(longTitle.count == DirectMessageThread.titleLimit)
        #expect(longTitle.hasSuffix("…"))

        let everything = thread.messages.map(\.text).joined() + (thread.title ?? "")
        #expect(!everything.unicodeScalars.contains { $0.value == 0x202E || $0.value < 0x20 && $0.value != 0x0A })
    }

    @Test("Text and shared titles are read from each field a message can carry them in")
    func contentFields() throws {
        let chat = Inbox.chat("chat-f", messages: [
            Inbox.message("f1", from: "fbid-maya", at: 10, ["content": ["text_body": "from content"]]),
            Inbox.message("f2", from: "fbid-maya", at: 20, text: "top wins", ["content": ["text_body": "from content"]]),
            Inbox.message("f3", from: "fbid-maya", at: 30, [
                "content": ["xma": ["header_title_text": "Reel by a chef", "xmaHeaderTitle": "Other"], "xma_text_body": "Body"]
            ]),
            Inbox.message("f4", from: "fbid-maya", at: 40, ["content": ["xma": ["xmaHeaderTitle": "Post title"]]]),
            Inbox.message("f5", from: "fbid-maya", at: 50, ["content": ["xma_text_body": "Link text"]]),
            Inbox.message("f6", from: "fbid-maya", at: 60, ["content": ["xma": ["header_title_text": "   "], "xma_text_body": "Fallback"]]),
            Inbox.message("f7", from: "fbid-maya", at: 70)
        ])

        let result = try Inbox.parse([Inbox.list([chat])])

        let messages = result.threads[0].messages
        #expect(messages.map(\.text) == ["from content", "top wins", "", "", "", "", ""])
        #expect(messages.map(\.shared) == [nil, nil, "Reel by a chef", "Post title", "Link text", "Fallback", nil])
        #expect(messages.count == 7)
    }

    // MARK: Unread

    @Test("A chat is unread when marked, when a newer message from someone else follows the viewer's watermark, and unknown without one")
    func unreadOutcomes() throws {
        let v = Inbox.viewerFBID
        func chat(_ key: String, marked: Bool? = nil, receipts: [[String: Any]]? = nil, messages: [[String: Any]]) -> [String: Any] {
            Inbox.chat(key, markedUnread: marked, users: [Inbox.maya], receipts: receipts, messages: messages)
        }
        let chats = [
            chat("marked", marked: true, receipts: [Inbox.receipt(v, at: 900)], messages: [Inbox.message("a", from: v, at: 100)]),
            chat("newer", receipts: [Inbox.receipt(v, at: 150)], messages: [Inbox.message("b", from: "fbid-maya", at: 200)]),
            chat("read", receipts: [Inbox.receipt(v, at: 300)], messages: [
                Inbox.message("c1", from: "fbid-maya", at: 200), Inbox.message("c2", from: v, at: 250)
            ]),
            chat("none", messages: [Inbox.message("d", from: "fbid-maya", at: 200)]),
            chat("explicit-false", marked: false, messages: [Inbox.message("e", from: "fbid-maya", at: 200)]),
            chat("own-only", receipts: [Inbox.receipt(v, at: 150)], messages: [Inbox.message("f", from: v, at: 200)]),
            chat("others-receipt", receipts: [Inbox.receipt("fbid-maya", at: 150)], messages: [Inbox.message("g", from: "fbid-maya", at: 200)]),
            chat("false-covered", marked: false, receipts: [Inbox.receipt(v, at: 300)], messages: [Inbox.message("h", from: "fbid-maya", at: 200)]),
            chat("by-igid", receipts: [Inbox.receipt(Inbox.viewerID, at: 150)], messages: [Inbox.message("i", from: "fbid-maya", at: 200)]),
            chat("equal", receipts: [Inbox.receipt(v, at: 200)], messages: [Inbox.message("j", from: "fbid-maya", at: 200)]),
            chat("bad-watermark", receipts: [["participant_fbid": v, "watermark_timestamp_ms": 0]], messages: [Inbox.message("k", from: "fbid-maya", at: 200)])
        ]

        let result = try Inbox.parse([Inbox.list(chats)])

        func unread(_ key: String) -> Bool?? {
            result.threads.first { $0.id == key }.map(\.isUnread)
        }
        #expect(unread("marked") == .some(true))
        #expect(unread("newer") == .some(true))
        #expect(unread("read") == .some(false))
        #expect(unread("none") == .some(nil))
        #expect(unread("explicit-false") == .some(nil))
        #expect(unread("own-only") == .some(false))
        #expect(unread("others-receipt") == .some(nil))
        #expect(unread("false-covered") == .some(false))
        #expect(unread("by-igid") == .some(true))
        #expect(unread("equal") == .some(false))
        #expect(unread("bad-watermark") == .some(nil))
    }

    // MARK: Caps

    @Test("At most 50 chats are returned, newest activity first")
    func threadCap() throws {
        let chats = (0..<60).map { (index: Int) -> [String: Any] in
            Inbox.chat("t-" + String(index), activity: index)
        }

        let result = try Inbox.parse([Inbox.list(chats)])

        #expect(result.threads.count == InstagramInboxParser.maximumThreads)
        #expect(result.threads.map(\.id) == (10..<60).reversed().map { "t-\($0)" })
        #expect(result.report.threadsListed == 60)
    }

    @Test("A chat keeps its 50 newest messages, oldest first")
    func messageCap() throws {
        let nodes = (0..<70).reversed().map { Inbox.message("m-\($0)", from: "fbid-maya", at: $0 * 10, text: "message \($0)") }
        let chat = Inbox.chat("chat-big", messages: nodes)

        let result = try Inbox.parse([Inbox.list([chat])])

        let messages = result.threads[0].messages
        #expect(messages.map(\.id) == (20..<70).map { "m-\($0)" })
        #expect(result.report.messages == InstagramInboxParser.maximumMessagesPerThread)
    }

    @Test("A chat with no activity time is ordered by its newest message and after chats with later ones")
    func recencyOrdering() throws {
        let chats = [
            Inbox.chat("quiet"),
            Inbox.chat("by-message", messages: [Inbox.message("a", from: "fbid-maya", at: 700)]),
            Inbox.chat("by-activity", activity: 600, messages: [Inbox.message("b", from: "fbid-maya", at: 800)])
        ]

        let result = try Inbox.parse([Inbox.list(chats)])

        #expect(result.threads.map(\.id) == ["by-message", "by-activity", "quiet"])
    }

    // MARK: Hostile structure

    @Test("Records are found down to the depth cap and not below it, and nothing crashes on deeper input")
    func depthCap() throws {
        let chat = Inbox.chat("chat-d", users: [Inbox.maya])
        let atCap = Inbox.nest(chat, levels: InstagramInboxParser.maximumDepth)
        let belowCap = Inbox.nest(chat, levels: InstagramInboxParser.maximumDepth + 1)
        let deep = Inbox.nest(chat, levels: 200)

        #expect(try Inbox.parse([atCap]).threads.map(\.id) == ["chat-d"])
        #expect(try Inbox.parse([belowCap]).threads.isEmpty)
        let deepResult = try Inbox.parse([deep])
        #expect(deepResult.threads.isEmpty)
        #expect(deepResult.report.documents == 1)

        let hugeText = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        let hugeResult = InstagramInboxParser.parse([hugeText], now: Inbox.now)
        #expect(hugeResult.threads.isEmpty)
    }

    @Test("Walking stops quietly once a parse has visited its node budget")
    func nodeBudget() throws {
        let chat = try Inbox.json(Inbox.list([Inbox.chat("chat-z", users: [Inbox.maya])]))
        func document(filler: Int) -> String {
            let zeros = Array(repeating: "0", count: filler).joined(separator: ",")
            return "{\"filler\":[\(zeros)],\"z\":\(chat)}"
        }

        let within = InstagramInboxParser.parse([document(filler: 1_000)], now: Inbox.now)
        let beyond = InstagramInboxParser.parse([document(filler: InstagramInboxParser.maximumVisitedNodes + 50_000)], now: Inbox.now)

        #expect(within.threads.map(\.id) == ["chat-z"])
        #expect(beyond.threads.isEmpty)
        #expect(beyond.report.documents == 1)
    }

    @Test("Records are never read inside a chat's own message list, and odd shapes are ignored")
    func oddShapes() throws {
        let inner = Inbox.chat("inner-chat")
        let chat = Inbox.chat("outer", messages: [
            Inbox.message("o1", from: "fbid-maya", at: 10, text: "hi", ["nested": inner])
        ])
        let odd: [String: Any] = [
            "thread_key": NSNull(),
            "slide_messages": "not a dictionary",
            "users": "nope",
            "list": [1, "two", NSNull(), [String: Any](), [[String: Any]]()],
            "another": ["slide_messages": ["edges": "not an array"]]
        ]
        let weirdFields = Inbox.chat("weird", users: [], receipts: nil, messages: nil)
            .merging([
                "users": [1, "x", ["username": 5], NSNull()],
                "slide_read_receipts": ["x", ["participant_fbid": [1]]],
                "slide_messages": ["edges": [1, ["node": 2], ["node": ["id": ["a"]]], NSNull()]],
                "viewer": "nobody",
                "thread_title": 7
            ]) { _, new in new }

        let result = try Inbox.parse([Inbox.list([chat, weirdFields]), odd])

        #expect(Set(result.threads.map(\.id)) == ["outer", "weird"])
        #expect(result.threads.first { $0.id == "outer" }?.messages.map(\.id) == ["o1"])
        let weird = try #require(result.threads.first { $0.id == "weird" })
        #expect(weird.participants.isEmpty)
        #expect(weird.messages.isEmpty)
        #expect(weird.title == nil)
        #expect(result.report.detailsUnmatched == 0)
    }

    @Test("A parse of the same input returns the same threads every time")
    func repeatable() throws {
        let chats = (0..<30).map { index in
            Inbox.chat(
                "t-\(index)", activity: index % 7, users: [Inbox.maya, Inbox.sam],
                messages: (0..<5).map { Inbox.message("m-\(index)-\($0)", from: "fbid-sam", at: $0, text: "n\($0)") }
            )
        }
        let documents = [Inbox.list(chats)]

        let first = try Inbox.parse(documents)
        #expect(first.threads.count == 30)
        #expect(first.report.messages == 150)
        for _ in 0..<5 {
            let again = try Inbox.parse(documents)
            #expect(again.threads == first.threads)
            #expect(again.report == first.report)
        }
    }
}
