import Foundation
import WebKit

/// What a browser copies out of a page: the text of the responses the page's own requests
/// receive, for one host and one family of addresses.
///
/// **The listener runs in the page's own world**, the only place a page's requests can be seen
/// from, so the page's scripts can reach it. Everything it reports is therefore the page's word
/// and nothing more: a script on the page can post a report of its own making, and the app
/// treats each report as text from a stranger. What the app controls is which frame it listens
/// to (`PageCaptureLog.record` takes the frame's facts from the web view, never from the
/// report) and how much it will hold.
///
/// **A page read this way is told it is on screen**, so it behaves as it does in front of a
/// person, and a page that reports presence or marks things seen would do so here. Two limits
/// keep the listener to reading. With `sentOperationSuffix` set, a request to a matching
/// address by any method but GET or HEAD is sent only when its body names exactly one
/// operation and that name ends in the suffix; any other, one whose body cannot be read
/// included, fails as a request the network refused and never leaves. With `blocksSockets`
/// set, `WebSocket` is replaced by one that never connects.
///
/// **Both act only on XHR, `fetch`, and `WebSocket` in the windows the script is injected
/// into.** A request made from a worker, a beacon, and a form the page submits pass them by.
/// The browser's content rules reach those, and block only the addresses they name.
///
/// **The handler is reachable from every frame of the page**, and WebKit builds a posted
/// value in the app before `PageCaptureLog.record` can measure it, so the limits bound what
/// is kept and never what one post costs to receive.
struct PageCapture: Equatable, Sendable {
    /// The message the listener posts.
    static let message = "supervisorCapture"

    static let maximumOperationNames = 64

    /// Where a refused request is pointed. No scheme handler answers it, so the request ends
    /// in a network error inside the web view.
    static let refusedAddress = "about:refused"

    /// The host whose main frame may report.
    let host: String
    /// A JavaScript regular expression. A request is watched when its absolute address
    /// matches.
    let urlPattern: String
    /// A response is reported when it contains one of these; any response when empty.
    let markers: [String]
    /// The field of a request body that names its operation.
    let operationField: String?
    /// See the type's comment. Nil sends every request.
    let sentOperationSuffix: String?
    let blocksSockets: Bool
    /// The most UTF-16 units one reported response may hold.
    var maximumResponseLength = 2 << 20
    var maximumResponses = 400
    /// The most UTF-8 bytes of responses a browser holds.
    var maximumTotalBytes = 48 << 20

    /// The name to count an operation under: the reported name when it is a plain identifier,
    /// else `unnamed`.
    static func operationName(_ reported: Any?) -> String {
        guard let name = reported as? String,
              name.range(of: #"\A[A-Za-z0-9_]{1,80}\z"#, options: .regularExpression) != nil
        else { return "unnamed" }
        return name
    }

    /// The listener, with this capture's settings written in as one JSON constant.
    var script: String {
        let settings: [String: Any] = [
            "message": Self.message,
            "urlPattern": urlPattern,
            "markers": markers,
            "operationField": operationField ?? NSNull(),
            "sentSuffix": sentOperationSuffix ?? NSNull(),
            "blocksSockets": blocksSockets,
            "maximumLength": maximumResponseLength,
            "refusedAddress": Self.refusedAddress,
        ]
        let encoded = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
        return Self.listener.replacingOccurrences(of: "__SETTINGS__", with: encoded)
    }

    /// Every failure inside the listener is swallowed: it runs in front of the page's own
    /// code, and an exception escaping a wrapped call would break the page.
    private static let listener = #"""
        (() => {
          const config = __SETTINGS__;
          if (!config) return;
          const handlers = window.webkit && window.webkit.messageHandlers;
          const handler = handlers && handlers[config.message];
          if (!handler) return;
          const post = (message) => {
            try { handler.postMessage(message); } catch (error) {}
          };
          let pattern;
          try { pattern = new RegExp(config.urlPattern); } catch (error) { return; }
          const matches = (url) => {
            try { return pattern.test(new URL(String(url), document.baseURI).href); } catch (error) { return false; }
          };

          // A field given twice names no operation: which one the server reads is its choice.
          const single = (values) => (values.length === 1 && typeof values[0] === 'string' ? values[0] : '');
          const operationOf = (body) => {
            if (!config.operationField) return '';
            try {
              if (typeof body === 'string') {
                const trimmed = body.trimStart();
                if (trimmed.startsWith('{')) {
                  const value = JSON.parse(trimmed)[config.operationField];
                  return typeof value === 'string' ? value : '';
                }
                return single(new URLSearchParams(body).getAll(config.operationField));
              }
              if (body instanceof URLSearchParams || body instanceof FormData) {
                return single(body.getAll(config.operationField));
              }
            } catch (error) {}
            return '';
          };
          const isRefused = (method, operation) => config.sentSuffix !== null
            && method !== 'GET' && method !== 'HEAD' && !operation.endsWith(config.sentSuffix);
          const report = (operation, text) => {
            if (typeof text !== 'string' || text.length === 0 || text.length > config.maximumLength) return;
            if (config.markers.length > 0 && !config.markers.some((marker) => text.includes(marker))) return;
            post({ kind: 'response', operation: operation, text: text });
          };
          const textOf = (request) => {
            try {
              const type = request.responseType;
              if (type === '' || type === 'text') return request.responseText;
              if (type === 'json') return JSON.stringify(request.response);
              if (type === 'arraybuffer' && request.response
                && request.response.byteLength <= config.maximumLength) {
                return new TextDecoder().decode(request.response);
              }
            } catch (error) {}
            return null;
          };

          const prototype = XMLHttpRequest.prototype;
          const nativeOpen = prototype.open;
          const nativeSend = prototype.send;
          const watched = new WeakMap();
          // The watched send a request object is on, until its response is reported. An object
          // can be opened and sent again, and the listener of an earlier send must not report
          // a later one's response.
          const current = new WeakMap();
          // Reports the response of the send `request` is on, once.
          const settle = (request, entry) => {
            if (current.get(request) !== entry) return;
            current.delete(request);
            if (request.readyState === 4) report(entry.operation, textOf(request));
          };
          prototype.open = function (method, url) {
            try {
              // A page can open the object again from its own load handler, which runs before
              // the listener added below; the response is read here, before it is discarded.
              const entry = current.get(this);
              if (entry) settle(this, entry);
              if (matches(url)) {
                watched.set(this, String(method).toUpperCase());
              } else {
                watched.delete(this);
              }
            } catch (error) {}
            return nativeOpen.apply(this, arguments);
          };
          prototype.send = function (body) {
            let method;
            try { method = watched.get(this); } catch (error) {}
            if (method === undefined) return nativeSend.apply(this, arguments);
            const operation = operationOf(body);
            if (isRefused(method, operation)) {
              post({ kind: 'refused', operation: operation });
              // Opened again on an address nothing answers, the request fails the way one the
              // network refused does: it reaches its final state and fires its own events, so
              // code waiting on any of them is released.
              try {
                nativeOpen.call(this, 'GET', config.refusedAddress, true);
                nativeSend.call(this, null);
              } catch (error) {}
              return undefined;
            }
            try {
              const entry = { operation: operation };
              current.set(this, entry);
              this.addEventListener('load', () => settle(this, entry), { once: true });
            } catch (error) {}
            return nativeSend.apply(this, arguments);
          };

          const nativeFetch = window.fetch;
          if (typeof nativeFetch === 'function') {
            window.fetch = function (input, init) {
              let url = '';
              let method = 'GET';
              let body = null;
              try {
                const isRequest = typeof Request === 'function' && input instanceof Request;
                url = isRequest ? input.url : String(input);
                method = String((init && init.method) || (isRequest ? input.method : 'GET')).toUpperCase();
                body = init && init.body !== undefined ? init.body : null;
              } catch (error) {
                // A request whose address or method cannot be read cannot be judged.
                post({ kind: 'refused', operation: '' });
                return Promise.reject(new TypeError('Load failed'));
              }
              if (!matches(url)) return nativeFetch.apply(this, arguments);
              const operation = operationOf(body);
              if (isRefused(method, operation)) {
                post({ kind: 'refused', operation: operation });
                return Promise.reject(new TypeError('Load failed'));
              }
              const pending = nativeFetch.apply(this, arguments);
              pending.then((response) => response.clone().text())
                .then((text) => report(operation, text))
                .catch(() => {});
              return pending;
            };
          }

          if (config.blocksSockets && typeof window.WebSocket === 'function') {
            const fire = (socket, event) => {
              try { socket.dispatchEvent(event); } catch (error) {}
              try {
                const listener = socket['on' + event.type];
                if (typeof listener === 'function') listener.call(socket, event);
              } catch (error) {}
            };
            class BlockedSocket extends EventTarget {
              constructor(url) {
                super();
                this.url = String(url);
                this.readyState = 0;
                this.bufferedAmount = 0;
                this.extensions = '';
                this.protocol = '';
                this.binaryType = 'blob';
                this.onopen = null;
                this.onmessage = null;
                this.onerror = null;
                this.onclose = null;
                post({ kind: 'socket' });
                setTimeout(() => {
                  this.readyState = 3;
                  fire(this, new Event('error'));
                  fire(this, new CloseEvent('close', { code: 1006, reason: '', wasClean: false }));
                }, 0);
              }
              send() {}
              close() {}
            }
            for (const [name, value] of [['CONNECTING', 0], ['OPEN', 1], ['CLOSING', 2], ['CLOSED', 3]]) {
              BlockedSocket[name] = value;
              BlockedSocket.prototype[name] = value;
            }
            window.WebSocket = BlockedSocket;
          }
        })();
        """#
}

/// What a browser's listener has reported so far.
struct PageCaptureLog: Equatable, Sendable {
    /// Where a report came from, as the web view says.
    struct Frame: Equatable, Sendable {
        let isMainFrame: Bool
        let scheme: String
        let host: String
        let port: Int
    }

    /// The text of each response accepted, in the order received.
    private(set) var responses: [String] = []
    /// How many responses were accepted, by the operation that asked for them.
    private(set) var operations: [String: Int] = [:]
    /// How many requests the listener refused to send, by operation.
    private(set) var refusedOperations: [String: Int] = [:]
    /// How many sockets the page asked for and was given one that never connects.
    private(set) var blockedSockets = 0
    /// Reports that were not kept: from another frame or host, malformed, or past a limit.
    private(set) var dropped = 0
    private(set) var bytes = 0

    /// Takes one report. It is kept only when it came from the main frame of `capture.host`
    /// over `https` on the default port, has one of the listener's shapes, and fits the
    /// capture's limits; anything else adds to `dropped`.
    mutating func record(_ body: Any, from frame: Frame, capture: PageCapture) {
        guard frame.isMainFrame,
              frame.scheme.lowercased() == "https",
              frame.host.lowercased() == capture.host,
              frame.port == 0 || frame.port == 443,
              let report = body as? [String: Any],
              let kind = report["kind"] as? String
        else {
            dropped += 1
            return
        }
        switch kind {
        case "response":
            guard let text = report["text"] as? String,
                  !text.isEmpty,
                  text.utf16.count <= capture.maximumResponseLength,
                  responses.count < capture.maximumResponses
            else {
                dropped += 1
                return
            }
            let size = text.utf8.count
            guard bytes + size <= capture.maximumTotalBytes else {
                dropped += 1
                return
            }
            bytes += size
            responses.append(text)
            Self.count(PageCapture.operationName(report["operation"]), in: &operations)
        case "refused":
            Self.count(PageCapture.operationName(report["operation"]), in: &refusedOperations)
        case "socket":
            blockedSockets += 1
        default:
            dropped += 1
        }
    }

    /// Counts under `name`, or under `other` once `maximumOperationNames` names are held, so a
    /// page cannot grow the table without bound.
    private static func count(_ name: String, in table: inout [String: Int]) {
        let key = table[name] != nil || table.count < PageCapture.maximumOperationNames ? name : "other"
        table[key, default: 0] += 1
    }
}

/// Receives the listener's reports for a browser, holding it weakly: the web view's content
/// controller keeps its handlers alive for as long as the web view lives. The frame a report
/// came from is read here, from the web view, and never from the report.
@MainActor
final class PageCaptureRelay: NSObject, WKScriptMessageHandler {
    weak var browser: SiteBrowser?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let frame = message.frameInfo
        browser?.receiveCapture(
            message.body,
            from: PageCaptureLog.Frame(
                isMainFrame: frame.isMainFrame,
                scheme: frame.securityOrigin.protocol,
                host: frame.securityOrigin.host,
                port: frame.securityOrigin.port
            )
        )
    }
}

/// Requests a browser refuses to make, compiled into the form WebKit applies to every load a
/// page sets off, a worker's included.
enum RequestBlocking {
    /// Compiles `rules`, a content rule list in WebKit's JSON form, under `identifier`. Nil
    /// when WebKit does not accept the rules.
    @MainActor
    static func compile(
        identifier: String,
        rules: String,
        store: WKContentRuleListStore? = .default()
    ) async -> WKContentRuleList? {
        guard let store else { return nil }
        return try? await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: rules
        )
    }
}
