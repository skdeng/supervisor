import Combine
import Foundation

/// The Add Site window's form: what the user typed, what it is missing, and what happens when
/// they sign in and save. The window's view only lays this out.
///
/// A site is kept in one of two ways (`Method`). **Keep me signed in**, the default, asks only
/// for the address: the person signs in on the page after Open Page, and the grant keeps that
/// session and no secret. **Sign in for me** also takes the user name, password, and code
/// settings, and the app signs in by itself.
///
/// Signing in again starts from the site's saved grant, in the way it was kept: its address
/// (fixed), user name, and code settings are filled in, and the password and authenticator key
/// fields start empty and stand for the saved ones until something is typed. A saved secret
/// goes only to the hosts the grant fills on (`SignInRequest.passwordHosts`). Those saved
/// secrets live in this object for as long as the window shows it.
///
/// **Save stores what signed in.** The grant is built from what the last Open Page or Sign In
/// started with, so Save is open only while the form still shows exactly that — the same way
/// of keeping the site and the same details — and, for Sign in for me, only after a sign-in the
/// enrollment confirms the password of (`SiteEnrollment`).
///
/// A sign-in the person is asked for, to a site ProVisor asked for that is not granted or to a
/// granted site kept by its session, goes through `SiteSignInModel`; this form carries a
/// request only for a granted site it signs in to again.
@MainActor
final class SiteFormModel: ObservableObject {
    enum Mode: Equatable {
        case adding
        case signingInAgain(siteID: String)
    }

    enum Field: Hashable {
        case address, name, username, password, authenticatorKey, codeSender
    }

    /// How the site is kept signed in.
    enum Method: Hashable {
        /// The person signs in on the page; the grant keeps the session and no secret.
        case keepsSession
        /// The app saves the user name and password in the Keychain and signs in by itself.
        case signsInForMe

        var title: String {
            switch self {
            case .keepsSession: "Keep me signed in"
            case .signsInForMe: "Sign in for me"
            }
        }

        var explanation: String {
            switch self {
            case .keepsSession:
                "Sign in on the page yourself. SuperVisor saves no password and asks you again when the site signs you out."
            case .signsInForMe:
                "SuperVisor saves your user name and password in the Keychain and signs in by itself."
            }
        }
    }

    /// The ProVisor proposal a form for a granted site was opened from, the site's host, and the
    /// line the form shows about it. Only a site saved under `host` settles the proposal.
    struct Request: Equatable {
        let proposalID: String
        let host: String
        let message: String
    }

    /// What the last Open Page or Sign In started with.
    enum Start: Equatable {
        case keepingSession(address: String)
        case signingIn(SignInRequest)
    }

    enum SaveOutcome: Equatable {
        case notSaved
        case saved
        /// Saved, with something the user is told before the window closes.
        case savedWithNotice(String)
    }

    /// What `SiteEnrollment.begin` is given. It carries the password, so no rendering of it
    /// shows its fields.
    struct SignInRequest: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let address: String
        let username: String
        /// Nil when the password is withheld from the app's fills.
        let password: String?
        let authenticatorKey: String?
        let codeKind: SiteGrant.CodeKind
        let codeSender: String?
        /// The hosts the password, and with it the user name, may be filled on, when it is the
        /// saved one; nil for a typed one.
        let passwordHosts: [String]?
        /// The same for the authenticator key.
        let authenticatorHosts: [String]?

        var description: String { "SignInRequest(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: []) }

        /// A sign-in again with everything `grant` saved, the request `currentDetails` makes
        /// when nothing is typed over the saved values: the saved password, and the saved
        /// authenticator key, go only to the hosts the grant fills on.
        init(saved grant: SiteGrant) {
            self.init(saved: grant, password: grant.password)
        }

        /// A sign-in again with everything `grant` saved but its password, which is withheld:
        /// the person types it into the page.
        init(savedWithholdingPassword grant: SiteGrant) {
            self.init(saved: grant, password: nil)
        }

        private init(saved grant: SiteGrant, password: String?) {
            address = grant.signInURL.absoluteString
            username = grant.username
            self.password = password
            codeKind = grant.codeKind
            switch grant.codeKind {
            case .none:
                authenticatorKey = nil
                codeSender = nil
                authenticatorHosts = nil
            case .authenticator:
                authenticatorKey = grant.authenticatorKey
                codeSender = nil
                authenticatorHosts = grant.fillHosts
            case .text, .email:
                authenticatorKey = nil
                codeSender = grant.codeSender
                authenticatorHosts = nil
            }
            passwordHosts = grant.fillHosts
        }

        init(
            address: String,
            username: String,
            password: String?,
            authenticatorKey: String?,
            codeKind: SiteGrant.CodeKind,
            codeSender: String?,
            passwordHosts: [String]?,
            authenticatorHosts: [String]?
        ) {
            self.address = address
            self.username = username
            self.password = password
            self.authenticatorKey = authenticatorKey
            self.codeKind = codeKind
            self.codeSender = codeSender
            self.passwordHosts = passwordHosts
            self.authenticatorHosts = authenticatorHosts
        }

        /// Starts an assisted sign-in with this request (`SiteEnrollment.begin`).
        @MainActor
        func begin(on enrollment: SiteEnrollment) async throws {
            try await enrollment.begin(
                signInAddress: address,
                username: username,
                password: password,
                authenticatorKey: authenticatorKey,
                codeKind: codeKind,
                codeSender: codeSender,
                passwordHosts: passwordHosts,
                authenticatorHosts: authenticatorHosts
            )
        }
    }

    /// The saved secrets and record a sign-in-again form stands on.
    private struct Saved {
        let password: String
        let authenticatorKey: String?
        let textSender: String?
        let fillHosts: [String]
        let record: SiteRecord
    }

    static let codeKinds: [SiteGrant.CodeKind] = [.none, .authenticator, .text, .email]
    static let methods: [Method] = [.keepsSession, .signsInForMe]
    static let detailsChangedMessage = "You changed the sign-in details. Press Sign In again before saving."
    static let openPageAgainMessage = "You changed the sign-in details. Press Open Page again before saving."

    static func signInAgainRequestMessage(name: String) -> String {
        "ProVisor asked you to sign in to \(name) again."
    }

    static func title(of kind: SiteGrant.CodeKind) -> String {
        switch kind {
        case .none: "None"
        case .authenticator: "Authenticator app"
        case .text: "Texted to me"
        case .email: "Emailed to me"
        }
    }

    let mode: Mode
    /// A line shown above the form.
    let notice: String?
    /// Set when the form was opened from a ProVisor request.
    let request: Request?

    @Published private var chosenMethod: Method = .keepsSession
    @Published private var typedAddress = ""
    @Published var username = ""
    @Published var password = ""
    @Published var codeKind: SiteGrant.CodeKind = .none
    @Published var authenticatorKey = ""
    @Published var codeSender = ""
    @Published private var typedName: String?

    /// A texted code needs this to be `.on`; `follow` keeps it in step with the center.
    @Published var textsStatus: SiteAccessCenter.TextsStatus = .off
    @Published var isWorking = false

    @Published private(set) var problem: SiteSaveProblem?
    @Published private(set) var isSaving = false
    /// What the last Open Page or Sign In started with; nil before one, after a refused
    /// address, and after a save refused for want of a new sign-in.
    @Published private(set) var started: Start?

    private let saved: Saved?
    /// The grant and record `finish` returned, kept until they are stored so a failed save can
    /// be tried again without signing in again.
    private var finished: (grant: SiteGrant, record: SiteRecord)?

    init() {
        mode = .adding
        notice = nil
        request = nil
        saved = nil
    }

    /// A form for adding a site whose saved sign-in could not be read back, in the way the
    /// site was kept.
    init(unreadableSite record: SiteRecord, requestedBy proposalID: String? = nil) {
        mode = .adding
        chosenMethod = record.keepsSessionOnly ? .keepsSession : .signsInForMe
        notice = "\(record.name)'s saved sign-in couldn't be read. Add it again."
        request = proposalID.map {
            Request(
                proposalID: $0,
                host: record.id,
                message: Self.signInAgainRequestMessage(name: record.name)
            )
        }
        saved = nil
        typedName = record.name
    }

    /// A form for signing in to a saved site again, in the way the site was kept.
    init(signingInAgain grant: SiteGrant, record: SiteRecord, requestedBy proposalID: String? = nil) {
        mode = .signingInAgain(siteID: record.id)
        notice = nil
        request = proposalID.map {
            Request(
                proposalID: $0,
                host: record.id,
                message: Self.signInAgainRequestMessage(name: record.name)
            )
        }
        chosenMethod = grant.remembersPassword ? .signsInForMe : .keepsSession
        saved = Saved(
            password: grant.password,
            authenticatorKey: grant.authenticatorKey,
            textSender: grant.codeKind == .text ? grant.codeSender : nil,
            fillHosts: grant.fillHosts,
            record: record
        )
        typedAddress = grant.signInURL.absoluteString
        typedName = record.name
        username = grant.username
        codeKind = grant.codeKind
        if grant.codeKind == .email {
            codeSender = grant.codeSender ?? ""
        }
    }

    func follow(_ enrollment: SiteEnrollment, center: SiteAccessCenter) {
        enrollment.$isWorking.assign(to: &$isWorking)
        center.$textsStatus.assign(to: &$textsStatus)
    }

    // MARK: Fields

    /// How the site is kept. A saved site keeps its own way.
    var method: Method {
        get { chosenMethod }
        set {
            guard saved == nil else { return }
            chosenMethod = newValue
        }
    }

    var canChooseMethod: Bool { saved == nil }

    /// The sign-in address. A saved site keeps its own: the site is its sign-in host.
    var address: String {
        get { typedAddress }
        set {
            guard saved == nil else { return }
            typedAddress = newValue
        }
    }

    /// The name field: the user's own once they have typed in it, else derived from the address.
    var name: String {
        get { typedName ?? Self.suggestedName(forAddress: address) }
        set { typedName = newValue }
    }

    /// The name `finish` is given; an emptied field falls back to the derived one.
    var resolvedName: String {
        let typed = typedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return typed.isEmpty ? Self.suggestedName(forAddress: address) : typed
    }

    /// The sign-in host with one leading `www.` or `my.` removed, or empty for an address that
    /// is not one.
    static func suggestedName(forAddress address: String) -> String {
        guard let host = SiteEnrollment.normalisedAddress(address)?.host(percentEncoded: false) else {
            return ""
        }
        for prefix in ["www.", "my."] where host.hasPrefix(prefix) {
            let rest = String(host.dropFirst(prefix.count))
            if rest.contains(".") { return rest }
        }
        return host
    }

    var isSigningInAgain: Bool { saved != nil }
    var hasSavedAuthenticatorKey: Bool { saved?.authenticatorKey != nil }

    var requiredFields: Set<Field> {
        guard method == .signsInForMe else { return [.address] }
        var fields: Set<Field> = [.address, .username]
        if saved == nil { fields.insert(.password) }
        switch codeKind {
        case .authenticator where saved?.authenticatorKey == nil: fields.insert(.authenticatorKey)
        case .email: fields.insert(.codeSender)
        case .none, .authenticator, .text: break
        }
        return fields
    }

    /// The sentence beside the address field, once something that is not an address is typed.
    var addressProblem: String? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, SiteEnrollment.normalisedAddress(typed) == nil else { return nil }
        return SiteSaveProblem.invalidAddress.message
    }

    /// A note beside a valid address that leads into the middle of a sign-in: one that carries
    /// a query, or whose host is a sign-in service's. Such a page belongs to a sign-in another
    /// browser started, and a site answers it with an error that reads like a wrong user name.
    /// The address a person normally starts from makes the site begin a sign-in of its own.
    var addressAdvice: String? {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSigningInAgain,
              let url = SiteEnrollment.normalisedAddress(typed),
              let host = url.host?.lowercased()
        else { return nil }
        let firstLabel = host.split(separator: ".").first.map(String.init) ?? ""
        let leadsIntoSignIn = !(url.query ?? "").isEmpty
            || Self.signInServiceLabels.contains(firstLabel)
        guard leadsIntoSignIn else { return nil }
        return "This looks like a page from the middle of a sign-in. If the site refuses it, "
            + "use the address you normally start from, such as the site's home or account page."
    }

    private static let signInServiceLabels: Set<String> = [
        "auth", "authentication", "authenticate", "login", "signin", "sso", "accounts",
        "account", "id", "identity", "idp", "secure", "oauth",
    ]

    /// The sentence beside the key field, once something that is not a key is typed.
    var authenticatorKeyProblem: String? {
        guard codeKind == .authenticator, !authenticatorKey.isEmpty, typedAuthenticatorKey == nil else {
            return nil
        }
        return "This is not a setup key or otpauth:// link."
    }

    var isAuthenticatorKeyAccepted: Bool {
        codeKind == .authenticator && typedAuthenticatorKey != nil
    }

    /// The sentence beside the sender field, once something that is not a sender is typed.
    var codeSenderProblem: String? {
        guard codeKind == .email, !trimmedSender.isEmpty, !Self.isValidSender(trimmedSender) else {
            return nil
        }
        return "Enter the address the code emails come from."
    }

    /// Texted codes are read only while texts are on and readable.
    var textsBlockSignIn: Bool {
        codeKind == .text && textsStatus != .on
    }

    /// Sign In, in Sign in for me.
    var canSignIn: Bool {
        method == .signsInForMe && !isWorking && !isSaving && signInRequest != nil
    }

    /// Open Page, in Keep me signed in.
    var canOpenPage: Bool {
        method == .keepsSession && !isWorking && !isSaving && keptSessionAddress != nil
    }

    /// The form shows another way of keeping the site, or other details, than the last Open
    /// Page or Sign In started with.
    var detailsChanged: Bool {
        guard let started else { return false }
        return currentStart != started
    }

    /// Why Save is closed after a sign-in, when the reason is the form itself.
    var saveBlocker: String? {
        guard detailsChanged else { return nil }
        return method == .keepsSession ? Self.openPageAgainMessage : Self.detailsChangedMessage
    }

    var canSave: Bool {
        started != nil && !detailsChanged && !isSaving
    }

    /// Whether the last Save was refused for want of a sign-in the app saw, or because the page
    /// reads the same to a visitor, which the person may answer by saving on their own word.
    var offersSaveAnyway: Bool {
        problem?.allowsSavingAnyway == true && canSave
    }

    /// What Sign In passes to `begin`, or nil while something required is missing or invalid.
    var signInRequest: SignInRequest? {
        textsBlockSignIn ? nil : currentDetails
    }

    /// What Open Page passes to `beginKeepingSession`, or nil for an address that is not one.
    var keptSessionAddress: String? {
        SiteEnrollment.normalisedAddress(address)?.absoluteString
    }

    /// What the button for the current method would start with now, whatever the texts status.
    private var currentStart: Start? {
        switch method {
        case .keepsSession: keptSessionAddress.map(Start.keepingSession)
        case .signsInForMe: currentDetails.map(Start.signingIn)
        }
    }

    /// What the fields say, valid and complete, whatever the texts status.
    private var currentDetails: SignInRequest? {
        guard let url = SiteEnrollment.normalisedAddress(address) else { return nil }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...SiteGrant.maximumUsernameLength).contains(user.count),
              let secret = resolvedPassword,
              (1...SiteGrant.maximumPasswordLength).contains(secret.count)
        else { return nil }

        var key: String?
        var sender: String?
        var keyHosts: [String]?
        switch codeKind {
        case .none:
            break
        case .authenticator:
            guard let resolved = resolvedAuthenticatorKey else { return nil }
            key = resolved
            if authenticatorKey.isEmpty { keyHosts = saved?.fillHosts }
        case .text:
            sender = saved?.textSender
        case .email:
            guard Self.isValidSender(trimmedSender) else { return nil }
            sender = trimmedSender
        }
        return SignInRequest(
            address: url.absoluteString,
            username: user,
            password: secret,
            authenticatorKey: key,
            codeKind: codeKind,
            codeSender: sender,
            passwordHosts: password.isEmpty ? saved?.fillHosts : nil,
            authenticatorHosts: keyHosts
        )
    }

    private var resolvedPassword: String? {
        if !password.isEmpty { return password }
        return saved?.password
    }

    private var typedAuthenticatorKey: String? {
        let typed = authenticatorKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, TOTPKey.parse(typed) != nil else { return nil }
        return typed
    }

    private var resolvedAuthenticatorKey: String? {
        if authenticatorKey.isEmpty { return saved?.authenticatorKey }
        return typedAuthenticatorKey
    }

    private var trimmedSender: String {
        codeSender.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The rule `SiteGrant.isValid` holds a code sender to.
    private static func isValidSender(_ sender: String) -> Bool {
        sender.range(of: #"\A[A-Za-z0-9+@._-]{2,80}\z"#, options: .regularExpression) != nil
    }

    // MARK: Messages from the sign-in

    /// What to say when a saved secret was not filled on a host the grant does not fill on.
    static func movedMessage(_ fill: AssistedSignInSession.UnvettedFill) -> String {
        switch fill.kind {
        case .code:
            "This site's sign-in page has moved to \(fill.host). Type your setup key here to continue."
        case .username, .password:
            "This site's sign-in page has moved to \(fill.host). Type your password here to continue."
        }
    }

    /// What to tell the user after saving a site that was to send codes by text or email but
    /// asked for none, so it was saved as one with no code.
    static func noticeAfterSaving(requested: SiteGrant.CodeKind, saved: SiteGrant.CodeKind, name: String) -> String? {
        guard saved == .none else { return nil }
        switch requested {
        case .text:
            return "Saved. \(name) didn't ask for a code this time, so SuperVisor hasn't learned who texts it. If it asks later, you'll be asked to sign in again."
        case .email:
            return "Saved. \(name) didn't ask for a code this time, so SuperVisor hasn't learned who emails it. If it asks later, you'll be asked to sign in again."
        case .none, .authenticator:
            return nil
        }
    }

    // MARK: Signing in and saving

    /// Opens the page for the person to sign in on themselves.
    func openPage(using enrollment: SiteEnrollment) async {
        guard canOpenPage, let address = keptSessionAddress else { return }
        problem = nil
        finished = nil
        started = .keepingSession(address: address)
        do {
            try await enrollment.beginKeepingSession(signInAddress: address)
        } catch {
            let problem = SiteSaveProblem.ofSignIn(error)
            self.problem = problem
            if problem == .invalidAddress { started = nil }
        }
    }

    func signIn(using enrollment: SiteEnrollment) async {
        guard canSignIn, let request = signInRequest else { return }
        problem = nil
        finished = nil
        started = .signingIn(request)
        do {
            try await request.begin(on: enrollment)
        } catch {
            let problem = SiteSaveProblem.ofSignIn(error)
            self.problem = problem
            // A refused address leaves nothing for `finish` to build on.
            if problem == .invalidAddress { started = nil }
        }
    }

    /// Builds the grant from the page the user is on and stores it, then hands the saved
    /// record to `onSaved`. Nothing is stored once the enrollment has been cancelled, however
    /// far the save had got.
    ///
    /// `confirmingSignIn` is the person's answer to the refusal the form shows, a Save refused
    /// for want of a sign-in the app saw or because the page cannot be told from a visitor's.
    /// It answers that refusal alone and counts only while the form shows it.
    func save(
        using enrollment: SiteEnrollment,
        into center: SiteAccessCenter,
        confirmingSignIn: Bool = false,
        onSaved: (SiteRecord) -> Void = { _ in }
    ) async -> SaveOutcome {
        guard canSave, let started else { return .notSaved }
        let confirming = confirmingSignIn && offersSaveAnyway ? problem?.confirmation : nil
        isSaving = true
        defer { isSaving = false }
        problem = nil

        let result: (grant: SiteGrant, record: SiteRecord)
        if let finished {
            result = finished
        } else {
            let made: (grant: SiteGrant, record: SiteRecord)
            do {
                switch started {
                case .keepingSession:
                    made = try await enrollment.finishKeepingSession(
                        name: resolvedName,
                        confirming: confirming
                    )
                case .signingIn:
                    made = try await enrollment.finish(name: resolvedName)
                }
            } catch {
                problem = SiteSaveProblem.ofFinish(error)
                if problem?.needsNewSignIn == true { self.started = nil }
                return .notSaved
            }
            var kept = made
            if let saved { kept.record.added = saved.record.added }
            result = kept
            finished = kept
        }

        guard !enrollment.isCancelled else { return .notSaved }
        do {
            try center.save(grant: result.grant, record: result.record)
        } catch {
            problem = .notSaved
            return .notSaved
        }
        finished = nil
        onSaved(result.record)
        if case let .signingIn(request) = started,
           let notice = Self.noticeAfterSaving(
               requested: request.codeKind,
               saved: result.grant.codeKind,
               name: result.record.name
           ) {
            return .savedWithNotice(notice)
        }
        return .saved
    }
}

/// The form holds the password the user typed and the saved one it stands for, so no
/// reflection of it shows them.
extension SiteFormModel: CustomReflectable {
    nonisolated var customMirror: Mirror { Mirror(self, children: []) }
}
