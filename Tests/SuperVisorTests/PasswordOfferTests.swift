import Foundation
import Testing

@testable import SuperVisor

@Suite("Site family")
struct SiteFamilyTests {
    @Test(
        "Hosts are one site when equal, one inside the other, or sharing an owner's parent",
        arguments: [
            ("example.com", "example.com", true),
            ("www.example.com", "example.com", true),
            ("example.com", "login.example.com", true),
            ("a.example.com", "b.example.com", true),
            ("a.b.example.com", "c.example.com", true),
            ("example.com", "example.net", false),
            ("example.com", "other.com", false),
            ("example.com", "notexample.com", false),
            ("example.com", "example.com.evil.test", false),
            ("accounts.google.com", "example.com", false),
            ("login.microsoftonline.com", "example.com", false),
            // Country codes: three labels only under a registry's open second level.
            ("a.example.co.uk", "b.example.co.uk", true),
            ("example.co.uk", "www.example.co.uk", true),
            ("example.co.uk", "other.co.uk", false),
            ("a.co.uk", "b.co.uk", false),
            ("x.com.au", "y.com.au", false),
            ("shop.example.com.au", "login.example.com.au", true),
            ("a.gob.mx", "b.gob.mx", false),
            ("co.uk", "example.co.uk", true),
            ("example.co.uk", "example.co.uk", true),
            ("bank.de", "login.bank.de", true),
            ("login.bank.de", "online.bank.de", true),
            ("example.io", "www.example.io", true),
            ("app.example.io", "auth.example.io", true),
            // Shared hosting: different owners under one parent.
            ("one.github.io", "two.github.io", false),
            ("one.github.io", "github.io", true),
            ("a.app.github.io", "b.app.github.io", false),
            ("www.app.github.io", "app.github.io", true),
            ("shop-a.myshopify.com", "shop-b.myshopify.com", false),
            ("x.herokuapp.com", "y.herokuapp.com", false),
            ("a.us.com", "b.us.com", false),
            ("d1.cloudfront.net", "d2.cloudfront.net", false),
            ("bucket.s3.amazonaws.com", "other.s3.amazonaws.com", false),
            ("my.pages.dev", "your.pages.dev", false),
            // Not host names.
            ("Example.com", "example.com", false),
            ("example.com", "EXAMPLE.COM", false),
            ("localhost", "localhost", false),
            ("intranet", "www.intranet", false),
            ("127.0.0.1", "127.0.0.1", false),
            ("10.0.0.1", "11.0.0.1", false),
            ("example.com.", "example.com", false),
            ("example.com:443", "example.com", false),
            ("", "", false),
        ]
    )
    func sameSite(first: String, second: String, expected: Bool) {
        #expect(SiteFamily.sameSite(first, second) == expected)
        #expect(SiteFamily.sameSite(second, first) == expected)
    }
}

@Suite("Sign-in services")
struct SignInServicesTests {
    @Test(
        "A sign-in service's host or tenant host is on the list, and a site's own sign-in is not",
        arguments: [
            ("accounts.google.com", true),
            ("login.microsoftonline.com", true),
            ("login.live.com", true),
            ("login.microsoft.com", true),
            ("account.microsoft.com", true),
            ("appleid.apple.com", true),
            ("idmsa.apple.com", true),
            ("signin.aws.amazon.com", true),
            ("login.yahoo.com", true),
            ("www.facebook.com", true),
            ("m.facebook.com", true),
            ("acme.okta.com", true),
            ("acme.oktapreview.com", true),
            ("acme.auth0.com", true),
            ("acme.eu.auth0.com", true),
            ("acme.onelogin.com", true),
            ("auth.pingone.com", true),
            ("api-1.duosecurity.com", true),
            ("acme.b2clogin.com", true),
            ("www.amazon.com", false),
            ("mail.google.com", false),
            ("google.com", false),
            ("okta.com", false),
            ("notokta.com", false),
            ("example.com", false),
            ("login.example.com", false),
        ]
    )
    func membership(host: String, listed: Bool) {
        #expect(SignInServices.contains(host) == listed)
    }
}

@Suite("Password offer")
struct PasswordOfferTests {
    private let browseHosts = ["example.com", "login.example.com", "sso.example.org", "evil.test", "acme.okta.com"]

    private func password(
        _ value: String = "hunter2",
        host: String = "example.com",
        path: String = "/login",
        name: String = "password",
        id: String = "pass",
        autocomplete: String = "current-password",
        actionHost: String = "example.com",
        newPassword: Bool = false
    ) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "password", "value": value, "name": name, "id": id, "autocomplete": autocomplete,
            "type": "password", "origin": "https://" + host, "path": path, "actionHost": actionHost,
            "newPassword": newPassword,
        ], host: host))
    }

    private func username(
        _ value: String = "alice",
        host: String = "example.com",
        path: String = "/login",
        name: String = "username",
        id: String = "user",
        autocomplete: String = "username",
        actionHost: String = "example.com"
    ) throws -> TypedCredential {
        try #require(typedCredential([
            "kind": "username", "value": value, "name": name, "id": id, "autocomplete": autocomplete,
            "type": "text", "origin": "https://" + host, "path": path, "actionHost": actionHost,
        ], host: host))
    }

    /// The clear the script reports for a field emptied on a page.
    private func cleared(
        host: String = "example.com",
        path: String = "/login",
        name: String = "password",
        id: String = "pass",
        autocomplete: String = "current-password",
        type: String = "password"
    ) throws -> TypedCredential {
        let body: [String: Any] = [
            "kind": "clear", "name": name, "id": id, "autocomplete": autocomplete, "type": type,
            "origin": "https://" + host, "path": path,
        ]
        return try #require(TypedCredential(
            messageBody: body, isMainFrame: true, frameScheme: "https", frameHost: host, framePort: nil
        ))
    }

    private func field(_ name: String, type: String = "text", autocomplete: String = "") -> ProbedField {
        ProbedField(key: FieldKey(name: name, id: name, autocomplete: autocomplete, type: type), inputMode: "", maxLength: nil)
    }

    private func page(_ fields: [ProbedField], path: String = "/login") -> PageProbe {
        PageProbe(origin: "https://example.com", path: path, isSecureTopFrame: true, hasChallenge: false, fields: fields)
    }

    private var passwordForm: PageProbe {
        page([field("username", autocomplete: "username"), field("password", type: "password", autocomplete: "current-password")])
    }

    private var signedInPage: PageProbe { page([], path: "/home") }

    private var redirectPage: PageProbe { page([], path: "/session") }

    private var codePage: PageProbe {
        page([ProbedField(key: FieldKey(name: "otp", id: "otp", autocomplete: "one-time-code", type: "text"), inputMode: "numeric", maxLength: 6)], path: "/verify")
    }

    private var sessionGrant: SiteGrant {
        SiteGrant(
            username: "",
            password: "",
            authenticatorKey: nil,
            signInURL: URL(string: "https://example.com/login")!,
            startURL: URL(string: "https://example.com/home")!,
            fillHosts: ["example.com"],
            browseHosts: browseHosts,
            codeKind: .none,
            codeSender: nil,
            remembersPassword: false
        )
    }

    /// A sign-in that typed `typed`, then left the form for the signed-in page.
    private func signedIn(_ typed: [TypedCredential]) -> CredentialCapture {
        var capture = CredentialCapture()
        capture.notePage(passwordForm)
        typed.forEach { capture.record($0) }
        capture.notePage(signedInPage)
        return capture
    }

    private func refusal(_ capture: CredentialCapture, browseHosts: [String]? = nil) -> OfferRefusal? {
        guard case let .failure(refusal) = capture.offer(siteHost: "example.com", browseHosts: browseHosts ?? self.browseHosts) else {
            return nil
        }
        return refusal
    }

    private func offer(_ capture: CredentialCapture) throws -> PasswordOffer {
        try capture.offer(siteHost: "example.com", browseHosts: browseHosts).get()
    }

    // MARK: Offers

    @Test("A password that left the form on the site's own page is offered, and its grant fills what was typed where it was typed")
    func offered() throws {
        let offer = try offer(signedIn([try username(), try password()]))

        #expect(offer.usernameText == "alice")
        #expect(offer.passwordHost == "example.com")
        let grant = try #require(offer.grant(upgrading: sessionGrant))
        #expect(grant.password == "hunter2")
        #expect(grant.username == "alice")
        #expect(grant.remembersPassword)
        #expect(grant.signInSteps.map(\.kind) == [.username, .password])
        #expect(grant.signInSteps.last?.field == FieldKey(name: "password", id: "pass", autocomplete: "current-password", type: "password"))
        #expect(grant.fillHosts == ["example.com"])
        #expect(grant.browseHosts == browseHosts)
        #expect(grant.isValid(for: "example.com"))
    }

    @Test("A password typed on a subdomain of the site among its browse hosts is offered, and one with no user name has none")
    func offeredOnSubdomain() throws {
        let offer = try offer(signedIn([try password(host: "login.example.com", actionHost: "login.example.com")]))

        #expect(offer.passwordHost == "login.example.com")
        #expect(offer.usernameText == nil)
        let grant = try #require(offer.grant(upgrading: sessionGrant))
        #expect(grant.username.isEmpty)
        #expect(grant.signInSteps.map(\.kind) == [.password])
        #expect(grant.fillHosts == ["example.com", "login.example.com"])
    }

    @Test("An offer builds no grant on a grant that keeps a password, or whose browse hosts lack where it was typed")
    func grantGuards() throws {
        let offer = try offer(signedIn([try password(host: "login.example.com", actionHost: "login.example.com")]))
        let narrow = SiteGrant(
            username: "", password: "", authenticatorKey: nil,
            signInURL: sessionGrant.signInURL, startURL: sessionGrant.startURL,
            fillHosts: ["example.com"], browseHosts: ["example.com"],
            codeKind: .none, codeSender: nil, remembersPassword: false
        )
        #expect(offer.grant(upgrading: narrow) == nil)
        let kept = try #require(offer.grant(upgrading: sessionGrant))
        #expect(offer.grant(upgrading: kept) == nil)
    }

    @Test("A field identified by its autocomplete token alone can be found again, so it is offered")
    func autocompleteOnly() throws {
        #expect(refusal(signedIn([try password(name: "", id: "", autocomplete: "current-password")])) == nil)
    }

    @Test("A form with no action is offered on the page's own host")
    func noActionHost() throws {
        #expect(refusal(signedIn([try password(actionHost: "")])) == nil)
    }

    @Test("A masked code or PIN field on a later page is not taken for the password form, and the password is still offered")
    func maskedSecretOnALaterPage() throws {
        var capture = CredentialCapture()
        capture.notePage(passwordForm)
        capture.record(try username())
        capture.record(try password())
        capture.notePage(redirectPage)
        capture.notePage(page([field("otp", type: "password")], path: "/verify"))
        capture.notePage(page([field("pin", type: "password")], path: "/pin"))
        capture.notePage(signedInPage)

        #expect(!capture.askedAgain)
        #expect(!capture.severalSecrets)
        let offer = try offer(capture)
        #expect(try #require(offer.grant(upgrading: sessionGrant)).password == "hunter2")
    }

    @Test("Typing again into the same field on the same page replaces the value and is one secret")
    func retypingIsOneSecret() throws {
        var capture = CredentialCapture()
        capture.record(try password("first"))
        capture.record(try password("second"))
        capture.notePage(signedInPage)

        #expect(!capture.severalSecrets)
        #expect(try #require(offer(capture).grant(upgrading: sessionGrant)).password == "second")
    }

    // MARK: Clears

    @Test("A cleared password field drops the value held for it, so nothing is left to offer")
    func clearedPassword() throws {
        var capture = CredentialCapture()
        capture.record(try username())
        capture.record(try password("stale"))
        capture.record(try cleared())
        capture.notePage(signedInPage)

        #expect(capture.password == nil)
        #expect(refusal(capture) == .nothingTyped)
    }

    @Test("A clear drops only the value typed into that field on that page")
    func clearIsScopedToItsField() throws {
        var capture = CredentialCapture()
        capture.record(try username("alice"))
        capture.record(try password("hunter2"))

        capture.record(try cleared(path: "/other"))
        capture.record(try cleared(name: "different", id: "different"))
        #expect(capture.password != nil)

        capture.record(try cleared(name: "username", id: "user", autocomplete: "username", type: "text"))
        #expect(capture.username == nil)
        #expect(capture.password != nil)
        capture.notePage(signedInPage)
        #expect(try offer(capture).usernameText == nil)
    }

    // MARK: Refusals, each alone

    @Test("No password typed: nothingTyped, even when a user name was")
    func nothingTyped() throws {
        #expect(refusal(CredentialCapture()) == .nothingTyped)
        #expect(refusal(signedIn([try username()])) == .nothingTyped)
        #expect(OfferRefusal.nothingTyped.sentence == nil)
    }

    @Test("The site asking for the password again: askedAgain")
    func askedAgain() throws {
        var capture = signedIn([try password()])
        capture.notePage(passwordForm)
        #expect(refusal(capture) == .askedAgain)

        var typedTwice = signedIn([try password()])
        typedTwice.record(try password("other"))
        #expect(refusal(typedTwice) == .askedAgain)
    }

    @Test("A second password field on a later page, with the form never left in between: severalSecrets")
    func severalSecrets() throws {
        var capture = CredentialCapture()
        capture.notePage(passwordForm)
        capture.record(try password("hunter2"))
        capture.notePage(page([field("password", type: "password"), field("", type: "password")], path: "/step-two"))
        capture.record(try password("1234", path: "/step-two", name: "", id: "", autocomplete: ""))
        capture.notePage(signedInPage)

        #expect(capture.severalSecrets)
        #expect(refusal(capture) == .severalSecrets)
    }

    @Test("A second password field on the same page: severalSecrets")
    func severalSecretsOnOnePage() throws {
        var capture = CredentialCapture()
        capture.record(try password("hunter2"))
        capture.record(try password("memorable", name: "word", id: "word", autocomplete: ""))
        capture.notePage(signedInPage)
        #expect(refusal(capture) == .severalSecrets)
    }

    @Test("A change-password or sign-up form: newPasswordForm")
    func newPasswordForm() throws {
        #expect(refusal(signedIn([try password(newPassword: true)])) == .newPasswordForm)
    }

    @Test("A sign-in code asked for: codeAsked")
    func codeAsked() throws {
        var capture = CredentialCapture()
        capture.record(try password())
        capture.notePage(codePage)
        capture.notePage(signedInPage)
        #expect(refusal(capture) == .codeAsked)
    }

    @Test("A password or user name field with no name, id, or autocomplete token: fieldUnidentified")
    func fieldUnidentified() throws {
        #expect(refusal(signedIn([try password(name: "", id: "", autocomplete: "")])) == .fieldUnidentified)
        #expect(refusal(signedIn([try username(name: "", id: "", autocomplete: ""), try password()])) == .fieldUnidentified)
    }

    @Test("A value typed on a sign-in service: signInService, whatever the site's family")
    func signInService() throws {
        let tenant = signedIn([try password(host: "acme.okta.com", actionHost: "acme.okta.com")])
        #expect(refusal(tenant) == .signInService)

        // A Google-family site whose password went in at accounts.google.com.
        let google = signedIn([try password(host: "accounts.google.com", actionHost: "accounts.google.com")])
        guard case let .failure(googleRefusal) = google.offer(
            siteHost: "mail.google.com",
            browseHosts: ["mail.google.com", "accounts.google.com"]
        ) else {
            Issue.record("a password typed at accounts.google.com was offered")
            return
        }
        #expect(googleRefusal == .signInService)

        // Only the user name went to the service.
        let username = signedIn([try username(host: "acme.okta.com", actionHost: "acme.okta.com"), try password()])
        #expect(refusal(username) == .signInService)

        // A form on the site that sends to the service.
        #expect(refusal(signedIn([try password(actionHost: "acme.okta.com")])) == .signInService)
    }

    @Test("A value typed or sent outside the site's family or its browse hosts: anotherCompany")
    func anotherCompany() throws {
        // Another owner's page, though the sign-in passed through it.
        #expect(refusal(signedIn([try password(host: "sso.example.org", actionHost: "sso.example.org")])) == .anotherCompany)
        // The site's family but not among its browse hosts.
        #expect(refusal(signedIn([try password(host: "id.example.com", actionHost: "id.example.com")])) == .anotherCompany)
        // A form on the site that sends the password elsewhere.
        #expect(refusal(signedIn([try password(actionHost: "evil.test")])) == .anotherCompany)
        #expect(refusal(signedIn([try password(actionHost: "id.example.com")])) == .anotherCompany)
        // The user name went to another owner while the password stayed home.
        #expect(refusal(signedIn([try username(host: "sso.example.org", actionHost: "sso.example.org"), try password()])) == .anotherCompany)
        #expect(refusal(signedIn([try username(actionHost: "evil.test"), try password()])) == .anotherCompany)
    }

    @Test("Any host a value was typed on counts, one whose value was replaced or cleared included")
    func everyTypedHostCounts() throws {
        var replaced = CredentialCapture()
        replaced.record(try username("first", host: "sso.example.org", actionHost: "sso.example.org"))
        replaced.record(try username("second"))
        replaced.record(try password())
        replaced.notePage(signedInPage)
        #expect(replaced.username?.value == "second")
        #expect(refusal(replaced) == .anotherCompany)

        var clearedThere = CredentialCapture()
        clearedThere.record(try password("elsewhere", host: "sso.example.org", actionHost: "sso.example.org"))
        clearedThere.record(try cleared(host: "sso.example.org"))
        clearedThere.notePage(redirectPage)
        clearedThere.notePage(passwordForm)
        clearedThere.record(try password())
        clearedThere.notePage(signedInPage)
        #expect(refusal(clearedThere) == .anotherCompany)
    }

    @Test("Every refusal but nothingTyped has a sentence")
    func sentences() {
        for refusal in OfferRefusal.allCases where refusal != .nothingTyped {
            #expect(refusal.sentence?.isEmpty == false, "\(refusal.caseName)")
        }
        #expect(OfferRefusal.allCases.map(\.caseName) == [
            "nothingTyped", "askedAgain", "severalSecrets", "newPasswordForm", "codeAsked",
            "fieldUnidentified", "signInService", "anotherCompany",
        ])
    }

    // MARK: Precedence

    @Test("When two refusals apply, the earlier in the list is given")
    func precedence() throws {
        // askedAgain over severalSecrets and newPasswordForm.
        var asked = CredentialCapture()
        asked.record(try password(newPassword: true))
        asked.record(try password("other", name: "other", id: "other"))
        asked.notePage(signedInPage)
        asked.notePage(passwordForm)
        #expect(refusal(asked) == .askedAgain)

        // severalSecrets over newPasswordForm.
        var several = CredentialCapture()
        several.record(try password(newPassword: true))
        several.record(try password("other", name: "other", id: "other"))
        several.notePage(signedInPage)
        #expect(refusal(several) == .severalSecrets)

        // newPasswordForm over codeAsked.
        var newForm = CredentialCapture()
        newForm.record(try password(newPassword: true))
        newForm.notePage(codePage)
        #expect(refusal(newForm) == .newPasswordForm)

        // codeAsked over fieldUnidentified.
        var code = CredentialCapture()
        code.record(try password(name: "", id: "", autocomplete: ""))
        code.notePage(codePage)
        #expect(refusal(code) == .codeAsked)

        // fieldUnidentified over signInService.
        let unidentified = signedIn([try password(host: "acme.okta.com", name: "", id: "", autocomplete: "", actionHost: "acme.okta.com")])
        #expect(refusal(unidentified) == .fieldUnidentified)

        // signInService over anotherCompany.
        #expect(refusal(signedIn([try password(host: "acme.okta.com", actionHost: "acme.okta.com")]), browseHosts: ["example.com"]) == .signInService)
    }

    // MARK: Redaction

    @Test("An offer prints as a fixed placeholder however it is rendered")
    func redaction() throws {
        let offer = try offer(signedIn([try username("distinctive-user-name"), try password("distinctive-pass-value")]))
        var dumped = ""
        dump(offer, to: &dumped)

        let renderings = [
            offer.description, offer.debugDescription, "\(offer)", String(describing: offer),
            String(reflecting: offer), String(describing: [offer]), String(describing: Optional(offer)), dumped,
        ]
        for rendering in renderings {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains("distinctive"))
            #expect(!rendering.contains("example.com"))
        }
    }
}
