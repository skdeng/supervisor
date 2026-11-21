import Foundation
import WebKit

/// How a read of one address in a hidden browser ended.
enum PageReadOutcome: Equatable, Sendable {
    /// The load settled on a page, which was probed.
    case page(PageProbe)
    /// A navigation went to a host outside the browser's.
    case leftSite
    case failed
}

/// Reads of one address in a browser that is never shown, each held to a time limit.
///
/// A hidden read is how a page looks to the reads the app makes by itself later: a fresh load
/// in a browser of the default size, with no one typing into it. `SiteEnrollment` makes one to
/// confirm what the person's own window showed, and `VisitorCheck` makes one with no cookies.
enum HiddenRead {
    static let standardTimeout: Duration = .seconds(10)

    /// `url` without its query and fragment, which can carry session data.
    static func addressWithoutQuery(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Runs `body` against a new browser held to `browseHosts` on `dataStore`, and closes the
    /// browser afterwards. `timeout` is a hard limit: when it has passed the browser is closed,
    /// which answers any script the page has not answered, and `body` is cancelled.
    ///
    /// The settle limit counts from the end of the load: a page that keeps changing is read
    /// once half of `timeout` has passed since its load finished, or when `timeout` ends the
    /// read, whichever comes first.
    @MainActor
    static func withBrowser<Result: Sendable>(
        browseHosts: Set<String>,
        dataStore: WKWebsiteDataStore,
        pages: SiteBrowser.SimulatedPages?,
        settling: SiteBrowser.Settling,
        timeout: Duration,
        capture: PageCapture? = nil,
        contentRules: [WKContentRuleList] = [],
        _ body: @escaping @MainActor (SiteBrowser) async -> Result
    ) async -> Result {
        var bounded = settling
        bounded.settleLimit = min(bounded.settleLimit, timeout / 2)
        let browser = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: browseHosts),
            dataStore: dataStore,
            simulatedPages: pages,
            settling: bounded,
            capture: capture,
            contentRules: contentRules
        )
        defer { browser.close() }

        let working = Task { @MainActor in await body(browser) }
        let timer = Task { @MainActor in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            browser.close()
            working.cancel()
        }
        let result = await withTaskCancellationHandler {
            await working.value
        } onCancel: {
            working.cancel()
        }
        timer.cancel()
        return result
    }

    /// Opens `url` in `browser` and probes the page that settles.
    @MainActor
    static func read(_ url: URL, in browser: SiteBrowser) async -> PageReadOutcome {
        do {
            _ = try await browser.open(url)
            return .page(try await SignInBroker(browser: browser).probe())
        } catch SiteBrowser.Failure.leftSite {
            return .leftSite
        } catch {
            return .failed
        }
    }

    /// What a fresh hidden read of a start page shows, when it shows the page a later read
    /// would take for the signed-in one: a secure top frame at the start page's own origin and
    /// path that asks for no sign-in. Nil when the read fails, is taken off the site's hosts,
    /// or shows anything else.
    ///
    /// The read uses `dataStore`, so it sees the session the person has just signed in with.
    @MainActor
    static func startPage(
        _ startURL: URL,
        browseHosts: Set<String>,
        dataStore: WKWebsiteDataStore,
        pages: SiteBrowser.SimulatedPages?,
        settling: SiteBrowser.Settling,
        timeout: Duration = standardTimeout
    ) async -> PageProbe? {
        guard let address = addressWithoutQuery(startURL) else { return nil }
        let outcome = await withBrowser(
            browseHosts: browseHosts,
            dataStore: dataStore,
            pages: pages,
            settling: settling,
            timeout: timeout
        ) { browser in
            await read(address, in: browser)
        }
        guard case let .page(probe) = outcome,
              probe.isSecureTopFrame,
              SignInRules.isStartPage(probe, address),
              SignInRules.isPastSignIn(probe)
        else { return nil }
        return probe
    }
}
