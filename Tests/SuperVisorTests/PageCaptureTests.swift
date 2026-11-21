import Foundation
import Network
import Testing
import WebKit

@testable import SuperVisor

/// A capture whose watched address is a `data:` URL, so a simulated page's requests are
/// answered inside the web view and nothing leaves the machine.
private func testCapture(
    host: String = "chat.example.com",
    maximumResponseLength: Int = 2 << 20
) -> PageCapture {
    var capture = PageCapture(
        host: host,
        urlPattern: "^data:application/json",
        markers: ["slide_messages"],
        operationField: "op",
        sentOperationSuffix: "Query",
        blocksSockets: true
    )
    capture.maximumResponseLength = maximumResponseLength
    return capture
}

@Suite("Page capture log")
struct PageCaptureLogTests {
    private let capture = testCapture()
    private let mainFrame = PageCaptureLog.Frame(isMainFrame: true, scheme: "https", host: "chat.example.com", port: 0)

    private func response(_ text: String, operation: Any? = "InboxQuery") -> [String: Any] {
        var report: [String: Any] = ["kind": "response", "text": text]
        if let operation { report["operation"] = operation }
        return report
    }

    @Test("A response from the capture's host in the main frame is kept and counted under its operation")
    func keepsResponse() {
        var log = PageCaptureLog()
        log.record(response("{\"slide_messages\":1}"), from: mainFrame, capture: capture)

        #expect(log.responses == ["{\"slide_messages\":1}"])
        #expect(log.operations == ["InboxQuery": 1])
        #expect(log.bytes == 20)
        #expect(log.dropped == 0)
    }

    @Test(
        "A report from a subframe, another host, plain http, or an explicit port is dropped",
        arguments: [
            PageCaptureLog.Frame(isMainFrame: false, scheme: "https", host: "chat.example.com", port: 0),
            PageCaptureLog.Frame(isMainFrame: true, scheme: "https", host: "evil.example.com", port: 0),
            PageCaptureLog.Frame(isMainFrame: true, scheme: "https", host: "sub.chat.example.com", port: 0),
            PageCaptureLog.Frame(isMainFrame: true, scheme: "http", host: "chat.example.com", port: 0),
            PageCaptureLog.Frame(isMainFrame: true, scheme: "https", host: "chat.example.com", port: 8443),
        ]
    )
    func dropsOtherFrames(frame: PageCaptureLog.Frame) {
        var log = PageCaptureLog()
        log.record(response("{}"), from: frame, capture: capture)

        #expect(log.responses.isEmpty)
        #expect(log.dropped == 1)
    }

    @Test("The default https port is accepted as no port is")
    func acceptsDefaultPort() {
        var log = PageCaptureLog()
        let frame = PageCaptureLog.Frame(isMainFrame: true, scheme: "HTTPS", host: "Chat.Example.com", port: 443)
        log.record(response("{}"), from: frame, capture: capture)

        #expect(log.responses.count == 1)
    }

    @Test("A report that is not one of the listener's shapes is dropped")
    func dropsMalformed() {
        var log = PageCaptureLog()
        log.record("text", from: mainFrame, capture: capture)
        log.record(["kind": "other"], from: mainFrame, capture: capture)
        log.record(["kind": "response"], from: mainFrame, capture: capture)
        log.record(["kind": "response", "text": 7], from: mainFrame, capture: capture)
        log.record(["kind": "response", "text": ""], from: mainFrame, capture: capture)

        #expect(log.responses.isEmpty)
        #expect(log.dropped == 5)
    }

    @Test("A response past the length, count, or total size limit is dropped")
    func holdsLimits() {
        var small = testCapture(maximumResponseLength: 10)
        var log = PageCaptureLog()
        log.record(response(String(repeating: "a", count: 11)), from: mainFrame, capture: small)
        #expect(log.responses.isEmpty)

        small.maximumResponses = 2
        log.record(response("one"), from: mainFrame, capture: small)
        log.record(response("two"), from: mainFrame, capture: small)
        log.record(response("three"), from: mainFrame, capture: small)
        #expect(log.responses == ["one", "two"])

        var tight = testCapture()
        tight.maximumTotalBytes = 5
        var second = PageCaptureLog()
        second.record(response("abc"), from: mainFrame, capture: tight)
        second.record(response("def"), from: mainFrame, capture: tight)
        #expect(second.responses == ["abc"])
        #expect(second.bytes == 3)
        #expect(second.dropped == 1)
    }

    @Test("An operation name that is not a plain identifier is counted as unnamed")
    func sanitizesOperationNames() {
        var log = PageCaptureLog()
        for name in ["Fine_Query1", "has space", "", String(repeating: "a", count: 81), "ünï"] as [Any] {
            log.record(["kind": "refused", "operation": name], from: mainFrame, capture: capture)
        }
        log.record(["kind": "refused", "operation": 4], from: mainFrame, capture: capture)
        log.record(["kind": "refused"], from: mainFrame, capture: capture)

        #expect(log.refusedOperations == ["Fine_Query1": 1, "unnamed": 6])
    }

    @Test("Past the cap on distinct names, further operations are counted together")
    func capsOperationNames() {
        var log = PageCaptureLog()
        for index in 0..<(PageCapture.maximumOperationNames + 10) {
            log.record(["kind": "refused", "operation": "Op\(index)"], from: mainFrame, capture: capture)
        }

        #expect(log.refusedOperations.count == PageCapture.maximumOperationNames + 1)
        #expect(log.refusedOperations["other"] == 10)
    }

    @Test("A blocked socket is counted")
    func countsSockets() {
        var log = PageCaptureLog()
        log.record(["kind": "socket"], from: mainFrame, capture: capture)
        log.record(["kind": "socket"], from: mainFrame, capture: capture)

        #expect(log.blockedSockets == 2)
    }
}

@Suite("Page capture in a browser", .serialized)
@MainActor
struct PageCaptureBrowserTests {
    private let hosts: Set<String> = ["chat.example.com", "other.example.com"]

    private func browser(_ site: TestSite, capture: PageCapture? = testCapture()) -> SiteBrowser {
        SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: hosts),
            dataStore: .nonPersistent(),
            simulatedPages: site.answer,
            settling: .fast,
            capture: capture
        )
    }

    /// The page's own helpers: a request by XHR that resolves to how it ended, and a mark the
    /// test waits for.
    private static let helpers = """
        const dataURL = (object) => 'data:application/json,' + encodeURIComponent(JSON.stringify(object));
        const request = (method, url, body) => new Promise((resolve) => {
          const xhr = new XMLHttpRequest();
          xhr.open(method, url);
          xhr.onload = () => resolve('load');
          xhr.onerror = () => resolve('error');
          xhr.send(body);
        });
        const finish = (results) => {
          document.body.dataset.results = JSON.stringify(results);
        };
        """

    /// Opens a page on `host` that runs `script` in the page's own world, and returns what the
    /// script passed to `finish`.
    private func run(
        _ script: String,
        in browser: SiteBrowser,
        site: TestSite,
        host: String = "chat.example.com",
        body: String = "<p>inbox</p>"
    ) async throws -> [String: Any] {
        site.route("/inbox", host: host, page: TestPages.page("Inbox", body, script: Self.helpers + script))
        _ = try await browser.open(URL(string: "https://\(host)/inbox")!)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            let value = try await browser.run("return document.body.dataset.results || '';")
            if let text = value.string, !text.isEmpty,
               let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                return object
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the page never finished")
        return [:]
    }

    @Test("The text of a watched response that carries a marker is copied, and no other", .timeLimit(.minutes(1)))
    func copiesWatchedResponses() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const first = await request('GET', dataURL({ slide_messages: ['hello'] }));
              const unmarked = await request('GET', dataURL({ other: 1 }));
              const unwatched = await request('GET', 'data:text/plain,slide_messages');
              finish({ first, unmarked, unwatched });
            })();
            """, in: browser, site: site)

        #expect(results["first"] as? String == "load")
        #expect(results["unmarked"] as? String == "load")
        #expect(results["unwatched"] as? String == "load")
        #expect(browser.captureLog.responses == [#"{"slide_messages":["hello"]}"#])
        #expect(browser.captureLog.dropped == 0)
    }

    @Test(
        "A watched request that is not a read is answered with an error and never sent; a read is sent and copied",
        .timeLimit(.minutes(1))
    )
    func refusesOtherOperations() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const url = dataURL({ slide_messages: 1 });
              const mutation = await request('POST', url, 'a=1&op=MarkSeenMutation');
              const unnamed = await request('POST', url, 'a=1');
              const json = await request('POST', url, JSON.stringify({ op: 'SendMutation' }));
              const form = new FormData();
              form.append('op', 'InboxQuery');
              const query = await request('POST', url, form);
              finish({ mutation, unnamed, json, query });
            })();
            """, in: browser, site: site)

        #expect(results["mutation"] as? String == "error")
        #expect(results["unnamed"] as? String == "error")
        #expect(results["json"] as? String == "error")
        #expect(results["query"] as? String == "load")
        #expect(browser.captureLog.refusedOperations == ["MarkSeenMutation": 1, "unnamed": 1, "SendMutation": 1])
        #expect(browser.captureLog.operations == ["InboxQuery": 1])
        #expect(browser.captureLog.responses.count == 1)
    }

    @Test(
        "A refused request reaches its final state with no status, so code waiting on the state change is released",
        .timeLimit(.minutes(1))
    )
    func refusedRequestSettles() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const settled = await new Promise((resolve) => {
                const xhr = new XMLHttpRequest();
                xhr.open('POST', dataURL({ slide_messages: 1 }));
                xhr.onreadystatechange = () => {
                  if (xhr.readyState === 4) resolve({ status: xhr.status, text: xhr.responseText });
                };
                xhr.send('op=MarkSeenMutation');
                setTimeout(() => resolve({ status: -1, text: 'never settled' }), 5000);
              });
              finish(settled);
            })();
            """, in: browser, site: site)

        #expect(results["status"] as? Int == 0)
        #expect(results["text"] as? String == "")
        #expect(browser.captureLog.responses.isEmpty)
    }

    @Test("A body that names two operations names none, and is refused", .timeLimit(.minutes(1)))
    func refusesTwoOperations() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const url = dataURL({ slide_messages: 1 });
              const text = await request('POST', url, 'op=InboxQuery&op=DeleteMutation');
              const form = new FormData();
              form.append('op', 'InboxQuery');
              form.append('op', 'DeleteMutation');
              const multipart = await request('POST', url, form);
              finish({ text, multipart });
            })();
            """, in: browser, site: site)

        #expect(results["text"] as? String == "error")
        #expect(results["multipart"] as? String == "error")
        #expect(browser.captureLog.refusedOperations == ["unnamed": 2])
    }

    @Test(
        "A request object sent again reports each response once, and none from an address that is not watched",
        .timeLimit(.minutes(1))
    )
    func reusedRequest() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const xhr = new XMLHttpRequest();
              const send = (url) => new Promise((resolve) => {
                xhr.onload = () => resolve('load');
                xhr.onerror = () => resolve('error');
                xhr.open('GET', url);
                xhr.send();
              });
              const first = await send(dataURL({ slide_messages: 'first' }));
              const second = await send(dataURL({ slide_messages: 'second' }));
              const unwatched = await send('data:text/plain,slide_messages');
              finish({ first, second, unwatched });
            })();
            """, in: browser, site: site)

        #expect(results["unwatched"] as? String == "load")
        #expect(browser.captureLog.responses == [#"{"slide_messages":"first"}"#, #"{"slide_messages":"second"}"#])
    }

    @Test("Requests made with fetch are copied and refused by the same rules", .timeLimit(.minutes(1)))
    func watchesFetch() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const url = dataURL({ slide_messages: 2 });
              const read = await fetch(url).then((response) => response.text());
              const refused = await fetch(url, { method: 'POST', body: 'op=DeleteMutation' })
                .then(() => 'sent', (error) => error instanceof TypeError ? 'rejected' : 'other');
              const allowed = await fetch(url, { method: 'POST', body: new URLSearchParams({ op: 'ThreadQuery' }) })
                .then(() => 'sent', () => 'rejected');
              finish({ read, refused, allowed });
            })();
            """, in: browser, site: site)

        #expect(results["read"] as? String == #"{"slide_messages":2}"#)
        #expect(results["refused"] as? String == "rejected")
        #expect(results["allowed"] as? String == "sent")
        #expect(browser.captureLog.refusedOperations == ["DeleteMutation": 1])
        #expect(browser.captureLog.responses.count == 2)
        #expect(browser.captureLog.operations == ["unnamed": 1, "ThreadQuery": 1])
    }

    @Test("A fetch whose method cannot be read is refused", .timeLimit(.minutes(1)))
    func refusesUnreadableFetch() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const init = { body: 'op=DeleteMutation' };
              Object.defineProperty(init, 'method', { get() { throw new Error('no'); } });
              const outcome = await fetch(dataURL({ slide_messages: 1 }), init)
                .then(() => 'sent', (error) => error instanceof TypeError ? 'rejected' : 'other');
              finish({ outcome });
            })();
            """, in: browser, site: site)

        #expect(results["outcome"] as? String == "rejected")
        #expect(browser.captureLog.responses.isEmpty)
    }

    private static let socketScript = """
        (async () => {
          const socket = new WebSocket('wss://socket.invalid/chat');
          const stateAtOnce = socket.readyState;
          const events = [];
          socket.onerror = () => events.push('error');
          socket.addEventListener('close', () => events.push('close'));
          socket.onopen = () => events.push('open');
          await new Promise((resolve) => setTimeout(resolve, 300));
          finish({
            stateAtOnce,
            stateLater: socket.readyState,
            kind: Object.prototype.toString.call(socket),
            events: events.join(','),
            closedConstant: WebSocket.CLOSED
          });
        })();
        """

    @Test("A socket the page asks for is one that never connects: it fails at once and says so", .timeLimit(.minutes(1)))
    func blocksSockets() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run(Self.socketScript, in: browser, site: site)

        #expect(results["stateAtOnce"] as? Int == 0)
        #expect(results["stateLater"] as? Int == 3)
        #expect(results["kind"] as? String != "[object WebSocket]")
        #expect(results["events"] as? String == "error,close")
        #expect(results["closedConstant"] as? Int == 3)
        #expect(browser.captureLog.blockedSockets == 1)
    }

    @Test("A browser with no capture leaves the page its own socket", .timeLimit(.minutes(1)))
    func leavesSocketsWithoutCapture() async throws {
        let site = TestSite()
        let browser = browser(site, capture: nil)
        defer { browser.close() }

        let results = try await run(Self.socketScript, in: browser, site: site)

        #expect(results["kind"] as? String == "[object WebSocket]")
        #expect(browser.captureLog == PageCaptureLog())
    }

    @Test("A browser with no capture gives the page no way to report", .timeLimit(.minutes(1)))
    func noHandlerWithoutCapture() async throws {
        let site = TestSite()
        let browser = browser(site, capture: nil)
        defer { browser.close() }

        let results = try await run("""
            const handlers = window.webkit && window.webkit.messageHandlers;
            finish({ has: Boolean(handlers && handlers.\(PageCapture.message)) });
            """, in: browser, site: site)

        #expect(results["has"] as? Bool == false)
    }

    @Test("A page on another host that reports by itself is not listened to", .timeLimit(.minutes(1)))
    func ignoresOtherHosts() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              await request('GET', dataURL({ slide_messages: 1 }));
              window.webkit.messageHandlers.\(PageCapture.message)
                .postMessage({ kind: 'response', operation: 'InboxQuery', text: '{"slide_messages":[]}' });
              finish({ done: true });
            })();
            """, in: browser, site: site, host: "other.example.com")

        #expect(results["done"] as? Bool == true)
        #expect(browser.captureLog.responses.isEmpty)
        #expect(browser.captureLog.dropped == 2)
    }

    @Test(
        "A report the page's own script makes up is kept like any other, and one over the length limit is not",
        .timeLimit(.minutes(1))
    )
    func keepsWhatThePageSays() async throws {
        let site = TestSite()
        let browser = browser(site, capture: testCapture(maximumResponseLength: 64))
        defer { browser.close() }

        let results = try await run("""
            const handler = window.webkit.messageHandlers.\(PageCapture.message);
            handler.postMessage({ kind: 'response', operation: 'Made_Up', text: '{"slide_messages":"forged"}' });
            handler.postMessage({ kind: 'response', operation: 'Made_Up', text: 'x'.repeat(65) });
            finish({ done: true });
            """, in: browser, site: site)

        #expect(results["done"] as? Bool == true)
        #expect(browser.captureLog.responses == [#"{"slide_messages":"forged"}"#])
        #expect(browser.captureLog.dropped == 1)
    }

    @Test("A frame inside the page gets the socket block, and its reports are not listened to", .timeLimit(.minutes(1)))
    func subframes() async throws {
        let site = TestSite()
        let browser = browser(site)
        defer { browser.close() }

        let results = try await run("""
            (async () => {
              const frame = document.querySelector('iframe');
              await new Promise((resolve) => setTimeout(resolve, 200));
              const inner = frame.contentWindow;
              const socket = new inner.WebSocket('wss://socket.invalid/chat');
              inner.webkit.messageHandlers.\(PageCapture.message)
                .postMessage({ kind: 'response', operation: 'InboxQuery', text: '{"slide_messages":[]}' });
              await new Promise((resolve) => setTimeout(resolve, 200));
              finish({ kind: Object.prototype.toString.call(socket), state: socket.readyState });
            })();
            """, in: browser, site: site, body: "<p>inbox</p><iframe srcdoc=\"<p>frame</p>\"></iframe>")

        #expect(results["kind"] as? String != "[object WebSocket]")
        #expect(results["state"] as? Int == 3)
        #expect(browser.captureLog.responses.isEmpty)
        #expect(browser.captureLog.dropped >= 1)
    }
}

@Suite("Request blocking", .serialized)
@MainActor
struct RequestBlockingTests {
    /// Counts the connections made to a port on this machine.
    private final class LoopbackListener: @unchecked Sendable {
        private let listener: NWListener
        private let lock = NSLock()
        private var count = 0

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.lock.withLock { self.count += 1 }
                connection.cancel()
            }
        }

        var connections: Int { lock.withLock { count } }

        func start() async throws -> UInt16 {
            listener.start(queue: .global())
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if let port = listener.port?.rawValue, port != 0 { return port }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }

        func stop() { listener.cancel() }
    }

    private func store() -> (WKContentRuleListStore?, ScratchFolder) {
        let folder = ScratchFolder()
        return (WKContentRuleListStore(url: folder.url), folder)
    }

    private static let socketRequest = """
        return await new Promise((resolve) => {
          const socket = new WebSocket('ws://127.0.0.1:' + port + '/');
          socket.onopen = () => resolve('open');
          socket.onerror = () => resolve('error');
          socket.onclose = () => resolve('close');
          setTimeout(() => resolve('silent'), 3000);
        });
        """

    /// A plain request for `path`, which ends when the listener hangs up or the rules refuse
    /// it.
    private static let pathRequest = """
        return await Promise.race([
          fetch('http://127.0.0.1:' + port + path, { method: 'POST', mode: 'no-cors', body: 'x' })
            .then(() => 'answered', () => 'failed'),
          new Promise((resolve) => setTimeout(() => resolve('silent'), 3000))
        ]);
        """

    /// Runs `script` against `port` on this machine from a browser's empty first document, and
    /// waits for the attempt to end.
    private func request(
        _ script: String,
        port: UInt16,
        path: String = "/",
        rules: [WKContentRuleList]
    ) async throws {
        let browser = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com"]),
            dataStore: .nonPersistent(),
            settling: .fast,
            contentRules: rules
        )
        defer { browser.close() }
        _ = try await browser.run(script, arguments: ["port": Int(port), "path": path])
        // A connection the page made reaches the listener a moment after the page hears of it.
        try await Task.sleep(for: .milliseconds(300))
    }

    @Test("The request rules of the direct-message source compile")
    func sourceRulesCompile() async {
        let (store, folder) = store()
        defer { folder.remove() }

        let rules = await RequestBlocking.compile(
            identifier: "test-rules",
            rules: DirectMessageSource.instagram.blockedRequests,
            store: store
        )

        #expect(rules != nil)
    }

    @Test("Rules WebKit does not accept compile to nothing")
    func badRulesDoNotCompile() async {
        let (store, folder) = store()
        defer { folder.remove() }

        #expect(await RequestBlocking.compile(identifier: "bad", rules: "not rules", store: store) == nil)
    }

    @Test(
        "Under the source's rules a socket never reaches the network; without them the same request does",
        .timeLimit(.minutes(1))
    )
    func rulesBlockSockets() async throws {
        let (store, folder) = store()
        defer { folder.remove() }
        let rules = try #require(await RequestBlocking.compile(
            identifier: "test-sockets",
            rules: DirectMessageSource.instagram.blockedRequests,
            store: store
        ))

        let open = try LoopbackListener()
        defer { open.stop() }
        try await request(Self.socketRequest, port: try await open.start(), rules: [])
        #expect(open.connections >= 1)

        let blocked = try LoopbackListener()
        defer { blocked.stop() }
        try await request(Self.socketRequest, port: try await blocked.start(), rules: [rules])
        #expect(blocked.connections == 0)
    }

    @Test(
        "Under the source's rules a request to an address that marks a chat seen never reaches the network; another address of the same host does",
        .timeLimit(.minutes(1))
    )
    func rulesBlockSeenAddresses() async throws {
        let (store, folder) = store()
        defer { folder.remove() }
        let rules = try #require(await RequestBlocking.compile(
            identifier: "test-seen",
            rules: DirectMessageSource.instagram.blockedRequests,
            store: store
        ))

        let other = try LoopbackListener()
        defer { other.stop() }
        try await request(
            Self.pathRequest, port: try await other.start(), path: "/api/v1/direct_v2/inbox/", rules: [rules]
        )
        #expect(other.connections >= 1)

        let seen = try LoopbackListener()
        defer { seen.stop() }
        try await request(
            Self.pathRequest, port: try await seen.start(),
            path: "/api/v1/direct_v2/threads/12/items/34/seen/", rules: [rules]
        )
        #expect(seen.connections == 0)
    }
}
