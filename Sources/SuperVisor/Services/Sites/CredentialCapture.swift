import Foundation

/// What a person typed into the user name and password fields of a sign-in, and the plain facts
/// about how the sign-in went, held in memory for as long as the sign-in window is open.
///
/// It keeps the password most recently typed and the user name that goes with it, and judges
/// nothing: whether the password worked, and whether to keep it, is for the holder to decide
/// from the facts. It carries secrets, so every textual rendering, `dump` included, is a fixed
/// placeholder, and it has no encoded form.
///
/// A page's password field is one `SignInRules.isMaskedNonPassword` does not set apart as a
/// masked code, PIN, or answer, which is the field the credential script reports as a password.
///
/// | Event | What changes |
/// |---|---|
/// | `record`, a value | its host joins `hostsTypedOn`; `sawNewPasswordForm` is set when it asks for a new |
/// | | password or the document holds two or more password inputs |
/// | `record`, a password | replaces `password`; sets `askedAgain` when `leftPasswordForm` is set; sets |
/// | | `severalSecrets` when it went into another field or onto another page than the password held, with no |
/// | | page without a password field noted since that one; sets `sawNewPasswordForm` when an earlier |
/// | | password went into another field of the same page; a user name waiting from another page becomes |
/// | | `username` |
/// | `record`, a user name before any password | replaces `username` |
/// | `record`, a user name after a password, on its page | replaces `username` |
/// | `record`, a user name after a password, elsewhere | waits, and becomes `username` at the next password |
/// | `record`, a clear | drops the password, user name, or waiting user name typed into that field on that page |
/// | `notePage`, any page | sets `sawCodeField` when it shows a code field or single-character boxes |
/// | `notePage`, after a password, no password field | sets `leftPasswordForm` |
/// | `notePage`, `leftPasswordForm` set, a password field | sets `askedAgain` |
/// | `wipe` | returns to the state of a new capture |
///
/// Every flag stays set once it is. The password typed last stays recorded when `askedAgain` is
/// set.
struct CredentialCapture: Equatable, Sendable {
    /// One value the person typed, with where it was typed.
    struct Record: Equatable, Sendable {
        let value: String
        let field: FieldKey
        /// `https://host`, with no port.
        let origin: String
        /// `location.pathname` of the page the value was typed on.
        let path: String
        /// The host of the owning form's own `action`, when it has one.
        let actionHost: String?

        fileprivate init(_ credential: TypedCredential) {
            value = credential.value
            field = credential.field
            origin = credential.origin
            path = credential.path
            actionHost = credential.actionHost
        }
    }

    /// The most pages whose password field is followed.
    private static let maximumTrackedPages = 16

    private struct PageKey: Hashable, Sendable {
        let origin: String
        let path: String
    }

    /// The password typed last.
    private(set) var password: Record?
    /// The user name typed before the password or on its page.
    private(set) var username: Record?
    /// The hosts a value was typed on.
    private(set) var hostsTypedOn: Set<String> = []
    /// A page showed no password field after a password was typed.
    private(set) var leftPasswordForm = false
    /// After the page left the password form, a page showed a password field again or a password
    /// was typed again: the first password did not work or the site asked for it again, and the
    /// last value alone no longer says which password is right.
    private(set) var askedAgain = false
    /// A document held two or more password inputs, a field asked for a new password, or
    /// passwords went into two different fields of one page: a change-password or sign-up form.
    private(set) var sawNewPasswordForm = false
    /// A page showed a code field or a row of single-character boxes.
    private(set) var sawCodeField = false
    /// A password went into another field, or onto another page, than the password held before
    /// it, with no page between them that showed no password field: two password-like values
    /// typed in one go, and nothing says which is the account's password.
    private(set) var severalSecrets = false

    private var usernameAfterPassword: Record?
    private var passwordFieldByPage: [PageKey: FieldKey] = [:]
    /// A page without a password field was noted since the password held was typed.
    private var notedPageWithoutPassword = false

    mutating func record(_ credential: TypedCredential) {
        guard credential.kind != .cleared else {
            clear(credential)
            return
        }
        hostsTypedOn.insert(String(credential.origin.dropFirst("https://".count)))
        if credential.newPassword || credential.passwordFields >= 2 { sawNewPasswordForm = true }
        switch credential.kind {
        case .password: recordPassword(Record(credential))
        case .username: recordUsername(Record(credential))
        case .cleared: break
        }
    }

    /// Takes a look at the page on display.
    mutating func notePage(_ page: PageProbe) {
        if page.hasCodeField || SignInRules.showsSplitCode(page) { sawCodeField = true }
        guard password != nil else { return }
        let showsPassword = page.fields.contains { $0.isPassword && !SignInRules.isMaskedNonPassword($0.key) }
        if !showsPassword {
            leftPasswordForm = true
            notedPageWithoutPassword = true
        } else if leftPasswordForm {
            askedAgain = true
        }
    }

    /// Forgets everything.
    mutating func wipe() {
        self = CredentialCapture()
    }

    private mutating func recordPassword(_ record: Record) {
        followPasswordField(record)
        if leftPasswordForm { askedAgain = true }
        if let held = password, !notedPageWithoutPassword, !Self.sameField(held, record) {
            severalSecrets = true
        }
        notedPageWithoutPassword = false
        password = record
        if let waiting = usernameAfterPassword {
            username = waiting
            usernameAfterPassword = nil
        }
    }

    private mutating func recordUsername(_ record: Record) {
        guard let password else {
            username = record
            return
        }
        if record.origin == password.origin, record.path == password.path {
            username = record
        } else {
            usernameAfterPassword = record
        }
    }

    /// Drops what was typed into the field `cleared` names, on its page.
    private mutating func clear(_ cleared: TypedCredential) {
        func matches(_ record: Record?) -> Bool {
            guard let record else { return false }
            return record.field == cleared.field && record.origin == cleared.origin && record.path == cleared.path
        }
        if matches(password) { password = nil }
        if matches(username) { username = nil }
        if matches(usernameAfterPassword) { usernameAfterPassword = nil }
    }

    /// Whether two values went into one field of one page.
    private static func sameField(_ first: Record, _ second: Record) -> Bool {
        first.field == second.field && first.origin == second.origin && first.path == second.path
    }

    /// Sets `sawNewPasswordForm` when `record` went into a different field than an earlier
    /// password did on the same page. Once the flag is set nothing more is followed.
    private mutating func followPasswordField(_ record: Record) {
        guard !sawNewPasswordForm else { return }
        let page = PageKey(origin: record.origin, path: record.path)
        if let earlier = passwordFieldByPage[page] {
            if earlier != record.field { sawNewPasswordForm = true }
        } else if passwordFieldByPage.count < Self.maximumTrackedPages {
            passwordFieldByPage[page] = record.field
        }
    }
}

/// A capture holds what a person typed, so every textual rendering is a fixed placeholder.
extension CredentialCapture: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "CredentialCapture(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension CredentialCapture.Record: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "CredentialCapture.Record(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
