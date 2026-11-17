import Foundation
import WebKit

/// What a visitor with no cookies gets at a signed-in page's address, reduced to what it says
/// about telling a lapsed session from a live one. Only what shows the visitor signed out
/// counts: a page the visitor cannot reach, or one that says the visitor is unverified,
/// proves nothing.
enum VisitorVerdict: String, Equatable, Sendable {
    /// The visitor was sent to another page on the site's hosts that asks for a sign-in or a
    /// user name.
    case redirects
    /// The visitor's page, at the signed-in page's address, asks for a sign-in
    /// (`SignInRules.asksForSignIn`).
    case asksForSignIn
    /// The visitor sees a sign-in control that the signed-in page lacks, at the same address or
    /// on the page the visitor was sent to.
    case showsSignInControl
    /// Nothing the app can see tells the two pages apart.
    case looksTheSame
    /// The visitor's load failed or timed out, left the site's hosts, met a challenge, or
    /// landed on a page that says nothing about a sign-in.
    case inconclusive

    /// Whether the visitor's page differs from the signed-in one in a way that shows the
    /// session is what makes the page the person's.
    var differsFromSignedIn: Bool {
        switch self {
        case .redirects, .asksForSignIn, .showsSignInControl: true
        case .looksTheSame, .inconclusive: false
        }
    }
}

/// How a visitor's load of a page ended.
typealias VisitorOutcome = PageReadOutcome

/// Loads a signed-in page's address as a visitor would, in a browser that holds no cookie, and
/// compares what comes back with the signed-in page.
///
/// A start page that renders the same for anyone cannot show that a session has lapsed, so
/// the answer decides whether a grant for it can notice a lapse (`SiteGrant.signInControlAbsent`)
/// and whether the page is worth saving as one. The check keeps and returns nothing about the
/// visitor's page beyond the verdict.
enum VisitorCheck {
    static let standardTimeout = HiddenRead.standardTimeout
    /// How long a page that looks the same is given before it is looked at again, for a site
    /// that renders a shell and then sends the visitor to its sign-in page.
    static let standardRecheckDelay: Duration = .seconds(2)

    /// The first of these that applies decides:
    /// - the visitor's load failed or left the site's hosts: `inconclusive`;
    /// - the visitor's page shows a challenge and asks for no sign-in: `inconclusive`, since a
    ///   challenge says the visitor is unverified, not signed out;
    /// - at the signed-in page's origin and path, a page that asks for a sign-in is
    ///   `asksForSignIn`, one that shows a sign-in control the signed-in page lacks is
    ///   `showsSignInControl`, and any other is `looksTheSame`;
    /// - at another origin or path, a page that asks for a sign-in or a user name is
    ///   `redirects`, one that shows a sign-in control the signed-in page lacks is
    ///   `showsSignInControl`, and any other is `inconclusive`, since a consent, locale, or
    ///   landing redirect proves nothing.
    static func verdict(signedIn: PageProbe, visitor: VisitorOutcome) -> VisitorVerdict {
        guard case let .page(page) = visitor else { return .inconclusive }
        let asksForSignIn = SignInRules.asksForSignIn(page)
        if page.hasChallenge, !asksForSignIn { return .inconclusive }
        let addsSignInControl = page.hasSignInControl && !signedIn.hasSignInControl

        if isSamePage(page, signedIn) {
            if asksForSignIn { return .asksForSignIn }
            return addsSignInControl ? .showsSignInControl : .looksTheSame
        }
        if asksForSignIn || SignInRules.showsUserNameField(page) { return .redirects }
        return addsSignInControl ? .showsSignInControl : .inconclusive
    }

    /// Opens `startURL` in a browser of its own on a data store that holds nothing, held to
    /// `browseHosts` and never shown, and returns the verdict on what it shows. A query or
    /// fragment on `startURL` is dropped.
    ///
    /// A page that looks the same is looked at once more after `recheckDelay`, without a new
    /// load, and the second look decides. Both looks, and the load, are held to `timeout`: a
    /// check that does not finish within it is `inconclusive`.
    ///
    /// `pages` serves a simulated site in place of the network.
    @MainActor
    static func run(
        startURL: URL,
        browseHosts: Set<String>,
        signedIn: PageProbe,
        pages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        timeout: Duration = standardTimeout,
        recheckDelay: Duration = standardRecheckDelay
    ) async -> VisitorVerdict {
        guard let host = startURL.host(percentEncoded: false)?.lowercased(),
              let address = HiddenRead.addressWithoutQuery(startURL)
        else { return .inconclusive }

        let verdict = await HiddenRead.withBrowser(
            browseHosts: browseHosts,
            dataStore: .nonPersistent(),
            pages: pages,
            settling: settling,
            timeout: timeout
        ) { browser in
            await look(at: address, in: browser, signedIn: signedIn, recheckDelay: recheckDelay)
        }
        AppLog.notice(.sites, "visitor check for \(host): \(verdict.rawValue)")
        return verdict
    }

    @MainActor
    private static func look(
        at url: URL,
        in browser: SiteBrowser,
        signedIn: PageProbe,
        recheckDelay: Duration
    ) async -> VisitorVerdict {
        let first = verdict(signedIn: signedIn, visitor: await HiddenRead.read(url, in: browser))
        guard first == .looksTheSame else { return first }
        // A navigation the browser refused during the wait was the page leaving the site's hosts.
        let refused = browser.refusedNavigations
        do {
            try await Task.sleep(for: recheckDelay)
            // A page the wait left in the middle of a navigation is read once that has settled; a
            // page that only keeps changing is read as it is.
            if browser.webView.isLoading { try await browser.settleLoadedPage() }
            let page = try await SignInBroker(browser: browser).probe()
            guard browser.refusedNavigations == refused else { return .inconclusive }
            return verdict(signedIn: signedIn, visitor: .page(page))
        } catch {
            return .inconclusive
        }
    }

    /// Whether two probes are of the same origin and path, a path being the same when its
    /// percent-decoded forms are.
    private static func isSamePage(_ page: PageProbe, _ other: PageProbe) -> Bool {
        guard page.origin == other.origin else { return false }
        if page.path == other.path { return true }
        guard let decoded = page.path.removingPercentEncoding,
              let otherDecoded = other.path.removingPercentEncoding
        else { return false }
        return decoded == otherDecoded
    }
}
