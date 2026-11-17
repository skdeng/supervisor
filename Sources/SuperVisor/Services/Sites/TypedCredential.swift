import Foundation

/// A user name or a password a person typed into a field of a sign-in page, as the page's
/// script reported it, with the facts that say where it was typed; or the report that such a
/// field was emptied (`Kind.cleared`), which carries no value.
///
/// A value exists only when every check in `init(messageBody:isMainFrame:frameScheme:frameHost:framePort:)`
/// passed, so a holder never sees one the app has not vetted. It carries a secret: every textual
/// rendering, `dump` included, is a fixed placeholder, and it has no encoded form.
struct TypedCredential: Equatable, Sendable {
    enum Kind: String, Sendable {
        case password, username
        /// The field was emptied. `value` is empty, `actionHost` nil, `passwordFields` 0, and
        /// `newPassword` false.
        case cleared = "clear"
    }

    /// The most password inputs a report counts.
    static let maximumPasswordFields = 9

    let kind: Kind
    let value: String
    /// How the field is identified: its name, id, autocomplete token, and type attribute. A
    /// password field's type is `password` even when the page has since turned it into a text
    /// input.
    let field: FieldKey
    /// `https://host`, with no port.
    let origin: String
    /// `location.pathname` of the page the value was typed on.
    let path: String
    /// The host of the owning form's own `action`, nil when the field has no form or the action
    /// is not an `https` address. A submit control's `formaction` is not known while typing.
    let actionHost: String?
    /// How many password inputs the document holds, at most `maximumPasswordFields`.
    let passwordFields: Int
    /// Whether this field or any password input of the document asks for a new password.
    let newPassword: Bool

    private static let messageKeys: Set<String> = [
        "kind", "value", "name", "id", "autocomplete", "type", "origin", "path", "actionHost",
        "passwordFields", "newPassword",
    ]
    private static let clearKeys: Set<String> = ["kind", "name", "id", "autocomplete", "type", "origin", "path"]

    private init(
        kind: Kind,
        value: String,
        field: FieldKey,
        origin: String,
        path: String,
        actionHost: String?,
        passwordFields: Int,
        newPassword: Bool
    ) {
        self.kind = kind
        self.value = value
        self.field = field
        self.origin = origin
        self.path = path
        self.actionHost = actionHost
        self.passwordFields = passwordFields
        self.newPassword = newPassword
    }

    /// Builds the credential a typing script reported, or nil.
    ///
    /// The frame facts come from the web view, never from the message: the message must come
    /// from the main frame over `https` with no explicit port (`framePort` nil, 0, or 443), the
    /// frame's host must be a valid host name, and the message's `origin` must be exactly
    /// `https://` and that host. The body holds exactly the keys of one report, each of its
    /// type: `kind` is `password` or `username`, a password's `type` is `password` and a user
    /// name's is not, `path` begins with `/` and fits a recorded step, the field's attributes fit
    /// a field key, the value is not empty and fits what a grant holds for its kind,
    /// `actionHost` is empty or a valid host name, and `passwordFields` is 0 through 9.
    ///
    /// A clear holds exactly `kind` (`clear`), the field's four attributes, `origin`, and
    /// `path`, under the same frame, origin, path, and attribute checks.
    ///
    /// The frame's host is taken as given, and `SiteHost.isValid` accepts lowercase names only.
    init?(
        messageBody: Any,
        isMainFrame: Bool,
        frameScheme: String?,
        frameHost: String?,
        framePort: Int?
    ) {
        guard isMainFrame,
              frameScheme?.lowercased() == "https",
              framePort == nil || framePort == 0 || framePort == 443,
              let frameHost,
              SiteHost.isValid(frameHost),
              case let .object(body) = ScriptValue(messageBody),
              let kindText = body["kind"]?.string,
              let kind = Kind(rawValue: kindText),
              Set(body.keys) == (kind == .cleared ? Self.clearKeys : Self.messageKeys),
              let name = body["name"]?.string,
              let id = body["id"]?.string,
              let autocomplete = body["autocomplete"]?.string,
              let type = body["type"]?.string,
              let origin = body["origin"]?.string,
              let path = body["path"]?.string,
              origin == "https://" + frameHost,
              path.hasPrefix("/"),
              path.count <= SiteGrant.maximumStepPathLength,
              [name, id, autocomplete, type].allSatisfy({ $0.count <= SiteGrant.maximumFieldKeyLength })
        else { return nil }
        let field = FieldKey(name: name, id: id, autocomplete: autocomplete, type: type)

        guard kind != .cleared else {
            self.init(
                kind: .cleared,
                value: "",
                field: field,
                origin: origin,
                path: path,
                actionHost: nil,
                passwordFields: 0,
                newPassword: false
            )
            return
        }
        guard let value = body["value"]?.string,
              let actionHost = body["actionHost"]?.string,
              let passwordFields = body["passwordFields"]?.int,
              let newPassword = body["newPassword"]?.bool,
              (0...Self.maximumPasswordFields).contains(passwordFields),
              actionHost.isEmpty || SiteHost.isValid(actionHost)
        else { return nil }

        switch kind {
        case .password:
            guard type == "password", (1...SiteGrant.maximumPasswordLength).contains(value.count) else {
                return nil
            }
        case .username:
            guard type != "password", (1...SiteGrant.maximumUsernameLength).contains(value.count) else {
                return nil
            }
        case .cleared:
            return nil
        }

        self.init(
            kind: kind,
            value: value,
            field: field,
            origin: origin,
            path: path,
            actionHost: actionHost.isEmpty ? nil : actionHost,
            passwordFields: passwordFields,
            newPassword: newPassword
        )
    }
}

/// A credential holds what a person typed, so every textual rendering is a fixed placeholder.
extension TypedCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "TypedCredential(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
