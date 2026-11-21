import Foundation
import WebKit

/// One copy of a source's recent chats: its inbox page is loaded in a browser nobody sees,
/// signed in as the person, the chat list is scrolled so the page fetches more, and what the
/// page received is parsed into a snapshot.
///
/// The browser loads the inbox and scrolls it, and does nothing else to the page: it opens no
/// chat, types nothing, and presses nothing. What the page itself may send while it is open is
/// bounded by the source's `PageCapture` and `blockedRequests`.
@MainActor
enum DirectMessageSync {
    enum Outcome: String, Equatable, Sendable {
        case synced
        /// The page asks for a sign-in, which only the person can give.
        case needsSignIn
        /// The inbox loaded signed in and no chat could be read from what it received.
        case nothingCaptured
        /// The inbox did not load, or the load ended somewhere else. Says nothing about
        /// whether the person is signed in.
        case pageUnavailable
    }

    struct Result: Equatable, Sendable {
        var outcome: Outcome
        /// The chats read, cut to what a snapshot keeps; set exactly when `outcome` is
        /// `synced`.
        var snapshot: DirectMessageSnapshot?
        var report = Report()
    }

    /// Counts and names for a log line or a self-check. Nothing here is message text.
    struct Report: Equatable, Sendable {
        /// The path of the page the load ended on, when it is made of plain path characters;
        /// `other` when it is not, since a page chooses its own path.
        var pagePath: String?
        var responses = 0
        var operations: [String: Int] = [:]
        var refusedOperations: [String: Int] = [:]
        var blockedSockets = 0
        var droppedReports = 0
        var capturedBytes = 0
        var scrollRounds = 0
        var foundScroller = false
        var parse = InstagramInboxParser.Report()
        /// Of the chats in the snapshot, how many have a message and how many are unread.
        var threadsWithMessages = 0
        var unreadThreads = 0
    }

    struct Pacing: Sendable {
        /// How long the page is given after each scroll to fetch what the scroll revealed.
        var scrollPause: Duration = .milliseconds(1_200)
        var maximumRounds = 20
        /// How many rounds in a row may bring nothing new before the scrolling stops.
        var quietRounds = 4
        /// The limit on the whole sync, after which the browser is closed and what was read so
        /// far is used.
        var timeout: Duration = .seconds(90)

        static let standard = Pacing()
    }

    static func run(
        source: DirectMessageSource,
        dataStore: WKWebsiteDataStore,
        contentRules: [WKContentRuleList],
        pages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        pacing: Pacing = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> Result {
        await HiddenRead.withBrowser(
            browseHosts: source.hosts,
            dataStore: dataStore,
            pages: pages,
            settling: settling,
            timeout: pacing.timeout,
            capture: source.capture,
            contentRules: contentRules
        ) { browser in
            var result = await read(source, in: browser, pacing: pacing, now: now)
            let log = browser.captureLog
            result.report.responses = log.responses.count
            result.report.operations = log.operations
            result.report.refusedOperations = log.refusedOperations
            result.report.blockedSockets = log.blockedSockets
            result.report.droppedReports = log.dropped
            result.report.capturedBytes = log.bytes
            return result
        }
    }

    private static func read(
        _ source: DirectMessageSource,
        in browser: SiteBrowser,
        pacing: Pacing,
        now: @escaping @Sendable () -> Date
    ) async -> Result {
        var result = Result(outcome: .pageUnavailable)
        let loaded = await HiddenRead.read(source.inboxURL, in: browser)
        guard case let .page(probe) = loaded else { return result }
        result.report.pagePath = reportedPath(probe.path)
        if asksForSignIn(probe, source: source) {
            result.outcome = .needsSignIn
            return result
        }
        guard probe.isSecureTopFrame, source.hosts.contains(host(of: probe)) else { return result }

        let wanted = DirectMessageSnapshot.maximumThreads
        var seen = browser.captureLog.responses.count
        var parsed = await parse(browser.captureLog.responses, source: source, now: now())
        var quiet = 0
        while !hasEnough(parsed.threads, wanted: wanted),
              result.report.scrollRounds < pacing.maximumRounds,
              quiet < pacing.quietRounds,
              !browser.isClosed {
            if let scrolled = try? await browser.run(Scripts.scroll), scrolled["found"]?.bool == true {
                result.report.foundScroller = true
            }
            guard (try? await Task.sleep(for: pacing.scrollPause)) != nil else { break }
            result.report.scrollRounds += 1
            let count = browser.captureLog.responses.count
            if count == seen {
                quiet += 1
            } else {
                quiet = 0
                seen = count
                parsed = await parse(browser.captureLog.responses, source: source, now: now())
            }
        }
        if browser.captureLog.responses.count != seen {
            parsed = await parse(browser.captureLog.responses, source: source, now: now())
        }
        result.report.parse = parsed.report

        // A session that ended while the list was scrolled leaves the page on the sign-in.
        if let path = browser.committedURL?.path, isSignInPath(path, source: source) {
            result.outcome = .needsSignIn
            return result
        }
        guard !parsed.threads.isEmpty else {
            result.outcome = .nothingCaptured
            return result
        }
        let snapshot = DirectMessageSnapshot(source: source.id, syncedAt: now(), threads: parsed.threads).trimmed()
        result.outcome = .synced
        result.snapshot = snapshot
        result.report.threadsWithMessages = snapshot.threads.filter { !$0.messages.isEmpty }.count
        result.report.unreadThreads = snapshot.threads.filter { $0.isUnread == true }.count
        return result
    }

    /// Whether the page is one that asks the person to sign in: its path says so, or it shows a
    /// password or code field, a sign-in frame, or a challenge to answer.
    static func asksForSignIn(_ probe: PageProbe, source: DirectMessageSource) -> Bool {
        isSignInPath(probe.path, source: source) || !SignInRules.isPastSignIn(probe)
    }

    static func reportedPath(_ path: String) -> String {
        path.range(of: #"\A/[A-Za-z0-9/_.-]{0,99}\z"#, options: .regularExpression) != nil ? path : "other"
    }

    static func isSignInPath(_ path: String, source: DirectMessageSource) -> Bool {
        source.signInPathPrefixes.contains { path.hasPrefix($0) }
    }

    /// Whether the chats a snapshot would keep are all there with messages, so that more
    /// scrolling would add nothing the snapshot keeps.
    static func hasEnough(_ threads: [DirectMessageThread], wanted: Int) -> Bool {
        threads.count >= wanted && threads.prefix(wanted).allSatisfy { !$0.messages.isEmpty }
    }

    private static func host(of probe: PageProbe) -> String {
        probe.origin.hasPrefix("https://") ? String(probe.origin.dropFirst("https://".count)) : ""
    }

    /// Parsing reads megabytes of JSON, so it runs off the main actor.
    private static func parse(
        _ responses: [String],
        source: DirectMessageSource,
        now: Date
    ) async -> (threads: [DirectMessageThread], report: InstagramInboxParser.Report) {
        let parse = source.parse
        return await Task.detached { parse(responses, now) }.value
    }

    private enum Scripts {
        /// Moves every scrolling list on the page most of a screen further down. A chat list
        /// fetches its next page, and the messages of the chats that come into view, as it is
        /// scrolled. Which element is the chat list is the page's business and changes with
        /// its markup, so every element that scrolls and holds at least three rows is moved.
        static let scroll = """
            let found = false;
            for (const element of document.querySelectorAll('div, ul, section, nav')) {
              if (element.scrollHeight - element.clientHeight < 40) continue;
              const overflow = getComputedStyle(element).overflowY;
              if (overflow !== 'auto' && overflow !== 'scroll') continue;
              if (element.querySelectorAll('[role="button"], [role="listitem"], [role="row"], a').length < 3) continue;
              found = true;
              element.scrollTop = Math.min(
                element.scrollTop + Math.max(element.clientHeight * 0.8, 200),
                element.scrollHeight
              );
            }
            return { found: found };
            """
    }
}
