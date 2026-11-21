import Foundation
import Testing
import WebKit

@testable import SuperVisor

/// A stand-in source on a simulated host. Its watched address is a `data:` URL, so the inbox
/// page's requests are answered inside the web view.
@MainActor
enum TestMessageSource {
    nonisolated static let host = "chat.example.com"
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let source = DirectMessageSource(
        id: "test-source",
        name: "Chatter",
        hosts: [host],
        inboxURL: URL(string: "https://\(host)/direct/inbox/")!,
        signInURL: URL(string: "https://\(host)/accounts/login/")!,
        signInPathPrefixes: ["/accounts/login", "/challenge"],
        capture: PageCapture(
            host: host,
            urlPattern: "^data:application/json",
            markers: ["slide_messages", "thread_key"],
            operationField: "op",
            sentOperationSuffix: "Query",
            blocksSockets: true
        ),
        blockedRequests: "[]",
        storeIdentifier: UUID(),
        parse: { responses, now in InstagramInboxParser.parse(responses, now: now) }
    )

    /// One chat in the shape the inbox's list responses carry, with a message from the other
    /// person a minute before `now` for each text.
    static func chat(_ key: String, with username: String, texts: [String], folder: String = "PRIMARY") -> [String: Any] {
        let base = Int(now.timeIntervalSince1970 * 1000) - 600_000
        let messages = texts.enumerated().map { index, text -> [String: Any] in
            ["node": [
                "id": "\(key)-m\(index)",
                "sender_fbid": "fb-\(username)",
                "timestamp_ms": String(base + index * 1000),
                "text_body": text,
            ]]
        }
        return [
            "thread_key": key,
            "folder": folder,
            "viewer": ["interop_messaging_user_fbid": "fb-me"],
            "users": [["interop_messaging_user_fbid": "fb-\(username)", "username": username]],
            "last_activity_timestamp_ms": String(base + texts.count * 1000),
            "slide_messages": ["edges": messages],
        ]
    }

    /// A list response holding `chats`, as text.
    static func listResponse(_ chats: [[String: Any]]) -> String {
        let document: [String: Any] = ["data": ["mailbox": ["edges": chats.map { ["node": $0] }]]]
        let data = try! JSONSerialization.data(withJSONObject: document)
        return String(decoding: data, as: UTF8.self)
    }

    /// An inbox page that fetches `first` as it loads and each of `later` in turn as its chat
    /// list is scrolled.
    static func inboxPage(first: String?, later: [String] = [], extra: String = "") -> String {
        func literal(_ text: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [text])
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        let rows = (0..<30).map { "<div role=\"button\" style=\"height:60px\">chat \($0)</div>" }.joined()
        let body = "<div id=\"list\" style=\"height:300px;overflow-y:auto\">\(rows)</div>\(extra)"
        let script = """
            const load = (text) => {
              const xhr = new XMLHttpRequest();
              xhr.open('GET', 'data:application/json,' + encodeURIComponent(text));
              xhr.send();
            };
            const later = [\(later.map(literal).joined(separator: ","))];
            \(first.map { "load(\(literal($0)));" } ?? "")
            document.getElementById('list').addEventListener('scroll', () => {
              const next = later.shift();
              if (next !== undefined) load(next);
            });
            """
        return TestPages.page("Inbox", body, script: script)
    }

    static let pacing = DirectMessageSync.Pacing(
        scrollPause: .milliseconds(150),
        maximumRounds: 10,
        quietRounds: 2,
        timeout: .seconds(40)
    )

    static func sync(_ site: TestSite, pacing: DirectMessageSync.Pacing = pacing) async -> DirectMessageSync.Result {
        await DirectMessageSync.run(
            source: source,
            dataStore: .nonPersistent(),
            contentRules: [],
            pages: site.answer,
            settling: .fast,
            pacing: pacing,
            now: { now }
        )
    }
}

@Suite("Direct message sync", .serialized)
@MainActor
struct DirectMessageSyncTests {
    private typealias Source = TestMessageSource

    @Test(
        "The chats the inbox fetches as it loads and as its list is scrolled become the snapshot",
        .timeLimit(.minutes(2))
    )
    func readsInbox() async throws {
        let site = TestSite()
        let first = Source.listResponse([
            Source.chat("t1", with: "maya", texts: ["hello", "are you free friday?"]),
            Source.chat("t2", with: "omar", texts: ["sent the invoice"]),
        ])
        let second = Source.listResponse([Source.chat("t3", with: "lin", texts: ["thanks!"])])
        site.route("/direct/inbox", host: Source.host, page: Source.inboxPage(first: first, later: [second]))

        let result = await Source.sync(site)

        #expect(result.outcome == .synced)
        let snapshot = try #require(result.snapshot)
        #expect(snapshot.source == "test-source")
        #expect(snapshot.syncedAt == Source.now)
        #expect(Set(snapshot.threads.map(\.id)) == ["t1", "t2", "t3"])
        let maya = try #require(snapshot.threads.first { $0.id == "t1" })
        #expect(maya.participants == ["maya"])
        #expect(maya.messages.map(\.text) == ["hello", "are you free friday?"])
        #expect(maya.messages.allSatisfy { !$0.isFromViewer && $0.sender == "maya" })
        #expect(result.report.foundScroller)
        #expect(result.report.responses == 2)
        #expect(result.report.threadsWithMessages == 3)
        #expect(result.report.pagePath == "/direct/inbox/")
    }

    @Test("A chat in the requests folder is left out of the snapshot", .timeLimit(.minutes(2)))
    func leavesOutRequests() async throws {
        let site = TestSite()
        let response = Source.listResponse([
            Source.chat("t1", with: "maya", texts: ["hello"]),
            Source.chat("t9", with: "stranger", texts: ["click this"], folder: "PENDING"),
        ])
        site.route("/direct/inbox", host: Source.host, page: Source.inboxPage(first: response))

        let result = await Source.sync(site)

        #expect(result.snapshot?.threads.map(\.id) == ["t1"])
        #expect(result.report.parse.threadsOutsideFolders == 1)
    }

    @Test("An inbox that sends the browser to the sign-in page needs the person", .timeLimit(.minutes(2)))
    func redirectedToSignIn() async {
        let site = TestSite()
        site.route("/direct/inbox", host: Source.host, page: TestPages.redirect(to: "/accounts/login/?next=/direct/inbox/"))
        site.route("/accounts/login", host: Source.host, page: TestPages.page("Log in", "<p>Log in to continue</p>"))

        let result = await Source.sync(site)

        #expect(result.outcome == .needsSignIn)
        #expect(result.snapshot == nil)
        #expect(result.report.pagePath == "/accounts/login/")
    }

    @Test("An inbox address that shows a password field needs the person", .timeLimit(.minutes(2)))
    func signInFormInPlace() async {
        let site = TestSite()
        let form = "<form><input name=\"username\"><input type=\"password\" name=\"password\"></form>"
        site.route("/direct/inbox", host: Source.host, page: TestPages.page("Log in", form))

        let result = await Source.sync(site)

        #expect(result.outcome == .needsSignIn)
    }

    @Test("An inbox that does not load is unavailable, which says nothing about the sign-in", .timeLimit(.minutes(2)))
    func pageDoesNotLoad() async {
        let result = await Source.sync(TestSite())

        #expect(result.outcome == .pageUnavailable)
        #expect(result.snapshot == nil)
    }

    @Test("An inbox that leaves the source's hosts is unavailable", .timeLimit(.minutes(2)))
    func leavesHosts() async {
        let site = TestSite()
        site.route("/direct/inbox", host: Source.host, page: TestPages.page(
            "Moving", "<p>moving</p>", script: "location.replace('https://elsewhere.example.com/')"
        ))

        let result = await Source.sync(site)

        #expect(result.outcome == .pageUnavailable)
    }

    @Test("An inbox that loads signed in and fetches no chat captures nothing", .timeLimit(.minutes(2)))
    func nothingCaptured() async {
        let site = TestSite()
        site.route("/direct/inbox", host: Source.host, page: Source.inboxPage(first: nil))

        let result = await Source.sync(site)

        #expect(result.outcome == .nothingCaptured)
        #expect(result.snapshot == nil)
        #expect(result.report.scrollRounds == 2)
    }

    @Test("A sync cut off by its time limit while still scrolling uses what it had read", .timeLimit(.minutes(2)))
    func timeLimitKeepsWhatWasRead() async throws {
        let site = TestSite()
        let first = Source.listResponse([Source.chat("t1", with: "maya", texts: ["hello"])])
        site.route("/direct/inbox", host: Source.host, page: Source.inboxPage(first: first))
        let endless = DirectMessageSync.Pacing(
            scrollPause: .milliseconds(200), maximumRounds: 500, quietRounds: 500, timeout: .seconds(4)
        )

        let started = ContinuousClock.now
        let result = await Source.sync(site, pacing: endless)

        #expect(ContinuousClock.now - started < .seconds(30))
        #expect(result.outcome == .synced)
        #expect(result.snapshot?.threads.map(\.id) == ["t1"])
        #expect(result.report.scrollRounds < 500)
    }

    @Test("A session that ends while the list is scrolled needs the person", .timeLimit(.minutes(2)))
    func sessionEndsWhileScrolling() async {
        let site = TestSite()
        let first = Source.listResponse([Source.chat("t1", with: "maya", texts: ["hello"])])
        site.route("/direct/inbox", host: Source.host, page: Source.inboxPage(
            first: first,
            extra: "<script>document.getElementById('list').addEventListener('scroll', () => { location.replace('/accounts/login/'); });</script>"
        ))
        site.route("/accounts/login", host: Source.host, page: TestPages.page("Log in", "<p>Log in to continue</p>"))

        let result = await Source.sync(site)

        #expect(result.outcome == .needsSignIn)
        #expect(result.snapshot == nil)
    }

    @Test("A path made of anything but plain path characters is reported as other")
    func reportedPaths() {
        #expect(DirectMessageSync.reportedPath("/direct/inbox/") == "/direct/inbox/")
        #expect(DirectMessageSync.reportedPath("/") == "/")
        #expect(DirectMessageSync.reportedPath("/direct/maya says hi/") == "other")
        #expect(DirectMessageSync.reportedPath("/" + String(repeating: "a", count: 100)) == "other")
        #expect(DirectMessageSync.reportedPath("/caf\u{E9}") == "other")
    }

    @Test("The scrolling stops once the chats a snapshot keeps all have messages")
    func hasEnough() {
        func thread(_ id: String, messages: Int) -> DirectMessageThread {
            DirectMessageThread(
                id: id, title: nil, participants: [], isGroup: false, lastActivity: nil, isUnread: nil,
                messages: (0..<messages).map {
                    DirectMessage(
                        id: "\(id)-\($0)", sent: TestMessageSource.now, isFromViewer: false,
                        sender: nil, text: "x", shared: nil
                    )
                }
            )
        }
        let full = [thread("a", messages: 1), thread("b", messages: 2)]

        #expect(DirectMessageSync.hasEnough(full, wanted: 2))
        #expect(!DirectMessageSync.hasEnough(full, wanted: 3))
        #expect(!DirectMessageSync.hasEnough([thread("a", messages: 1), thread("b", messages: 0)], wanted: 2))
        #expect(DirectMessageSync.hasEnough(full + [thread("c", messages: 0)], wanted: 2))
    }

    @Test("A page asks for a sign-in by its path, a password field, or a challenge")
    func asksForSignIn() {
        let passwordField = ProbedField(
            key: FieldKey(name: "password", id: "", autocomplete: "", type: "password"),
            inputMode: "",
            maxLength: nil
        )
        func probe(path: String, password: Bool = false, challenge: Bool = false) -> PageProbe {
            PageProbe(
                origin: "https://chat.example.com",
                path: path,
                isSecureTopFrame: true,
                hasChallenge: challenge,
                fields: password ? [passwordField] : []
            )
        }
        let source = TestMessageSource.source

        #expect(!DirectMessageSync.asksForSignIn(probe(path: "/direct/inbox/"), source: source))
        #expect(DirectMessageSync.asksForSignIn(probe(path: "/accounts/login/"), source: source))
        #expect(DirectMessageSync.asksForSignIn(probe(path: "/challenge/123/"), source: source))
        #expect(DirectMessageSync.asksForSignIn(probe(path: "/direct/inbox/", password: true), source: source))
        #expect(DirectMessageSync.asksForSignIn(probe(path: "/direct/inbox/", challenge: true), source: source))
    }
}
