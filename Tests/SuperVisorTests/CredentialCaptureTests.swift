import Foundation
import Testing

@testable import SuperVisor

@Suite("Credential capture")
struct CredentialCaptureTests {
    private let host = "example.com"

    private func password(
        _ value: String,
        path: String = "/login",
        host: String = "example.com",
        id: String = "pass",
        newPassword: Bool = false,
        passwordFields: Int = 1
    ) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "password", "value": value, "id": id, "name": id, "type": "password",
            "origin": "https://" + host, "path": path, "newPassword": newPassword,
            "passwordFields": passwordFields,
        ], host: host))
    }

    private func username(
        _ value: String,
        path: String = "/login",
        host: String = "example.com",
        passwordFields: Int = 1
    ) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "username", "value": value, "id": "user", "name": "user", "type": "text",
            "autocomplete": "username", "origin": "https://" + host, "path": path,
            "passwordFields": passwordFields,
        ], host: host))
    }

    private func page(_ fields: [ProbedField], path: String = "/login") -> PageProbe {
        PageProbe(origin: "https://example.com", path: path, isSecureTopFrame: true, hasChallenge: false, fields: fields)
    }

    private func field(
        id: String,
        type: String = "text",
        autocomplete: String = "",
        inputMode: String = "",
        maxLength: Int? = nil
    ) -> ProbedField {
        ProbedField(
            key: FieldKey(name: id, id: id, autocomplete: autocomplete, type: type),
            inputMode: inputMode,
            maxLength: maxLength
        )
    }

    private var passwordForm: PageProbe {
        page([field(id: "user", autocomplete: "username"), field(id: "pass", type: "password")])
    }

    private var signedInPage: PageProbe {
        page([field(id: "search")], path: "/home")
    }

    private func assertFlags(
        _ capture: CredentialCapture,
        left: Bool = false,
        asked: Bool = false,
        newForm: Bool = false,
        code: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(capture.leftPasswordForm == left, "leftPasswordForm", sourceLocation: sourceLocation)
        #expect(capture.askedAgain == asked, "askedAgain", sourceLocation: sourceLocation)
        #expect(capture.sawNewPasswordForm == newForm, "sawNewPasswordForm", sourceLocation: sourceLocation)
        #expect(capture.sawCodeField == code, "sawCodeField", sourceLocation: sourceLocation)
    }

    // MARK: Sign-ins

    @Test("A new capture holds nothing")
    func startsEmpty() {
        let capture = CredentialCapture()

        #expect(capture.password == nil)
        #expect(capture.username == nil)
        #expect(capture.hostsTypedOn.isEmpty)
        assertFlags(capture)
    }

    @Test("A one-page sign-in keeps the last password typed with its user name, and the page leaving the form is noted")
    func onePageSignIn() throws {
        var capture = CredentialCapture()
        capture.notePage(passwordForm)
        capture.record(try username("alice"))
        // Each keystroke reports the whole value; the last report stands.
        capture.record(try password("h"))
        capture.record(try password("hunter"))
        capture.record(try password("hunter2"))
        assertFlags(capture)

        capture.notePage(signedInPage)

        let typed = try #require(capture.password)
        #expect(typed.value == "hunter2")
        #expect(typed.field.id == "pass")
        #expect(typed.origin == "https://example.com")
        #expect(typed.path == "/login")
        #expect(typed.actionHost == "example.com")
        #expect(capture.username?.value == "alice")
        #expect(capture.username?.field.autocomplete == "username")
        #expect(capture.hostsTypedOn == [host])
        assertFlags(capture, left: true)
    }

    @Test("A two-step sign-in keeps the user name typed on the first page with the password of the second")
    func twoStepSignIn() throws {
        var capture = CredentialCapture()
        capture.notePage(page([field(id: "user", autocomplete: "username")], path: "/signin"))
        capture.record(try username("alice", path: "/signin", passwordFields: 0))
        capture.notePage(page([field(id: "pass", type: "password")], path: "/password"))
        capture.record(try password("hunter2", path: "/password"))
        assertFlags(capture)

        capture.notePage(signedInPage)

        #expect(capture.username?.value == "alice")
        #expect(capture.username?.path == "/signin")
        #expect(capture.password?.value == "hunter2")
        #expect(capture.password?.path == "/password")
        assertFlags(capture, left: true)
    }

    @Test("A page that still shows the password field after it was typed has not left the form")
    func stayingOnTheForm() throws {
        var capture = CredentialCapture()
        capture.record(try password("hunter2"))

        capture.notePage(passwordForm)
        capture.notePage(passwordForm)

        assertFlags(capture)
    }

    @Test("Pages shown before any password was typed say nothing about leaving the form")
    func pagesBeforeAPassword() throws {
        var capture = CredentialCapture()

        capture.notePage(signedInPage)
        capture.notePage(passwordForm)
        capture.notePage(signedInPage)
        capture.record(try username("alice"))
        capture.notePage(signedInPage)

        assertFlags(capture)
        #expect(capture.password == nil)
    }

    // MARK: Asked again

    @Test("A wrong password, a page without the form, the form again, then the right password: asked again")
    func wrongThenRight() throws {
        var capture = CredentialCapture()
        capture.record(try username("alice"))
        capture.record(try password("wrong-one"))
        capture.notePage(page([], path: "/checking"))
        assertFlags(capture, left: true)

        capture.notePage(passwordForm)
        assertFlags(capture, left: true, asked: true)

        capture.record(try password("right-one"))

        #expect(capture.password?.value == "right-one")
        #expect(capture.username?.value == "alice")
        assertFlags(capture, left: true, asked: true)
    }

    @Test("A password typed again after the page left the form is asking again, with no page shown in between")
    func typedAgainAfterLeaving() throws {
        var capture = CredentialCapture()
        capture.record(try password("first"))
        capture.notePage(signedInPage)
        assertFlags(capture, left: true)

        capture.record(try password("second"))

        #expect(capture.password?.value == "second")
        assertFlags(capture, left: true, asked: true)
    }

    @Test("A form shown again after leaving it is asking again, whatever it shows")
    func formShownAgain() throws {
        var capture = CredentialCapture()
        capture.record(try password("hunter2"))
        capture.notePage(signedInPage)
        capture.notePage(page([field(id: "other", type: "password")], path: "/elsewhere"))

        #expect(capture.password?.value == "hunter2")
        assertFlags(capture, left: true, asked: true)
    }

    @Test("Passwords typed in a row before the page left the form are one attempt")
    func keystrokesAreOneAttempt() throws {
        var capture = CredentialCapture()

        for value in ["a", "ab", "abc", "abcd"] {
            capture.record(try password(value))
        }

        #expect(capture.password?.value == "abcd")
        assertFlags(capture)
    }

    // MARK: New-password forms

    @Test("A field that asks for a new password marks a change-password or sign-up form")
    func newPasswordToken() throws {
        var capture = CredentialCapture()

        capture.record(try password("hunter2", newPassword: true))

        assertFlags(capture, newForm: true)
    }

    @Test("A document with two password inputs marks a change-password form, whichever kind of report says so")
    func twoPasswordInputs() throws {
        var fromPassword = CredentialCapture()
        fromPassword.record(try password("hunter2", passwordFields: 2))
        assertFlags(fromPassword, newForm: true)

        var fromUsername = CredentialCapture()
        fromUsername.record(try username("alice", passwordFields: 3))
        assertFlags(fromUsername, newForm: true)
    }

    @Test("Passwords typed into two different fields of one page mark a form that asks for a new password")
    func twoFieldsOnOnePage() throws {
        var capture = CredentialCapture()
        capture.record(try password("old-one", id: "current"))
        capture.record(try password("old-one-more", id: "current"))
        assertFlags(capture)

        capture.record(try password("new-one", id: "replacement"))

        assertFlags(capture, newForm: true)
        #expect(capture.password?.value == "new-one")
    }

    @Test("The same field on another page, or another field on another page, is no new-password form")
    func fieldsOnDifferentPages() throws {
        var capture = CredentialCapture()
        capture.record(try password("one", path: "/login", id: "first"))
        capture.record(try password("two", path: "/retry", id: "second"))
        capture.record(try password("three", path: "/login", id: "first"))

        assertFlags(capture)

        capture.record(try password("four", host: "accounts.example.com", id: "other"))
        assertFlags(capture)
    }

    @Test("A new-password form stays noted however the sign-in goes on")
    func newPasswordFormIsSticky() throws {
        var capture = CredentialCapture()
        capture.record(try password("hunter2", newPassword: true))

        capture.record(try password("again"))
        capture.notePage(signedInPage)
        capture.record(try password("once more"))

        assertFlags(capture, left: true, asked: true, newForm: true)
    }

    // MARK: Codes

    @Test("A code field on a page noted after the password is a code step")
    func codeStep() throws {
        var capture = CredentialCapture()
        capture.record(try password("hunter2"))

        capture.notePage(page([field(id: "otp", autocomplete: "one-time-code")], path: "/verify"))

        assertFlags(capture, left: true, code: true)
    }

    @Test("A row of single-character boxes is a code too, and so is a code field noted before any password")
    func splitCodeAndEarlyCode() {
        let boxes = (1...6).map { field(id: "digit-\($0)", inputMode: "numeric", maxLength: 1) }
        var split = CredentialCapture()
        split.notePage(page(boxes, path: "/verify"))
        assertFlags(split, code: true)

        var early = CredentialCapture()
        early.notePage(page([field(id: "code", inputMode: "numeric", maxLength: 6)]))
        assertFlags(early, code: true)

        var fewBoxes = CredentialCapture()
        fewBoxes.notePage(page(Array(boxes.prefix(3))))
        assertFlags(fewBoxes)
    }

    // MARK: User names

    @Test("A user name typed on the password's page after the password replaces the one before it")
    func usernameEditedAlongside() throws {
        var capture = CredentialCapture()
        capture.record(try username("alicia"))
        capture.record(try password("hunter2"))

        capture.record(try username("alice"))

        #expect(capture.username?.value == "alice")
        #expect(capture.password?.value == "hunter2")
    }

    @Test("A user name typed after the password on another page replaces nothing, and goes with the next password")
    func usernameAfterThePasswordElsewhere() throws {
        var capture = CredentialCapture()
        capture.record(try username("first-user", path: "/signin"))
        capture.record(try password("wrong", path: "/password"))

        capture.record(try username("second-user", path: "/signin"))
        #expect(capture.username?.value == "first-user")
        #expect(capture.password?.value == "wrong")

        capture.record(try password("right", path: "/password"))
        #expect(capture.username?.value == "second-user")
        #expect(capture.password?.value == "right")

        // Further typing in the same password field stays paired with that user name.
        capture.record(try password("right-still", path: "/password"))
        #expect(capture.username?.value == "second-user")
    }

    @Test("A user name typed on another host, with no password yet, is the latest user name")
    func latestUsernameBeforeAPassword() throws {
        var capture = CredentialCapture()
        capture.record(try username("one", host: "accounts.example.com"))
        capture.record(try username("two", host: "www.example.com"))

        #expect(capture.username?.value == "two")
        #expect(capture.password == nil)
        #expect(capture.hostsTypedOn == ["accounts.example.com", "www.example.com"])
    }

    @Test("A password typed with no user name beforehand has none")
    func passwordWithoutUsername() throws {
        var capture = CredentialCapture()

        capture.record(try password("hunter2"))

        #expect(capture.username == nil)
        #expect(capture.password?.value == "hunter2")
    }

    @Test("The hosts a value was typed on are collected across both kinds of report")
    func hosts() throws {
        var capture = CredentialCapture()
        capture.record(try username("alice", host: "accounts.example.com"))
        capture.record(try password("hunter2", host: "www.example.com"))
        capture.record(try password("hunter22", host: "www.example.com"))

        #expect(capture.hostsTypedOn == ["accounts.example.com", "www.example.com"])
    }

    // MARK: Wipe

    @Test("Wiping forgets every value, fact, and host")
    func wipe() throws {
        var capture = CredentialCapture()
        capture.notePage(page([field(id: "otp", autocomplete: "one-time-code")]))
        capture.record(try username("alice", path: "/signin"))
        capture.record(try password("hunter2", path: "/password", newPassword: true))
        capture.notePage(signedInPage)
        capture.record(try password("again", path: "/password"))
        capture.record(try username("later", path: "/elsewhere"))
        #expect(capture.password != nil)
        assertFlags(capture, left: true, asked: true, newForm: true, code: true)

        capture.wipe()

        #expect(capture.password == nil)
        #expect(capture.username == nil)
        #expect(capture.hostsTypedOn.isEmpty)
        assertFlags(capture)
        #expect(capture == CredentialCapture())

        // A password typed after the wipe starts from nothing: the earlier waiting user name is
        // gone, and no earlier flag carries over.
        capture.record(try password("fresh", path: "/password"))
        #expect(capture.username == nil)
        assertFlags(capture)
    }

    // MARK: Redaction

    @Test("A capture and its records print as a fixed placeholder however they are rendered")
    func redaction() throws {
        var capture = CredentialCapture()
        capture.record(try username("distinctive-user-name"))
        capture.record(try password("distinctive-pass-value"))
        let typed = try #require(capture.password)
        let name = try #require(capture.username)
        var dumpedCapture = ""
        dump(capture, to: &dumpedCapture)
        var dumpedRecord = ""
        dump(typed, to: &dumpedRecord)

        let renderings = [
            capture.description, capture.debugDescription, "\(capture)", String(describing: capture),
            String(reflecting: capture), String(describing: [capture]), dumpedCapture,
            typed.description, typed.debugDescription, "\(typed)", String(describing: typed),
            String(reflecting: typed), String(describing: [typed]), dumpedRecord,
            name.description, String(describing: name),
        ]
        for rendering in renderings {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains("distinctive"))
            #expect(!rendering.contains("example.com"))
            #expect(!rendering.contains("/login"))
        }
    }
}
