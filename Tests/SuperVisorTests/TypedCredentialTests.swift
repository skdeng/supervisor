import Foundation
import Testing

@testable import SuperVisor

/// The message the credential script posts, as a dictionary, with `changes` applied; a nil
/// change removes the key.
func credentialBody(_ changes: [String: Any?] = [:]) -> [String: Any] {
    var body: [String: Any] = [
        "kind": "password",
        "value": "hunter2-Value",
        "name": "pw-field-name",
        "id": "pw-field-id",
        "autocomplete": "current-password",
        "type": "password",
        "origin": "https://example.com",
        "path": "/login",
        "actionHost": "example.com",
        "passwordFields": 1,
        "newPassword": false,
    ]
    for (key, change) in changes {
        if let change { body[key] = change } else { body.removeValue(forKey: key) }
    }
    return body
}

/// A credential built the way the browser builds one from the main frame of `https://example.com`.
func typedCredential(
    _ changes: [String: Any?] = [:],
    host: String = "example.com"
) -> TypedCredential? {
    TypedCredential(
        messageBody: credentialBody(changes),
        isMainFrame: true,
        frameScheme: "https",
        frameHost: host,
        framePort: nil
    )
}

@Suite("Typed credentials")
struct TypedCredentialTests {
    private func build(
        _ body: Any,
        isMainFrame: Bool = true,
        scheme: String? = "https",
        host: String? = "example.com",
        port: Int? = nil
    ) -> TypedCredential? {
        TypedCredential(
            messageBody: body,
            isMainFrame: isMainFrame,
            frameScheme: scheme,
            frameHost: host,
            framePort: port
        )
    }

    // MARK: Accepted

    @Test("A password report from the main frame of an https page is accepted whole")
    func acceptsPassword() throws {
        let credential = try #require(build(credentialBody()))

        #expect(credential.kind == .password)
        #expect(credential.value == "hunter2-Value")
        #expect(credential.field == FieldKey(
            name: "pw-field-name", id: "pw-field-id", autocomplete: "current-password", type: "password"
        ))
        #expect(credential.origin == "https://example.com")
        #expect(credential.path == "/login")
        #expect(credential.actionHost == "example.com")
        #expect(credential.passwordFields == 1)
        #expect(credential.newPassword == false)
    }

    @Test("A user name report is accepted, and an empty action host reads as none")
    func acceptsUsername() throws {
        let credential = try #require(build(credentialBody([
            "kind": "username", "value": "alice@example.com", "type": "email", "actionHost": "",
            "passwordFields": 0, "newPassword": true,
        ])))

        #expect(credential.kind == .username)
        #expect(credential.value == "alice@example.com")
        #expect(credential.field.type == "email")
        #expect(credential.actionHost == nil)
        #expect(credential.passwordFields == 0)
        #expect(credential.newPassword)
    }

    @Test("The frame's port may be absent, 0 (what the web view reports for a default port), or 443")
    func acceptsDefaultPorts() {
        for port: Int? in [nil, 0, 443] {
            #expect(build(credentialBody(), port: port) != nil, "\(String(describing: port))")
        }
    }

    @Test("The scheme is compared without regard to case, and the limits are inclusive")
    func acceptsTheLimits() throws {
        #expect(build(credentialBody(), scheme: "HTTPS") != nil)

        let longest = String(repeating: "x", count: SiteGrant.maximumFieldKeyLength)
        let path = "/" + String(repeating: "p", count: SiteGrant.maximumStepPathLength - 1)
        let password = String(repeating: "p", count: SiteGrant.maximumPasswordLength)
        let credential = try #require(build(credentialBody([
            "name": longest, "id": longest, "autocomplete": longest, "type": "password", "path": path,
            "value": password, "passwordFields": 9,
        ])))
        #expect(credential.path == path)
        #expect(credential.value == password)
        #expect(credential.passwordFields == 9)

        let name = String(repeating: "n", count: SiteGrant.maximumUsernameLength)
        #expect(build(credentialBody(["kind": "username", "type": "text", "value": name])) != nil)
        #expect(build(credentialBody(["value": "x"])) != nil)
    }

    // MARK: Refused

    @Test("A report is refused unless every check passes")
    func refusals() {
        let tooLong = String(repeating: "x", count: SiteGrant.maximumFieldKeyLength + 1)
        let cases: [(String, TypedCredential?)] = [
            // The frame the message came from.
            ("a frame inside the page", build(credentialBody(), isMainFrame: false)),
            ("an http frame", build(credentialBody(), scheme: "http")),
            ("no scheme", build(credentialBody(), scheme: nil)),
            ("a file frame", build(credentialBody(), scheme: "file")),
            ("an explicit port", build(credentialBody(), port: 8443)),
            ("port 80", build(credentialBody(), port: 80)),
            ("no host", build(credentialBody(), host: nil)),
            ("an empty host", build(credentialBody(), host: "")),
            ("a host that is not lowercase", build(credentialBody(["origin": "https://example.com"]), host: "Example.com")),
            ("an IP literal host", build(credentialBody(["origin": "https://10.0.0.1"]), host: "10.0.0.1")),
            ("a single-label host", build(credentialBody(["origin": "https://localhost"]), host: "localhost")),
            ("a host with a port in it", build(credentialBody(["origin": "https://example.com:8443"]), host: "example.com:8443")),
            // The origin the page reported.
            ("an origin of another host", build(credentialBody(["origin": "https://evil.example.org"]))),
            ("an origin with another case", build(credentialBody(["origin": "https://Example.com"]))),
            ("an origin with a trailing slash", build(credentialBody(["origin": "https://example.com/"]))),
            ("an origin with a port", build(credentialBody(["origin": "https://example.com:8443"]))),
            ("an http origin", build(credentialBody(["origin": "http://example.com"]))),
            ("an origin of a subdomain", build(credentialBody(["origin": "https://www.example.com"]))),
            ("an opaque origin", build(credentialBody(["origin": "null"]))),
            ("an empty origin", build(credentialBody(["origin": ""]))),
            // The path.
            ("a path without a slash", build(credentialBody(["path": "login"]))),
            ("an empty path", build(credentialBody(["path": ""]))),
            ("a path over the limit", build(credentialBody(["path": "/" + String(repeating: "p", count: SiteGrant.maximumStepPathLength)]))),
            // The field's attributes.
            ("a name over the limit", build(credentialBody(["name": tooLong]))),
            ("an id over the limit", build(credentialBody(["id": tooLong]))),
            ("an autocomplete over the limit", build(credentialBody(["autocomplete": tooLong]))),
            ("a type over the limit", build(credentialBody(["kind": "username", "type": tooLong]))),
            // The value.
            ("an empty value", build(credentialBody(["value": ""]))),
            ("a password over the limit", build(credentialBody(["value": String(repeating: "p", count: SiteGrant.maximumPasswordLength + 1)]))),
            ("a user name over the limit", build(credentialBody(["kind": "username", "type": "text", "value": String(repeating: "n", count: SiteGrant.maximumUsernameLength + 1)]))),
            // The kind.
            ("an unknown kind", build(credentialBody(["kind": "code"]))),
            ("a kind with another case", build(credentialBody(["kind": "Password"]))),
            ("an empty kind", build(credentialBody(["kind": ""]))),
            ("a password whose type is not password", build(credentialBody(["type": "text"]))),
            ("a password with an empty type", build(credentialBody(["type": ""]))),
            ("a user name whose type is password", build(credentialBody(["kind": "username", "type": "password"]))),
            // The action host and the counts.
            ("an action host that is not a host name", build(credentialBody(["actionHost": "https://example.com"]))),
            ("an action host with a port", build(credentialBody(["actionHost": "example.com:8443"]))),
            ("an action host that is not lowercase", build(credentialBody(["actionHost": "Example.com"]))),
            ("a negative password count", build(credentialBody(["passwordFields": -1]))),
            ("ten password inputs", build(credentialBody(["passwordFields": 10]))),
            ("a fractional password count", build(credentialBody(["passwordFields": 1.5]))),
        ]

        for (label, credential) in cases {
            #expect(credential == nil, "\(label)")
        }
    }

    @Test("A report whose keys or value types are not exactly those of a report is refused")
    func refusesWrongShapes() {
        let keys = Array(credentialBody().keys)
        for key in keys {
            #expect(build(credentialBody([key: nil])) == nil, "missing \(key)")
        }
        #expect(build(credentialBody(["extra": "x"])) == nil, "an extra key")
        #expect(build(credentialBody(["extra": NSNull()])) == nil, "an extra null")

        let wrongTypes: [String: Any] = [
            "kind": 1, "value": 5, "name": ["a"], "id": NSNull(), "autocomplete": true, "type": 0,
            "origin": ["https://example.com"], "path": 1, "actionHost": NSNull(),
            "passwordFields": "1", "newPassword": "false",
        ]
        for (key, wrong) in wrongTypes {
            #expect(build(credentialBody([key: wrong])) == nil, "\(key) of the wrong type")
        }
        #expect(build(credentialBody(["passwordFields": true])) == nil, "a Boolean for a count")
        #expect(build(credentialBody(["newPassword": 1])) == nil, "a number for a Boolean")
        #expect(build(credentialBody(["value": ["nested": "x"]])) == nil, "an object for a value")
    }

    @Test("A body that is not a dictionary is refused")
    func refusesNonDictionaries() {
        let bodies: [Any] = [
            "password", 1, true, NSNull(), ["password", "hunter2"], [String: Any](), Data(),
        ]
        for body in bodies {
            #expect(build(body) == nil, "\(body)")
        }
    }

    // MARK: Clears

    /// The clear the script reports for an emptied field, with `changes` applied; a nil change
    /// removes the key.
    private func clearBody(_ changes: [String: Any?] = [:]) -> [String: Any] {
        var body: [String: Any] = [
            "kind": "clear", "name": "pw-field-name", "id": "pw-field-id",
            "autocomplete": "current-password", "type": "password",
            "origin": "https://example.com", "path": "/login",
        ]
        for (key, change) in changes {
            if let change { body[key] = change } else { body.removeValue(forKey: key) }
        }
        return body
    }

    @Test("A clear from the main frame is accepted, carrying the field and page and no value")
    func acceptsClear() throws {
        let clear = try #require(build(clearBody()))

        #expect(clear.kind == .cleared)
        #expect(clear.value.isEmpty)
        #expect(clear.field == FieldKey(
            name: "pw-field-name", id: "pw-field-id", autocomplete: "current-password", type: "password"
        ))
        #expect(clear.origin == "https://example.com")
        #expect(clear.path == "/login")
        #expect(clear.actionHost == nil)
        #expect(clear.passwordFields == 0)
        #expect(!clear.newPassword)
        #expect(build(clearBody(["type": "text"])) != nil)
    }

    @Test("A clear is refused under the frame and length checks a report is held to, and with any other keys")
    func refusesClear() {
        let tooLong = String(repeating: "x", count: SiteGrant.maximumFieldKeyLength + 1)
        let cases: [(String, TypedCredential?)] = [
            ("a frame inside the page", build(clearBody(), isMainFrame: false)),
            ("an http frame", build(clearBody(), scheme: "http")),
            ("an explicit port", build(clearBody(), port: 8443)),
            ("an origin of another host", build(clearBody(["origin": "https://evil.example.org"]))),
            ("a relative path", build(clearBody(["path": "login"]))),
            ("a long path", build(clearBody(["path": "/" + String(repeating: "p", count: SiteGrant.maximumStepPathLength)]))),
            ("a long name", build(clearBody(["name": tooLong]))),
            ("a value", build(clearBody(["value": "x"]))),
            ("an empty value", build(clearBody(["value": ""]))),
            ("the keys of a report", build(credentialBody(["kind": "clear"]))),
            ("a missing key", build(clearBody(["path": nil]))),
            ("a key of the wrong type", build(clearBody(["name": 3]))),
            ("a report with no value", build(credentialBody(["value": ""]))),
        ]
        for (label, credential) in cases {
            #expect(credential == nil, "\(label)")
        }
    }

    // MARK: Redaction

    @Test("A credential prints as a fixed placeholder however it is rendered")
    func redaction() throws {
        let credential = try #require(build(credentialBody([
            "value": "very-secret-typed-value", "name": "distinctive-field-name",
            "id": "distinctive-field-id", "path": "/distinctive/path",
        ])))
        var dumped = ""
        dump(credential, to: &dumped)

        for rendering in [
            credential.description, credential.debugDescription, "\(credential)",
            String(describing: credential), String(reflecting: credential),
            String(describing: [credential]), String(describing: Optional(credential)), dumped,
        ] {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains("very-secret-typed-value"))
            #expect(!rendering.contains("distinctive-field-name"))
            #expect(!rendering.contains("distinctive-field-id"))
            #expect(!rendering.contains("distinctive"))
            #expect(!rendering.contains("example.com"))
        }
    }
}
