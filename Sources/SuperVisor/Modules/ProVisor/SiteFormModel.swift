import Combine
import Foundation

/// The Add Site window's form: what the user typed, what it is missing, and what happens when
/// they sign in and save. The window's view only lays this out.
///
/// Signing in again starts from the site's saved grant: its address (fixed), user name, and
/// code settings are filled in, and the password and authenticator key fields start empty and
/// stand for the saved ones until something is typed. A saved secret goes only to the hosts
/// the grant fills on (`SignInRequest.passwordHosts`). Those saved secrets live in this object
/// for as long as the window shows it.
///
/// **Save stores what signed in.** The grant is built from the details the last Sign In
/// started with, so Save is open only while the form still shows exactly those details, and
/// only after a sign-in the enrollment confirms the password of (`SiteEnrollment`).
@MainActor
final class SiteFormModel: ObservableObject {
    enum Mode: Equatable {
        case adding
        case signingInAgain(siteID: String)
    }

    enum Field: Hashable {
        case address, name, username, password, authenticatorKey, codeSender
    }

    /// Why a sign-in or save did not go through, each shown as a fixed sentence.
    enum Problem: Equatable {
        case invalidAddress
        case pageDidNotLoad
        case notSignedIn
        case invalidGrant
        case passwordNotConfirmed
        case passwordNotFilled
        case notSaved

        var message: String {
            switch self {
            case .invalidAddress:
                "Enter the https address of the site's sign-in page."
            case .pageDidNotLoad:
                "The sign-in page did not finish loading. Check the address and try again."
            case .notSignedIn:
                "Finish signing in on the page first, then save."
            case .invalidGrant:
                "This sign-in could not be recorded. Try again from the sign-in page."
            case .passwordNotConfirmed:
                "SuperVisor can't tell which password worked. Type the working password in the form here, then press Sign In again."
            case .passwordNotFilled:
                "SuperVisor didn't fill the sign-in itself, so it couldn't record it. Press Sign In and let it fill the page."
            case .notSaved:
                "The site could not be saved to the Keychain."
            }
        }

        /// A problem a new sign-in, not another Save, puts right.
        var needsNewSignIn: Bool {
            self == .passwordNotConfirmed || self == .passwordNotFilled
        }

        static func ofSignIn(_ error: any Error) -> Problem {
            (error as? SiteEnrollment.Failure) == .invalidAddress ? .invalidAddress : .pageDidNotLoad
        }

        /// Nil for an enrollment cancelled while it finished: the window is gone.
        static func ofFinish(_ error: any Error) -> Problem? {
            switch error as? SiteEnrollment.Failure {
            case .cancelled?: nil
            case .invalidGrant?: .invalidGrant
            case .passwordNotConfirmed?: .passwordNotConfirmed
            case .passwordNotFilled?: .passwordNotFilled
            case .invalidAddress?, .notSignedIn?, nil: .notSignedIn
            }
        }
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
        let password: String
        let authenticatorKey: String?
        let codeKind: SiteGrant.CodeKind
        let codeSender: String?
        /// The hosts the password may be filled on, when it is the saved one; nil for a typed one.
        let passwordHosts: [String]?
        /// The same for the authenticator key.
        let authenticatorHosts: [String]?

        var description: String { "SignInRequest(redacted)" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: []) }
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
    static let detailsChangedMessage = "You changed the sign-in details. Press Sign In again before saving."

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

    @Published private(set) var problem: Problem?
    @Published private(set) var isSaving = false
    /// The details the last sign-in started with; nil before one, after a refused address, and
    /// after a save refused for want of a new sign-in.
    @Published private(set) var signedInWith: SignInRequest?

    private let saved: Saved?
    /// The grant and record `finish` returned, kept until they are stored so a failed save can
    /// be tried again without signing in again.
    private var finished: (grant: SiteGrant, record: SiteRecord)?

    init() {
        mode = .adding
        notice = nil
        saved = nil
    }

    /// A form for adding a site whose saved sign-in could not be read back.
    init(unreadableSite record: SiteRecord) {
        mode = .adding
        notice = "\(record.name)'s saved sign-in couldn't be read. Add it again."
        saved = nil
        typedName = record.name
    }

    init(signingInAgain grant: SiteGrant, record: SiteRecord) {
        mode = .signingInAgain(siteID: record.id)
        notice = nil
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
        return Problem.invalidAddress.message
    }

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

    var canSignIn: Bool {
        !isWorking && !isSaving && signInRequest != nil
    }

    /// The form shows other details than the ones the last sign-in started with.
    var detailsChanged: Bool {
        guard let signedInWith else { return false }
        return currentDetails != signedInWith
    }

    /// Why Save is closed after a sign-in, when the reason is the form itself.
    var saveBlocker: String? {
        detailsChanged ? Self.detailsChangedMessage : nil
    }

    var canSave: Bool {
        signedInWith != nil && !detailsChanged && !isSaving
    }

    /// What Sign In passes to `begin`, or nil while something required is missing or invalid.
    var signInRequest: SignInRequest? {
        textsBlockSignIn ? nil : currentDetails
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

    func signIn(using enrollment: SiteEnrollment) async {
        guard canSignIn, let request = signInRequest else { return }
        problem = nil
        finished = nil
        signedInWith = request
        do {
            try await enrollment.begin(
                signInAddress: request.address,
                username: request.username,
                password: request.password,
                authenticatorKey: request.authenticatorKey,
                codeKind: request.codeKind,
                codeSender: request.codeSender,
                passwordHosts: request.passwordHosts,
                authenticatorHosts: request.authenticatorHosts
            )
        } catch {
            let problem = Problem.ofSignIn(error)
            self.problem = problem
            // A refused address leaves nothing for `finish` to build on.
            if problem == .invalidAddress { signedInWith = nil }
        }
    }

    /// Builds the grant from the page the user is on and stores it. Nothing is stored once the
    /// enrollment has been cancelled, however far the save had got.
    func save(using enrollment: SiteEnrollment, into center: SiteAccessCenter) async -> SaveOutcome {
        guard canSave, let request = signedInWith else { return .notSaved }
        isSaving = true
        defer { isSaving = false }
        problem = nil

        let result: (grant: SiteGrant, record: SiteRecord)
        if let finished {
            result = finished
        } else {
            do {
                var made = try await enrollment.finish(name: resolvedName)
                if let saved { made.record.added = saved.record.added }
                result = made
                finished = made
            } catch {
                problem = Problem.ofFinish(error)
                if problem?.needsNewSignIn == true { signedInWith = nil }
                return .notSaved
            }
        }

        guard !enrollment.isCancelled else { return .notSaved }
        do {
            try center.save(grant: result.grant, record: result.record)
        } catch {
            problem = .notSaved
            return .notSaved
        }
        finished = nil
        if let notice = Self.noticeAfterSaving(
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
