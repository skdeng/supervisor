import Foundation

/// Where sign-in codes come from. Each closure returns nil when no code could be had.
struct SignInCodes: Sendable {
    /// The current code of an authenticator key.
    var authenticator: @Sendable (_ key: String) -> String?
    /// A code texted by `sender` after the message with row id `afterRowID`.
    var texted: @Sendable (_ sender: String, _ afterRowID: Int64) async -> String?
    /// A code emailed by `sender` at or after `since`, the moment before it was requested.
    var emailed: @Sendable (_ sender: String, _ since: Date) async -> String?
    /// The row id of the newest text, taken before a code is requested.
    var messageBaseline: @Sendable () -> Int64?
    /// Enrollment only: the first code texted after the baseline, with who sent it.
    var firstTextedCode: @Sendable (_ afterRowID: Int64) async -> (code: String, sender: String)?
}

enum SignInOutcome: Equatable, Sendable {
    case signedIn
    /// The app stopped and must not try again by itself.
    case needsPerson(Reason)
    /// The sign-in was cut short, by the task being cancelled or the browser closed under it.
    /// Nothing says whether the site would have let the app in.
    case interrupted

    enum Reason: String, Sendable {
        case noRecordedSteps
        case unrecognisedPage
        case challenge
        case noCode
        case pageMoved
        case tooManySteps
        case stillSignedOut
        /// A page could not be loaded, or took too long.
        case loadFailed
        /// A saved secret would have been filled on a host the grant does not fill on.
        case unvettedHost
    }

    /// How the attempt counts against the site, or nil for an attempt that does not count.
    ///
    /// A site that wants something only the person can give (a challenge answered, a page
    /// recognised again, a session that did not take) stops the app until the person signs in.
    /// A code that did not arrive, a page that moved, or one that did not load may pass.
    var attemptOutcome: SignInAttempts.AttemptOutcome? {
        switch self {
        case .signedIn:
            return .succeeded
        case .interrupted:
            return nil
        case let .needsPerson(reason):
            switch reason {
            case .noCode, .pageMoved, .loadFailed: return .transientFailure
            case .noRecordedSteps, .unrecognisedPage, .challenge, .tooManySteps, .stillSignedOut,
                 .unvettedHost:
                return .needsPerson
            }
        }
    }
}

/// What an enrollment sign-in did: the fills it made, the code sender it learned, and why it
/// stopped. A nil `stoppedBecause` means it ran out of fields to fill.
struct AssistedSignIn: Equatable, Sendable {
    let steps: [SignInStep]
    let learnedCodeSender: String?
    let stoppedBecause: SignInOutcome.Reason?
    /// The hosts the filled forms submit to.
    let submissionHosts: [String]
}

/// A field on a page as the broker saw it: how it is identified, and the hints that mark what it
/// asks for.
struct ProbedField: Equatable, Sendable {
    let key: FieldKey
    /// The `inputmode` attribute, lowercased.
    let inputMode: String
    let maxLength: Int?
    /// Which form on the page owns the field, numbered in the order the probe met them; nil for
    /// a field outside any form.
    let form: Int?
    /// Whether the owning form has a submit control.
    let formHasSubmit: Bool

    init(
        key: FieldKey,
        inputMode: String,
        maxLength: Int?,
        form: Int? = nil,
        formHasSubmit: Bool = false
    ) {
        self.key = key
        self.inputMode = inputMode
        self.maxLength = maxLength
        self.form = form
        self.formHasSubmit = formHasSubmit
    }

    var isPassword: Bool { key.type == "password" }
    var isTextLike: Bool { ["", "text", "email", "tel"].contains(key.type) }
}

/// What a page shows, read in one script call.
struct PageProbe: Equatable, Sendable {
    let origin: String
    let path: String
    /// A secure context in the top frame, which is where the broker works.
    let isSecureTopFrame: Bool
    /// A challenge a person has to answer is on the page: a visible widget of a known kind, not
    /// the floating badge of a challenge that runs unseen.
    let hasChallenge: Bool
    /// The visible, enabled, writable inputs that take text, in document order.
    let fields: [ProbedField]
    /// A visible link or button reads `sign out`, `log out`, or the like.
    let hasSignOutControl: Bool
    /// A visible link or button reads `sign in`, `log in`, or the like. A page can show both
    /// kinds of control.
    let hasSignInControl: Bool
    /// A visible frame of at least 200 by 100 points whose address reads as a sign-in.
    let hasLoginFrame: Bool

    var hasVisiblePassword: Bool { fields.contains(where: \.isPassword) }
    var hasCodeField: Bool { fields.contains(where: SignInRules.isCodeField) }

    static let maximumFields = 40
    static let maximumAttributeLength = 200

    init(
        origin: String,
        path: String,
        isSecureTopFrame: Bool,
        hasChallenge: Bool,
        fields: [ProbedField],
        hasSignOutControl: Bool = false,
        hasSignInControl: Bool = false,
        hasLoginFrame: Bool = false
    ) {
        self.origin = origin
        self.path = path
        self.isSecureTopFrame = isSecureTopFrame
        self.hasChallenge = hasChallenge
        self.fields = fields
        self.hasSignOutControl = hasSignOutControl
        self.hasSignInControl = hasSignInControl
        self.hasLoginFrame = hasLoginFrame
    }

    /// Reads the script's result; nil when it is not the shape the script returns.
    init?(_ value: ScriptValue) {
        guard let origin = value["origin"]?.string,
              let path = value["path"]?.string,
              let secure = value["secure"]?.bool,
              let top = value["top"]?.bool,
              let challenge = value["challenge"]?.bool,
              let signOut = value["signOut"]?.bool,
              let signIn = value["signIn"]?.bool,
              let loginFrame = value["loginFrame"]?.bool,
              let inputs = value["inputs"]?.array
        else { return nil }

        func text(_ field: ScriptValue, _ name: String) -> String? {
            field[name]?.string.map { String($0.prefix(Self.maximumAttributeLength)) }
        }
        var fields: [ProbedField] = []
        for input in inputs.prefix(Self.maximumFields) {
            guard let name = text(input, "name"),
                  let id = text(input, "id"),
                  let autocomplete = text(input, "autocomplete"),
                  let type = text(input, "type"),
                  let inputMode = text(input, "inputmode"),
                  let form = input["form"]?.int,
                  let formSubmit = input["formSubmit"]?.bool
            else { return nil }
            fields.append(ProbedField(
                key: FieldKey(name: name, id: id, autocomplete: autocomplete, type: type),
                inputMode: inputMode,
                maxLength: input["maxlength"]?.int.flatMap { $0 >= 0 ? $0 : nil },
                form: form >= 0 ? form : nil,
                formHasSubmit: formSubmit
            ))
        }
        self.init(
            origin: String(origin.prefix(Self.maximumAttributeLength)),
            path: String(path.prefix(2_048)),
            isSecureTopFrame: secure && top,
            hasChallenge: challenge,
            fields: fields,
            hasSignOutControl: signOut,
            hasSignInControl: signIn,
            hasLoginFrame: loginFrame
        )
    }
}

/// The rules the broker decides by, free of any page: which recorded step a page matches, what
/// the enrollment sign-in fills on a page, whether a page is a signed-in one, and what a code
/// looks like.
enum SignInRules {
    private static let codePattern = #"\A[0-9]{4,8}\z"#

    struct Pick: Equatable, Sendable {
        let kind: SignInStep.Kind
        let field: ProbedField
    }

    enum Decision: Equatable, Sendable {
        case fill([Pick])
        /// Nil means no field was left to fill.
        case stop(SignInOutcome.Reason?)
    }

    /// The name or id pattern that marks a field as taking a user name. `SiteBrowser`'s credential
    /// script restates `looksLikeUsername`, `isCodeField`, and `isMaskedNonPassword` in script
    /// form, built from this pattern and the word lists below; a change to any of those rules
    /// changes the script too, and a test holds their verdicts together.
    static let usernamePattern = #"user|email|login|member|account"#

    /// Words in a field's name or id that mark it as asking for a code.
    static let codeWords: Set<String> = [
        "otp", "code", "token", "pin", "passcode", "totp", "mfa", "2fa", "verification", "verify",
    ]

    /// Words that rule a field out as asking for a sign-in code.
    static let notCodeWords: Set<String> = [
        "zip", "postal", "post", "promo", "coupon", "country", "area", "gift", "discount",
        "referral", "invite", "tracking", "csrf",
    ]

    /// Words that, beside `codeWords`, mark a masked field as holding something other than the
    /// account's password: a PIN, a card's security code, or the answer to a memorable or
    /// security question.
    static let notPasswordWords: Set<String> = ["pin", "cvv", "cvc", "memorable", "answer", "security"]

    /// Whether a password-type field holds a secret other than the account's password: its name
    /// or id holds, as a whole word, one of `codeWords` or `notPasswordWords`, and none of
    /// `notCodeWords`. It is `isCodeField`'s word test applied to masked fields, and
    /// `SiteBrowser`'s credential script restates it.
    static func isMaskedNonPassword(_ key: FieldKey) -> Bool {
        let words = Set([key.name, key.id].flatMap {
            SiteNavigationPolicy.words(in: $0) + SiteNavigationPolicy.words(in: $0, splittingDigits: false)
        })
        guard words.isDisjoint(with: notCodeWords) else { return false }
        return !words.isDisjoint(with: codeWords.union(notPasswordWords))
    }

    // MARK: What to fill

    /// What to fill on a page. A password field comes with the username field of its form; a
    /// page without one asks for a code, a username, or nothing. A kind already filled is never
    /// filled again.
    static func decide(
        page: PageProbe,
        used: Set<SignInStep.Kind>,
        codeKind: SiteGrant.CodeKind
    ) -> Decision {
        let fields = page.fields
        if let password = fields.first(where: \.isPassword) {
            if used.contains(.password) { return .stop(.stillSignedOut) }
            var picks: [Pick] = []
            if !used.contains(.username), let username = usernameField(in: fields, beside: password) {
                picks.append(Pick(kind: .username, field: username))
            }
            picks.append(Pick(kind: .password, field: password))
            return .fill(picks)
        }
        if let code = fields.first(where: isCodeField) {
            if used.contains(.code) { return .stop(.stillSignedOut) }
            if codeKind == .none { return .stop(.noCode) }
            return .fill([Pick(kind: .code, field: code)])
        }
        let textFields = fields.filter(\.isTextLike)
        if let username = usernameField(in: fields, beside: nil) ?? (textFields.count == 1 ? textFields[0] : nil) {
            if used.contains(.username) { return .stop(.stillSignedOut) }
            return .fill([Pick(kind: .username, field: username)])
        }
        return .stop(nil)
    }

    /// The field that takes the username. With a password field on the page, a text field in the
    /// password's form; without one, a text field in a form that has a submit control, when
    /// that choice is clear. Otherwise the first field whose hints say it takes a username.
    private static func usernameField(in fields: [ProbedField], beside password: ProbedField?) -> ProbedField? {
        let textual = textFields(fields)
        var scoped: [ProbedField] = []
        if let password {
            if let form = password.form { scoped = textual.filter { $0.form == form } }
        } else {
            scoped = textual.filter { $0.form != nil && $0.formHasSubmit }
        }
        if let hinted = scoped.first(where: looksLikeUsername) { return hinted }
        if let first = scoped.first, password != nil || scoped.count == 1 { return first }
        return textual.first(where: looksLikeUsername)
    }

    /// The fields that take free text and do not ask for a code.
    private static func textFields(_ fields: [ProbedField]) -> [ProbedField] {
        fields.filter { $0.isTextLike && !isCodeField($0) }
    }

    /// Whether the page shows a field whose hints say it takes a user name or an email address:
    /// the field a sign-in page asks for first.
    static func showsUserNameField(_ page: PageProbe) -> Bool {
        textFields(page.fields).contains(where: looksLikeUsername)
    }

    private static func looksLikeUsername(_ field: ProbedField) -> Bool {
        let key = field.key
        return ["username", "email"].contains(key.autocomplete)
            || key.type == "email"
            || matches(usernamePattern, key.name)
            || matches(usernamePattern, key.id)
    }

    /// Whether a field asks for a sign-in code: its autocomplete token says so; or its name or
    /// id holds a code word and no word that makes it another kind of code (`zip_code`,
    /// `promoCode`); or it takes four to eight digits by `inputmode` and `maxlength`.
    ///
    /// Words are whole words, so `shipping`, `opinion`, `zipcode`, `promocode`, and `verified`
    /// are not code fields.
    static func isCodeField(_ field: ProbedField) -> Bool {
        guard !field.isPassword else { return false }
        let key = field.key
        if key.autocomplete == "one-time-code" { return true }
        let words = Set([key.name, key.id].flatMap {
            SiteNavigationPolicy.words(in: $0) + SiteNavigationPolicy.words(in: $0, splittingDigits: false)
        })
        guard words.isDisjoint(with: notCodeWords) else { return false }
        if !words.isDisjoint(with: codeWords) { return true }
        return field.inputMode == "numeric" && field.maxLength.map { (4...8).contains($0) } == true
    }

    /// Whether the page shows a row of single-character boxes, the way a site asks for a code
    /// one digit to a box. Such boxes often carry no name, token, or input mode that marks
    /// them as a code field.
    static func showsSplitCode(_ page: PageProbe) -> Bool {
        page.fields.filter { !$0.isPassword && $0.maxLength == 1 }.count >= splitCodeBoxes
    }

    /// The fewest single-character boxes that read as a code: the shortest code sites send.
    static let splitCodeBoxes = 4

    /// Whether the page asks the person to sign in: it shows a password field, a field or row
    /// of boxes for a code, or a sign-in frame.
    static func asksForSignIn(_ page: PageProbe) -> Bool {
        page.hasVisiblePassword || page.hasCodeField || page.hasLoginFrame || showsSplitCode(page)
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Whether what a step would record about the page fits the limits a grant holds it to.
    static func isRecordable(_ page: PageProbe) -> Bool {
        guard page.origin.hasPrefix("https://"),
              SiteHost.isValid(String(page.origin.dropFirst("https://".count))),
              page.path.hasPrefix("/"),
              page.path.count <= SiteGrant.maximumStepPathLength
        else { return false }
        return page.fields.allSatisfy { field in
            let key = field.key
            return [key.name, key.id, key.autocomplete, key.type]
                .allSatisfy { $0.count <= SiteGrant.maximumFieldKeyLength }
        }
    }

    // MARK: Matching

    /// The one visible field `step` was recorded for, when the page is the recorded page. The
    /// kinds must agree: a password step takes only a password field and the others never do.
    /// A field matches by the recorded name, or the recorded id, or the recorded autocomplete
    /// token together with the type, each only when recorded. Two matching fields leave the
    /// step unmatched.
    static func visibleField(for step: SignInStep, on page: PageProbe) -> ProbedField? {
        guard step.origin == page.origin, step.path == page.path else { return nil }
        let found = page.fields.filter { field in
            fieldMatches(field.key, recorded: step.field)
                && field.isPassword == (step.kind == .password)
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Whether a page that matches only some of the steps recorded for it has changed since they
    /// were recorded: a recorded field is missing and the page shows a field no matched step
    /// accounts for. A page that shows only the fields of the steps matched (a sign-in that
    /// asks for the password on the page after the username, at one address) is not changed.
    static func isAlteredPage(recordedHere: [SignInStep], matched: [ProbedField], on page: PageProbe) -> Bool {
        guard !matched.isEmpty, matched.count < recordedHere.count else { return false }
        return page.fields.contains { !matched.contains($0) }
    }

    static func fieldMatches(_ actual: FieldKey, recorded: FieldKey) -> Bool {
        if !recorded.name.isEmpty, actual.name == recorded.name { return true }
        if !recorded.id.isEmpty, actual.id == recorded.id { return true }
        return !recorded.autocomplete.isEmpty
            && actual.autocomplete == recorded.autocomplete
            && actual.type == recorded.type
    }

    // MARK: Signed in

    /// Whether the settled page, which is what loading the grant's start page led to, is one a
    /// signed-in session shows. All of these hold: it has the start page's origin and path; it
    /// shows nothing that asks for a sign-in (`isPastSignIn`) and no field a recorded step was
    /// recorded for; when the page the user ended enrollment on had a sign-out control, it has
    /// one too; and when that page lacked a sign-in control that a visitor's copy of it shows
    /// (`SiteGrant.signInControlAbsent`), it shows none.
    static func isSignedIn(page: PageProbe, grant: SiteGrant) -> Bool {
        guard page.isSecureTopFrame,
              isStartPage(page, grant.startURL),
              isPastSignIn(page),
              !grant.signInSteps.contains(where: { visibleField(for: $0, on: page) != nil }),
              !(grant.signInControlAbsent && page.hasSignInControl)
        else { return false }
        return !grant.signOutControlSeen || page.hasSignOutControl
    }

    /// Whether a page shows nothing that asks for a sign-in (`asksForSignIn`) and no challenge
    /// to answer.
    static func isPastSignIn(_ page: PageProbe) -> Bool {
        !asksForSignIn(page) && !page.hasChallenge
    }

    /// Whether the page's origin and path are those of `start`, a path being the same when its
    /// percent-decoded forms are.
    static func isStartPage(_ page: PageProbe, _ start: URL) -> Bool {
        guard let host = start.host(percentEncoded: false)?.lowercased(),
              page.origin == "https://" + host
        else { return false }
        let encoded = start.path(percentEncoded: true)
        let path = encoded.isEmpty ? "/" : encoded
        return page.path == path || page.path.removingPercentEncoding == path.removingPercentEncoding
    }

    // MARK: Codes

    static func validCode(_ code: String) -> String? {
        code.range(of: codePattern, options: .regularExpression) != nil ? code : nil
    }
}

/// Signs in to a site in a `SiteBrowser`, from app code with no model in the loop.
///
/// Two flows share one set of page scripts. The unattended flow signs in only through the
/// steps recorded when the user granted the site: each fill happens on the exact page and into
/// the exact field it was recorded for, and a page it does not recognise stops it. The assisted
/// flow runs while the user watches, finds fields by heuristics, and records what it filled.
/// Passwords and codes reach a page only as script arguments, and appear in no log line and no
/// error.
///
/// Every wait for a code is bounded by `codeWaitLimit`, so a code source that never answers
/// cannot hold a sign-in, or the gate that serialises sign-ins, past it.
@MainActor
final class SignInBroker {
    static let maximumFills = 6
    static let standardCodeWaitLimit: Duration = .seconds(120)

    let browser: SiteBrowser
    private let codeWaitLimit: Duration
    private let now: () -> Date

    init(
        browser: SiteBrowser,
        codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit,
        now: @escaping () -> Date = Date.init
    ) {
        self.browser = browser
        self.codeWaitLimit = codeWaitLimit
        self.now = now
    }

    // MARK: Unattended

    /// Whether the page that is open is a signed-in page of the grant's site (see
    /// `SignInRules.isSignedIn`).
    func isSignedIn(_ grant: SiteGrant) async throws -> Bool {
        SignInRules.isSignedIn(page: try await probe(), grant: grant)
    }

    /// Signs in through `grant.signInSteps`, starting from the page that is open. At the end the
    /// start page is loaded to confirm the session holds.
    func signIn(with grant: SiteGrant, codes: SignInCodes) async -> SignInOutcome {
        guard !grant.signInSteps.isEmpty else { return .needsPerson(.noRecordedSteps) }
        do {
            return try await runSignIn(grant, codes: codes)
        } catch {
            if Self.isInterruption(error) { return .interrupted }
            AppLog.notice(.sites, "sign-in stopped by a page failure: \(Self.failureName(error))")
            return .needsPerson(Self.reason(for: error))
        }
    }

    private func runSignIn(_ grant: SiteGrant, codes: SignInCodes) async throws -> SignInOutcome {
        var used = Set<SignInStep.Kind>()
        var fills = 0
        var baseline = codes.messageBaseline()
        var requestedAt = now()

        for _ in 0..<Self.maximumFills {
            try Task.checkCancellation()
            let page = try await probe()
            if page.hasChallenge { return .needsPerson(.challenge) }
            guard page.isSecureTopFrame else { return .needsPerson(.pageMoved) }

            let matches = grant.signInSteps.compactMap { step in
                SignInRules.visibleField(for: step, on: page).map { (step: step, field: $0) }
            }
            if matches.isEmpty {
                if page.hasVisiblePassword { return .needsPerson(.unrecognisedPage) }
                return try await confirmSignedIn(grant)
            }
            let recordedHere = grant.signInSteps.filter { $0.origin == page.origin && $0.path == page.path }
            if SignInRules.isAlteredPage(recordedHere: recordedHere, matched: matches.map(\.field), on: page) {
                return .needsPerson(.unrecognisedPage)
            }
            let pending = matches.filter { !used.contains($0.step.kind) }
            if pending.isEmpty { return .needsPerson(.stillSignedOut) }

            let chosen = Self.chosen(from: pending)
            fills += chosen.count
            if fills > Self.maximumFills { return .needsPerson(.tooManySteps) }

            var requests: [FillRequest] = []
            for pick in chosen {
                let value = await value(
                    for: pick.step.kind,
                    grant: grant,
                    baseline: baseline,
                    requestedAt: requestedAt,
                    codes: codes
                )
                try Task.checkCancellation()
                // A wait for a code ends early when the browser closes; that is no missing code.
                if browser.isClosed { return .interrupted }
                guard let value else { return .needsPerson(.noCode) }
                requests.append(FillRequest(kind: pick.step.kind, key: pick.step.field, value: value))
            }

            // A code this submit requests arrives after the baseline taken here, so the next
            // step reads no earlier code.
            baseline = codes.messageBaseline()
            requestedAt = now()
            let mark = browser.markAction()
            let status = try await fill(
                origin: page.origin,
                path: page.path,
                allowedHosts: grant.fillHosts,
                requests: requests
            )
            guard case .filled = status else { return .needsPerson(Self.reason(for: status)) }
            used.formUnion(chosen.map(\.step.kind))
            try await browser.settleAfterAction(since: mark)
        }
        return .needsPerson(.tooManySteps)
    }

    private func confirmSignedIn(_ grant: SiteGrant) async throws -> SignInOutcome {
        _ = try await browser.open(grant.startURL)
        return try await isSignedIn(grant) ? .signedIn : .needsPerson(.stillSignedOut)
    }

    /// Username and password are filled together when both are pending; otherwise one step at
    /// a time.
    private static func chosen(
        from pending: [(step: SignInStep, field: ProbedField)]
    ) -> [(step: SignInStep, field: ProbedField)] {
        let username = pending.first { $0.step.kind == .username }
        let password = pending.first { $0.step.kind == .password }
        if let username, let password { return [username, password] }
        return [pending[0]]
    }

    private func value(
        for kind: SignInStep.Kind,
        grant: SiteGrant,
        baseline: Int64?,
        requestedAt: Date,
        codes: SignInCodes
    ) async -> String? {
        switch kind {
        case .username:
            return grant.username
        case .password:
            return grant.password
        case .code:
            let code: String?
            switch grant.codeKind {
            case .none:
                code = nil
            case .authenticator:
                code = grant.authenticatorKey.flatMap(codes.authenticator)
            case .text:
                guard let sender = grant.codeSender, let baseline else { return nil }
                code = await bounded { await codes.texted(sender, baseline) }
            case .email:
                guard let sender = grant.codeSender else { return nil }
                code = await bounded { await codes.emailed(sender, requestedAt) }
            }
            return code.flatMap(SignInRules.validCode)
        }
    }

    // MARK: Assisted

    /// Signs in while the user watches, finding fields by what they look like and recording
    /// each fill. It stops at a challenge or a page it does not recognise, leaving the rest to
    /// the user in the page.
    func assistedSignIn(
        username: String,
        password: String,
        authenticatorKey: String?,
        codeKind: SiteGrant.CodeKind,
        codeSender: String?,
        codes: SignInCodes
    ) async -> AssistedSignIn {
        let session = AssistedSignInSession(
            broker: self,
            username: username,
            password: password,
            authenticatorKey: authenticatorKey,
            codeKind: codeKind,
            codeSender: codeSender,
            codes: codes
        )
        let stopped = await session.run()
        return session.result(stoppedBecause: stopped)
    }

    // MARK: Waiting for codes

    /// The answer of `operation`, or nil when `codeWaitLimit` passes first, the task is
    /// cancelled, or the browser closes. However the wait ends, the operation's task is
    /// cancelled, so a code source that polls stops with it.
    fileprivate func bounded(_ operation: @escaping @Sendable () async -> String?) async -> String? {
        let race = CodeRace()
        let limit = codeWaitLimit
        let closeToken = browser.whenClosed { race.finish(nil) }
        defer { browser.withdrawCloseHandler(closeToken) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let timer = Task {
                    try? await Task.sleep(for: limit)
                    race.finish(nil)
                }
                let work = Task { race.finish(await operation()) }
                race.install(continuation, tasks: [timer, work])
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    /// Resolves a wait for a code once, whichever of the answer, the time limit, cancellation,
    /// and the browser closing comes first, and cancels the tasks the wait started.
    private final class CodeRace: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var isFinished = false
        private var result: String?

        func install(_ continuation: CheckedContinuation<String?, Never>, tasks: [Task<Void, Never>]) {
            lock.lock()
            if isFinished {
                let result = result
                lock.unlock()
                tasks.forEach { $0.cancel() }
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            self.tasks = tasks
            lock.unlock()
        }

        func finish(_ value: String?) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            result = value
            let continuation = continuation
            let tasks = tasks
            self.continuation = nil
            self.tasks = []
            lock.unlock()
            tasks.forEach { $0.cancel() }
            continuation?.resume(returning: value)
        }
    }

    // MARK: Failures

    /// Whether `error` is the sign-in being cut short rather than failing.
    static func isInterruption(_ error: any Error) -> Bool {
        error is CancellationError || (error as? SiteBrowser.Failure) == .closed
    }

    /// Why a page failure stopped a sign-in.
    fileprivate static func reason(for error: any Error) -> SignInOutcome.Reason {
        switch error as? SiteBrowser.Failure {
        case .leftSite?, .notAllowed?: .pageMoved
        default: .loadFailed
        }
    }

    private static func reason(for status: FillStatus) -> SignInOutcome.Reason {
        switch status {
        case .moved: .pageMoved
        case .filled, .missing, .ambiguous, .foreignAction, .blockedGet, .submitDisabled, .noSubmit:
            .unrecognisedPage
        }
    }

    fileprivate static func failureName(_ error: any Error) -> String {
        (error as? SiteBrowser.Failure)?.caseName ?? (error is CancellationError ? "cancelled" : "other")
    }

    // MARK: Page scripts

    /// One value to place in one field. It carries a secret, so no rendering of it shows the value.
    struct FillRequest: Sendable {
        let kind: SignInStep.Kind
        let key: FieldKey
        let value: String
    }

    enum FillStatus: Equatable, Sendable {
        /// Every field was filled and the form submitted; `actionHost` is where the form sends.
        case filled(actionHost: String?)
        /// The page was not the one expected, so nothing was touched.
        case moved
        case missing
        case ambiguous
        /// The form submits somewhere that is not a fill host, so nothing was submitted.
        case foreignAction
        /// The form would have sent its fields in the address and nothing on the page handled the
        /// submission, so nothing was submitted.
        case blockedGet
        /// The form's submit controls are all disabled, so nothing was submitted.
        case submitDisabled
        /// The fields were filled but no way to submit them was found.
        case noSubmit
    }

    /// Whether the page shows exactly one visible password field matching `key`, and it holds
    /// no value. Only the emptiness is read, never the value.
    func isPasswordFieldEmpty(_ key: FieldKey) async throws -> Bool {
        let value = try await browser.run(Scripts.passwordFieldEmpty, arguments: [
            "key": ["name": key.name, "id": key.id, "autocomplete": key.autocomplete, "type": key.type],
        ])
        return value.bool == true
    }

    /// Reads what the page shows.
    func probe() async throws -> PageProbe {
        guard let page = PageProbe(try await browser.run(Scripts.probe)) else {
            throw SiteBrowser.Failure.loadFailed
        }
        return page
    }

    /// Fills `requests` and submits, all in one script call that first checks the page is still
    /// the one expected: same origin and path, a secure context, the top frame. Values travel
    /// as arguments. `allowedHosts` limits where the form may send; nil leaves that open.
    func fill(
        origin: String,
        path: String,
        allowedHosts: [String]?,
        requests: [FillRequest]
    ) async throws -> FillStatus {
        let fills: [[String: Any]] = requests.map { request in
            [
                "kind": request.kind.rawValue,
                "value": request.value,
                "key": [
                    "name": request.key.name,
                    "id": request.key.id,
                    "autocomplete": request.key.autocomplete,
                    "type": request.key.type,
                ],
            ]
        }
        let arguments: [String: Any] = [
            "origin": origin,
            "path": path,
            "hosts": allowedHosts ?? NSNull(),
            "fills": fills,
        ]
        let value = try await browser.run(Scripts.fill, arguments: arguments)
        switch value["status"]?.string {
        case "ok":
            let host = value["actionHost"]?.string
            return .filled(actionHost: host.flatMap { SiteHost.isValid($0) ? $0 : nil })
        case "moved": return .moved
        case "missing": return .missing
        case "ambiguous": return .ambiguous
        case "foreign": return .foreignAction
        case "blocked": return .blockedGet
        case "disabled": return .submitDisabled
        case "nosubmit": return .noSubmit
        default: throw SiteBrowser.Failure.loadFailed
        }
    }

    private enum Scripts {
        /// Helpers both scripts use. The page's own scripts run in another world and cannot
        /// reach these, and the prototypes called here are the browser's own, so a field named
        /// like a method of its form shadows nothing.
        static let common = """
            const skippedTypes = ['hidden', 'submit', 'button', 'image', 'reset', 'checkbox', 'radio', 'file', 'range', 'color'];
            const getAttr = (element, name) => Element.prototype.getAttribute.call(element, name);
            const attr = (element, name) => getAttr(element, name) || '';
            const isVisible = (element) => {
              const style = getComputedStyle(element);
              if (style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') return false;
              if (parseFloat(style.opacity) === 0) return false;
              const rect = element.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };
            const fillableInputs = () => Array.prototype.filter.call(document.querySelectorAll('input'), (element) =>
              !skippedTypes.includes(attr(element, 'type').toLowerCase()) && !element.disabled && !element.readOnly && isVisible(element));
            const inputProto = (name) => Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, name);
            const formProto = (name) => Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, name);
            const formOf = (element) => inputProto('form').get.call(element);
            const controlsOf = (form) => Array.prototype.slice.call(formProto('elements').get.call(form));
            const isSubmitControl = (control) => (control.tagName === 'BUTTON' || control.tagName === 'INPUT') && control.type === 'submit';
            const matches = (element, key) => {
              if (key.name !== '' && attr(element, 'name') === key.name) return true;
              if (key.id !== '' && attr(element, 'id') === key.id) return true;
              return key.autocomplete !== '' && attr(element, 'autocomplete').toLowerCase() === key.autocomplete
                && attr(element, 'type').toLowerCase() === key.type;
            };
            """

        static let passwordFieldEmpty = common + """

            const found = fillableInputs().filter((element) => element.type === 'password' && matches(element, key));
            return found.length === 1 && inputProto('value').get.call(found[0]) === '';
            """

        static let probe = common + """

            const bigEnough = (element, width, height) => {
              const rect = element.getBoundingClientRect();
              return rect.width >= width && rect.height >= height;
            };
            const inBadge = (element) => element.closest('.grecaptcha-badge') !== null;
            const frameLocation = (frame) => {
              if (attr(frame, 'src') === '') return '';
              try {
                const url = new URL(attr(frame, 'src'), document.baseURI);
                return (url.hostname + url.pathname).toLowerCase();
              } catch (error) {
                return '';
              }
            };
            const challengeWords = ['recaptcha', 'hcaptcha', 'turnstile', 'arkoselabs', 'funcaptcha'];
            const loginWords = ['login', 'signin', 'sign-in', 'auth', 'sso', 'oauth'];
            let challenge = false;
            let loginFrame = false;
            for (const frame of document.querySelectorAll('iframe')) {
              if (!isVisible(frame)) continue;
              const where = frameLocation(frame);
              if (!challenge && bigEnough(frame, 150, 60) && !inBadge(frame)
                && challengeWords.some((word) => where.includes(word))) challenge = true;
              if (!loginFrame && bigEnough(frame, 200, 100)
                && loginWords.some((word) => where.includes(word))) loginFrame = true;
            }
            if (!challenge) {
              for (const element of document.querySelectorAll('[id*="captcha" i], [class*="captcha" i]')) {
                if (inBadge(element) || !isVisible(element) || !bigEnough(element, 150, 60)) continue;
                challenge = true;
                break;
              }
            }

            const signOutLabels = ['sign out', 'log out', 'logout', 'signout', 'sign off', 'log off'];
            const signInLabels = ['sign in', 'log in', 'login', 'signin', 'sign on', 'log on'];
            let signOut = false;
            let signIn = false;
            const controls = document.querySelectorAll('a, button, [role="button"], [role="link"], input[type="button"], input[type="submit"]');
            for (let index = 0; index < controls.length && index < 3000 && !(signOut && signIn); index++) {
              const control = controls[index];
              const raw = control.tagName === 'INPUT' ? attr(control, 'value') : (control.innerText || control.textContent || '');
              const text = raw.replace(/\\s+/g, ' ').trim().toLowerCase();
              if (!signOut && signOutLabels.includes(text) && isVisible(control)) signOut = true;
              if (!signIn && signInLabels.includes(text) && isVisible(control)) signIn = true;
            }

            const cut = (value) => value.slice(0, 200);
            const formIndexes = new Map();
            const indexOfForm = (form) => {
              if (!formIndexes.has(form)) formIndexes.set(form, formIndexes.size);
              return formIndexes.get(form);
            };
            const inputs = [];
            for (const element of fillableInputs()) {
              if (inputs.length >= 40) break;
              const maxLength = parseInt(attr(element, 'maxlength'), 10);
              const form = formOf(element);
              inputs.push({
                name: cut(attr(element, 'name')),
                id: cut(attr(element, 'id')),
                autocomplete: cut(attr(element, 'autocomplete').toLowerCase()),
                type: cut(attr(element, 'type').toLowerCase()),
                inputmode: cut(attr(element, 'inputmode').toLowerCase()),
                maxlength: Number.isFinite(maxLength) ? maxLength : -1,
                form: form ? indexOfForm(form) : -1,
                formSubmit: form ? controlsOf(form).some(isSubmitControl) : false
              });
            }
            return {
              origin: location.origin,
              path: location.pathname,
              secure: isSecureContext,
              top: window.top === window.self,
              challenge: challenge,
              signOut: signOut,
              signIn: signIn,
              loginFrame: loginFrame,
              inputs: inputs
            };
            """

        static let fill = common + """

            const result = (status, actionHost) => ({ status: status, actionHost: actionHost || null });
            try {
              const onPage = () => location.origin === origin && location.pathname === path
                && isSecureContext && window.top === window.self;
              if (!onPage()) return result('moved');

              const inputs = fillableInputs();
              const targets = [];
              for (const fill of fills) {
                const found = inputs.filter((element) => matches(element, fill.key)
                  && ((element.type === 'password') === (fill.kind === 'password')));
                if (found.length === 0) return result('missing');
                if (found.length > 1) return result('ambiguous');
                targets.push({ element: found[0], value: fill.value });
              }

              const last = targets[targets.length - 1].element;
              const form = formOf(last);
              const actionOf = (owner, submitter) => {
                const own = submitter ? attr(submitter, 'formaction') : '';
                const raw = own !== '' ? own : attr(owner, 'action');
                return new URL(raw === '' ? document.URL : raw, document.baseURI);
              };
              const methodOf = (owner, submitter) => {
                const own = submitter ? attr(submitter, 'formmethod') : '';
                return (own !== '' ? own : attr(owner, 'method') || 'get').toLowerCase();
              };
              const isAllowed = (url) => url.protocol === 'https:' && url.port === ''
                && (hosts === null || hosts.includes(url.hostname.toLowerCase()));
              let actionHost = null;
              const checkAction = (owner, submitter) => {
                const url = actionOf(owner, submitter);
                if (!isAllowed(url)) return false;
                actionHost = url.hostname.toLowerCase();
                return true;
              };
              if (form && !checkAction(form, null)) return result('foreign');

              const setter = inputProto('value').set;
              for (const target of targets) {
                if (!target.element.isConnected || !onPage()) return result('moved');
                setter.call(target.element, target.value);
                target.element.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
                target.element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
              }

              if (form) {
                const submitControls = controlsOf(form).filter(isSubmitControl);
                if (submitControls.length > 0 && submitControls.every((control) => control.disabled)) {
                  return result('disabled');
                }
              }

              // A form that sends by POST is submitted. One that sends by GET would put its
              // fields, a password among them, in the address, so a submit event is dispatched
              // to the page's own handlers instead, and the form is sent only if one takes it over.
              const send = (owner, submitter) => {
                if (!checkAction(owner, submitter)) return 'foreign';
                if (methodOf(owner, submitter) === 'post') {
                  if (submitter) HTMLElement.prototype.click.call(submitter);
                  else formProto('requestSubmit').value.call(owner);
                  return 'ok';
                }
                const event = new Event('submit', { bubbles: true, cancelable: true });
                return EventTarget.prototype.dispatchEvent.call(owner, event) ? 'blocked' : 'ok';
              };
              const buttons = (scope, selector) => Array.prototype.filter.call(scope.querySelectorAll(selector),
                (button) => !button.disabled && isVisible(button));
              const nearest = (pick) => {
                for (let scope = last.parentElement; scope; scope = scope.parentElement) {
                  const button = pick(scope);
                  if (button) return button;
                }
                return null;
              };
              let outcome = null;
              if (form) {
                try {
                  outcome = send(form, null);
                } catch (error) {
                  outcome = null;
                }
              }
              if (outcome === null) {
                const submitter = nearest((scope) => buttons(scope, 'button[type=submit], input[type=submit]')[0])
                  || nearest((scope) => buttons(scope, 'button').find((button) =>
                    /^(sign in|log in|login|continue|next|verify|submit)$/i.test((button.textContent || '').trim())));
                if (submitter) {
                  const ownerProto = submitter instanceof HTMLButtonElement ? HTMLButtonElement.prototype : HTMLInputElement.prototype;
                  const owner = Object.getOwnPropertyDescriptor(ownerProto, 'form').get.call(submitter);
                  if (owner) {
                    outcome = send(owner, submitter);
                  } else {
                    HTMLElement.prototype.click.call(submitter);
                    outcome = 'ok';
                  }
                }
              }
              if (outcome === 'foreign') return result('foreign');
              if (outcome === 'blocked') return result('blocked');
              return outcome === 'ok' ? result('ok', actionHost) : result('nosubmit');
            } catch (error) {
              return result('error');
            }
            """
    }
}

/// An enrollment sign-in that keeps its place from one page to the next: which kinds it has
/// filled, the steps it recorded, the code sender it learned, and the hosts the filled forms
/// submit to. Each `run` examines the page that is open and the pages its fills lead to, so a
/// page the user took over, or one the app passed on, is examined afresh when the user moves on.
///
/// A secret saved with a site (`passwordHosts`, `authenticatorHosts`) is filled only on a page
/// whose host is in its list, into a form that sends to one of them; anywhere else the session
/// stops with `.unvettedHost` and fills nothing on that page.
@MainActor
final class AssistedSignInSession {
    /// A fill the session refused because the page's host is not one the secret may go to.
    struct UnvettedFill: Equatable, Sendable {
        let host: String
        let kind: SignInStep.Kind
    }

    private let broker: SignInBroker
    private let username: String
    private let password: String
    private let authenticatorKey: String?
    private let codeKind: SiteGrant.CodeKind
    private let codeSender: String?
    private let codes: SignInCodes
    private let passwordHosts: [String]?
    private let authenticatorHosts: [String]?

    private(set) var steps: [SignInStep] = []
    private(set) var learnedCodeSender: String?
    private(set) var submissionHosts: [String] = []
    /// Whether a page that shows nothing asking for a sign-in has followed one that showed a
    /// password field. From there on the session fills nothing: what the user sees is the site
    /// they signed in to.
    private(set) var hasReachedSignedInPage = false
    /// Set when a page asked for a code.
    private(set) var sawCodeField = false
    private(set) var unvettedFill: UnvettedFill?
    /// Set when, after the password was filled, a page showed the field it went into empty
    /// again at the same address: the site asked for the password again.
    private(set) var passwordShownAgain = false
    /// Set when, after the password was filled, a page no longer showed the field it went into.
    private(set) var leftPasswordForm = false
    private var sawPasswordField = false
    private var used = Set<SignInStep.Kind>()
    private var baseline: Int64?
    private var requestedAt: Date
    private var fills = 0

    init(
        broker: SignInBroker,
        username: String,
        password: String,
        authenticatorKey: String?,
        codeKind: SiteGrant.CodeKind,
        codeSender: String?,
        codes: SignInCodes,
        passwordHosts: [String]? = nil,
        authenticatorHosts: [String]? = nil
    ) {
        self.broker = broker
        self.username = username
        self.password = password
        self.authenticatorKey = authenticatorKey
        self.codeKind = codeKind
        self.codeSender = codeSender
        self.codes = codes
        self.passwordHosts = passwordHosts
        self.authenticatorHosts = authenticatorHosts
        baseline = codes.messageBaseline()
        requestedAt = broker.currentTime()
    }

    func result(stoppedBecause: SignInOutcome.Reason?) -> AssistedSignIn {
        AssistedSignIn(
            steps: steps,
            learnedCodeSender: learnedCodeSender,
            stoppedBecause: stoppedBecause,
            submissionHosts: submissionHosts
        )
    }

    /// Whether the password the session filled took: a later page left its form, and no page
    /// asked for it again.
    var passwordWasAccepted: Bool {
        steps.contains { $0.kind == .password } && leftPasswordForm && !passwordShownAgain
    }

    /// Examines the open page and fills what it recognises, then does the same on the page each
    /// fill leads to. Returns why it stopped; nil means no field was left to fill.
    func run() async -> SignInOutcome.Reason? {
        for _ in 0..<SignInBroker.maximumFills {
            let page: PageProbe
            do {
                try Task.checkCancellation()
                page = try await broker.probe()
                try await notePasswordForm(on: page)
            } catch {
                return stopped(by: error)
            }
            if page.hasChallenge { return .challenge }
            guard page.isSecureTopFrame else { return .pageMoved }
            if page.hasVisiblePassword { sawPasswordField = true }
            if page.hasCodeField { sawCodeField = true }
            if sawPasswordField, SignInRules.isPastSignIn(page) {
                hasReachedSignedInPage = true
                return nil
            }
            guard SignInRules.isRecordable(page) else { return .unrecognisedPage }

            let picks: [SignInRules.Pick]
            switch SignInRules.decide(page: page, used: used, codeKind: codeKind) {
            case let .stop(reason): return reason
            case let .fill(chosen): picks = chosen
            }
            let host = String(page.origin.dropFirst("https://".count))
            var allowedHosts: [String]?
            for pick in picks {
                guard let limit = savedSecretHosts(for: pick.kind) else { continue }
                guard limit.contains(host) else {
                    unvettedFill = UnvettedFill(host: host, kind: pick.kind)
                    return .unvettedHost
                }
                allowedHosts = limit
            }

            fills += picks.count
            if fills > SignInBroker.maximumFills { return .tooManySteps }

            var requests: [SignInBroker.FillRequest] = []
            for pick in picks {
                let value: String?
                switch pick.kind {
                case .username:
                    value = username
                case .password:
                    value = password
                case .code:
                    value = await code()
                }
                if Task.isCancelled || broker.browser.isClosed { return .loadFailed }
                guard let value else { return .noCode }
                requests.append(SignInBroker.FillRequest(kind: pick.kind, key: pick.field.key, value: value))
            }

            baseline = codes.messageBaseline()
            requestedAt = broker.currentTime()
            let mark = broker.browser.markAction()
            let status: SignInBroker.FillStatus
            do {
                status = try await broker.fill(
                    origin: page.origin,
                    path: page.path,
                    allowedHosts: allowedHosts,
                    requests: requests
                )
            } catch {
                return stopped(by: error)
            }
            guard case let .filled(actionHost) = status else { return Self.reason(for: status) }

            for pick in picks {
                steps.append(SignInStep(
                    kind: pick.kind,
                    origin: page.origin,
                    path: page.path,
                    field: pick.field.key
                ))
                used.insert(pick.kind)
            }
            if let actionHost, !submissionHosts.contains(actionHost) { submissionHosts.append(actionHost) }
            do {
                try await broker.browser.settleAfterAction(since: mark)
            } catch {
                return stopped(by: error)
            }
        }
        return .tooManySteps
    }

    /// The hosts a saved secret behind a fill of `kind` may go to, or nil when the value was
    /// typed during this enrollment.
    private func savedSecretHosts(for kind: SignInStep.Kind) -> [String]? {
        switch kind {
        case .username: nil
        case .password: passwordHosts
        case .code: codeKind == .authenticator ? authenticatorHosts : nil
        }
    }

    /// Notes whether a page after the password fill shows that fill's field: empty again at
    /// the same address is the site asking for the password again; absent is the form left. A
    /// field still holding the value is a form still being submitted, and says neither.
    private func notePasswordForm(on page: PageProbe) async throws {
        guard let step = steps.first(where: { $0.kind == .password }) else { return }
        guard SignInRules.visibleField(for: step, on: page) != nil else {
            leftPasswordForm = true
            return
        }
        if try await broker.isPasswordFieldEmpty(step.field) {
            passwordShownAgain = true
        }
    }

    private func stopped(by error: any Error) -> SignInOutcome.Reason {
        AppLog.notice(.sites, "assisted sign-in stopped by a page failure: \(SignInBroker.failureName(error))")
        return SignInBroker.isInterruption(error) ? .loadFailed : SignInBroker.reason(for: error)
    }

    private static func reason(for status: SignInBroker.FillStatus) -> SignInOutcome.Reason {
        status == .moved ? .pageMoved : .unrecognisedPage
    }

    /// The code the page asks for, read from the source the user named; a text with no sender
    /// named yet teaches the session whom the site texts from.
    private func code() async -> String? {
        let code: String?
        let codes = codes
        switch codeKind {
        case .none:
            code = nil
        case .authenticator:
            code = authenticatorKey.flatMap(codes.authenticator)
        case .text:
            guard let baseline else { return nil }
            if let sender = codeSender ?? learnedCodeSender {
                code = await broker.waiting { await codes.texted(sender, baseline) }
            } else if let first = await broker.waitingForFirstText(codes: codes, after: baseline) {
                learnedCodeSender = first.sender
                code = first.code
            } else {
                code = nil
            }
        case .email:
            guard let sender = codeSender else { return nil }
            let since = requestedAt
            code = await broker.waiting { await codes.emailed(sender, since) }
        }
        return code.flatMap(SignInRules.validCode)
    }
}

extension SignInBroker {
    func currentTime() -> Date { now() }

    /// Waits for a code from `operation`, within the broker's limit.
    func waiting(_ operation: @escaping @Sendable () async -> String?) async -> String? {
        await bounded(operation)
    }

    /// Waits within the broker's limit for the first code texted after `baseline`.
    func waitingForFirstText(
        codes: SignInCodes,
        after baseline: Int64
    ) async -> (code: String, sender: String)? {
        let found = FirstText()
        let code = await bounded {
            guard let first = await codes.firstTextedCode(baseline) else { return nil }
            found.set(first)
            return first.code
        }
        // A source that answers after the wait ended, cancelled or not, answered no one.
        guard code != nil else { return nil }
        return found.value
    }

    private final class FirstText: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (code: String, sender: String)?

        func set(_ value: (code: String, sender: String)) {
            lock.withLock { stored = value }
        }

        var value: (code: String, sender: String)? {
            lock.withLock { stored }
        }
    }
}

/// A session holds the username and password the user typed, so every textual rendering of it is
/// a fixed placeholder.
extension AssistedSignInSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "AssistedSignInSession(redacted)" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: []) }
}

/// A fill request carries the value to type, so every textual rendering is a fixed placeholder.
extension SignInBroker.FillRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "FillRequest(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
