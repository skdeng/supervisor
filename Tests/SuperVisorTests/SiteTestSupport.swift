import Foundation
import WebKit

@testable import SuperVisor

extension SiteBrowser.Settling {
    /// Short polls for tests whose pages hold still; the limits are the standard ones.
    static let fast = SiteBrowser.Settling(
        pollInterval: .milliseconds(40),
        stablePolls: 2,
        settleLimit: .seconds(5),
        totalLimit: .seconds(30),
        actionGrace: .seconds(1.5),
        scriptTimeout: .seconds(10)
    )
}

/// An in-memory web site: it answers each navigation a simulated browser makes and keeps a log
/// of what was asked, so a test can say what the page asked the site for and what it sent.
@MainActor
final class TestSite {
    struct Request: Equatable {
        let method: String
        let host: String
        let path: String
        /// The decoded fields of a form body, or of the query of a GET.
        let fields: [String: String]

        var isPost: Bool { method == "POST" }
    }

    typealias Handler = @MainActor (Request) -> String?

    private(set) var requests: [Request] = []
    private var handlers: [String: Handler] = [:]

    /// Serves `handler`'s page for `method` requests to `host` and `path`.
    func route(
        _ path: String,
        method: String = "GET",
        host: String = "example.com",
        _ handler: @escaping Handler
    ) {
        handlers["\(method) \(host)\(path)"] = handler
    }

    func route(_ path: String, method: String = "GET", host: String = "example.com", page: String) {
        route(path, method: method, host: host) { _ in page }
    }

    /// The seam a simulated browser is given.
    func answer(_ urlRequest: URLRequest) -> String? {
        guard let url = urlRequest.url else { return nil }
        let request = Request(
            method: urlRequest.httpMethod ?? "GET",
            host: url.host(percentEncoded: false) ?? "",
            path: url.path,
            fields: Self.fields(of: urlRequest)
        )
        requests.append(request)
        return handlers["\(request.method) \(request.host)\(request.path)"]?(request)
    }

    var posts: [Request] { requests.filter(\.isPost) }

    func requests(to path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    func forgetRequests() {
        requests.removeAll()
    }

    private static func fields(of request: URLRequest) -> [String: String] {
        var text = ""
        if let body = request.httpBody {
            text = String(decoding: body, as: UTF8.self)
        } else if let query = request.url?.query {
            text = query
        }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            func decode(_ part: Substring) -> String {
                part.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(part)
            }
            fields[decode(name)] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return fields
    }
}

/// Small pages for the simulated sites.
enum TestPages {
    static func page(_ title: String, _ body: String, script: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>\
        <body>\(body)\(script.isEmpty ? "" : "<script>\(script)</script>")</body></html>
        """
    }

    /// A page that moves the browser on by script, the way a site's redirect after sign-in does.
    static func redirect(to path: String) -> String {
        page("Redirecting", "Redirecting", script: "location.replace('\(path)')")
    }
}

/// A bank-like site on `example.com` with several kinds of sign-in, switched by its properties.
///
/// The start page is `/account`; signed out it sends the browser to `/login`.
///
/// Its routes hold it `unowned`, so a test keeps the instance alive for as long as a browser
/// may load from its site: one dropped early, as by binding it to `_` when destructuring a
/// fixture tuple, crashes the run at the next page load with "Attempted to read an unowned
/// reference".
@MainActor
final class TestBank {
    enum Flow {
        /// One page asks for the username and password together.
        case onePage
        /// One page asks for the username, a second for the password.
        case twoStep
    }

    let site = TestSite()
    let username = "alice@example.com"
    /// Unique to the instance, so a test can look for it in every string the code produces.
    let password = "Pw-" + UUID().uuidString.lowercased()
    let code = "482910"

    var flow: Flow = .onePage {
        didSet { install() }
    }
    /// A code is asked for after the password.
    var requiresCode = false {
        didSet { install() }
    }
    /// A page that shows a captcha frame is the login page.
    var showsChallenge = false {
        didSet { install() }
    }
    /// The login page stays whatever is submitted.
    var neverSignsIn = false {
        didSet { install() }
    }
    /// A failed sign-in shows the login page where the form was posted instead of sending the
    /// browser back to it.
    var rendersFailureInPlace = false {
        didSet { install() }
    }
    /// The start page sends the browser to the login page even after a sign-in, as a site does
    /// whose session does not hold.
    var startPageIgnoresSession = false {
        didSet { install() }
    }
    /// Where a correct sign-in sends the browser.
    var postLoginLocation = "/home" {
        didSet { install() }
    }
    /// Markup added to the login page, such as a challenge widget.
    var extraLoginMarkup = "" {
        didSet { install() }
    }
    /// After a correct password the site asks for it again, on a page that is not the login page.
    var asksToConfirm = false {
        didSet { install() }
    }
    /// The name, id, and autocomplete token the username field carries.
    var usernameFieldName = "username" {
        didSet { install() }
    }
    var usernameFieldID = "user" {
        didSet { install() }
    }
    var usernameAutocomplete = "username" {
        didSet { install() }
    }
    /// A signed-out start page is a public page with no sign-in form, as a site shows to a
    /// visitor who has not signed in.
    var startPageIsPublic = false {
        didSet { install() }
    }
    /// In the two-step flow, the page after the username is a challenge, and the password page
    /// is reached only by leaving it.
    var challengeBetweenSteps = false {
        didSet { install() }
    }
    /// Where the login form sends its fields.
    var formAction = "/session" {
        didSet { install() }
    }
    var formMethod = "post" {
        didSet { install() }
    }
    private(set) var signedIn = false
    private var identified = false
    private var passwordAccepted = false

    init() {
        install()
    }

    func markSignedIn() {
        signedIn = true
    }

    func signOut() {
        signedIn = false
        identified = false
        passwordAccepted = false
    }

    // MARK: Pages

    private var credentials: String {
        """
        <input type="text" id="\(usernameFieldID)" name="\(usernameFieldName)" autocomplete="\(usernameAutocomplete)">
        <input type="password" id="pass" name="password" autocomplete="current-password">
        """
    }

    private var challenge: String {
        (showsChallenge ? "<iframe src=\"https://www.recaptcha.net/recaptcha/api2/anchor\"></iframe>" : "")
            + extraLoginMarkup
    }

    private func failedLogin() -> String {
        rendersFailureInPlace ? loginPage() : TestPages.redirect(to: "/login")
    }

    private func loginPage() -> String {
        let fields: String
        let action: String
        switch flow {
        case .onePage:
            fields = credentials
            action = formAction
        case .twoStep:
            fields = """
                <input type="text" id="\(usernameFieldID)" name="\(usernameFieldName)" autocomplete="\(usernameAutocomplete)">
                """
            action = "/identify"
        }
        return TestPages.page("Sign in", """
            <h1>Sign in</h1>\(challenge)
            <form method="\(formMethod)" action="\(action)">\(fields)<button type="submit">Sign in</button></form>
            """)
    }

    private var passwordPage: String {
        TestPages.page("Password", """
            <h1>Password</h1>
            <form method="post" action="\(formAction)">
            <input type="password" id="pass" name="password" autocomplete="current-password">
            <button type="submit">Continue</button></form>
            """)
    }

    private var verifyPage: String {
        TestPages.page("Verify", """
            <h1>Verify</h1>
            <form method="post" action="/verify">
            <input type="text" id="otp" name="otp" autocomplete="one-time-code" inputmode="numeric" maxlength="6">
            <button type="submit">Verify</button></form>
            """)
    }

    private var confirmPage: String {
        TestPages.page("Confirm", """
            <h1>Confirm it is you</h1>
            <form method="post" action="/confirm">
            <input type="password" id="again" name="password" autocomplete="current-password">
            <button type="submit">Confirm</button></form>
            """)
    }

    private var publicPage: String {
        TestPages.page("Welcome", "<h1>Welcome</h1><p>Open an account today.</p><a href=\"/login\">Sign in here</a>")
    }

    private var challengePage: String {
        TestPages.page("Check", """
            <h1>Check</h1><div class="captcha-box" style="width:300px;height:80px">Prove you are a person</div>
            """)
    }

    private var accountPage: String {
        TestPages.page("Account", """
            <h1>Account</h1><p>Card on file: Amex ending 1001</p>
            <a href="/cards">Cards</a> <a href="/statements">Statements</a>
            <a href="/logout">Sign out</a> <a href="https://evil.test/phish">Offers</a>
            """)
    }

    // MARK: Routes

    private func finishLogin() -> String {
        if asksToConfirm {
            signedIn = true
            return TestPages.redirect(to: "/confirm")
        }
        signedIn = true
        return TestPages.redirect(to: postLoginLocation)
    }

    private func install() {
        site.route("/account") { [unowned self] _ in
            if signedIn && !startPageIgnoresSession { return accountPage }
            return startPageIsPublic ? publicPage : TestPages.redirect(to: "/login")
        }
        site.route("/home") { [unowned self] _ in
            signedIn ? accountPage : TestPages.redirect(to: "/login")
        }
        site.route("/login") { [unowned self] _ in loginPage() }
        site.route("/password") { [unowned self] _ in passwordPage }
        site.route("/challenge") { [unowned self] _ in challengePage }
        site.route("/verify") { [unowned self] _ in verifyPage }
        site.route("/confirm") { [unowned self] _ in confirmPage }
        site.route("/cards", page: TestPages.page("Cards", "<p>Visa and Amex</p><a href=\"/account\">Back</a>"))
        site.route("/statements", page: TestPages.page("Statements", "<p>No statements</p>"))

        site.route("/identify", method: "POST") { [unowned self] request in
            guard request.fields[usernameFieldName] == username else { return failedLogin() }
            identified = true
            return TestPages.redirect(to: challengeBetweenSteps ? "/challenge" : "/password")
        }
        site.route("/session", method: "POST") { [unowned self] request in
            let nameOK = flow == .twoStep ? identified : request.fields[usernameFieldName] == username
            guard !neverSignsIn, nameOK, request.fields["password"] == password else {
                return failedLogin()
            }
            if requiresCode {
                passwordAccepted = true
                return TestPages.redirect(to: "/verify")
            }
            return finishLogin()
        }
        site.route("/verify", method: "POST") { [unowned self] request in
            guard passwordAccepted, request.fields["otp"] == code else { return verifyPage }
            return finishLogin()
        }
        site.route("/confirm", method: "POST") { _ in TestPages.page("Confirmed", "Confirmed") }
    }
}

/// A gate a test opens when it is ready to let a waiting code source answer.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Sign-in code sources for tests, recording what was asked of them.
///
/// Message baselines count up from 100, one per request, so a test can tell which request a
/// code was read after.
final class CodeStub: @unchecked Sendable {
    static let sampleKey = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    private let lock = NSLock()
    private var log: [String] = []
    private var sinceDates: [Date] = []
    private var nextBaseline: Int64 = 100

    let authenticatorCode: String?
    let textedCode: String?
    let emailedCode: String?
    let firstText: (code: String, sender: String)?
    let baselineAvailable: Bool
    /// When set, a request for a texted code waits at this gate before it answers.
    let textedGate: TestGate?
    /// A request for a texted or emailed code never answers.
    let hangs: Bool

    init(
        authenticator: String? = "482910",
        texted: String? = "482910",
        emailed: String? = "482910",
        firstText: (code: String, sender: String)? = ("482910", "24273"),
        baselineAvailable: Bool = true,
        textedGate: TestGate? = nil,
        hangs: Bool = false
    ) {
        authenticatorCode = authenticator
        textedCode = texted
        emailedCode = emailed
        self.firstText = firstText
        self.baselineAvailable = baselineAvailable
        self.textedGate = textedGate
        self.hangs = hangs
    }

    /// Every request made, in order.
    var calls: [String] { lock.withLock { log } }

    /// The `since` of each emailed-code request, in order.
    var emailedSince: [Date] { lock.withLock { sinceDates } }

    private func note(_ line: String) {
        lock.withLock { log.append(line) }
    }

    private func takeBaseline() -> Int64 {
        lock.withLock {
            defer { nextBaseline += 1 }
            return nextBaseline
        }
    }

    private func hang() async {
        try? await Task.sleep(for: .seconds(3_600))
    }

    var codes: SignInCodes {
        SignInCodes(
            authenticator: { [self] key in
                note("authenticator \(key)")
                return authenticatorCode
            },
            texted: { [self] sender, after in
                note("texted \(sender) \(after)")
                if hangs { await hang() }
                await textedGate?.wait()
                return textedCode
            },
            emailed: { [self] sender, since in
                note("emailed \(sender)")
                lock.withLock { sinceDates.append(since) }
                if hangs { await hang() }
                return emailedCode
            },
            messageBaseline: { [self] in
                guard baselineAvailable else { return nil }
                return takeBaseline()
            },
            firstTextedCode: { [self] after in
                note("first \(after)")
                if hangs { await hang() }
                return firstText
            }
        )
    }
}
