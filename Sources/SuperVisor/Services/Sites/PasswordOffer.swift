import Foundation

/// Whether two hosts belong to one site, judged from their names alone with no list of public
/// suffixes.
///
/// Two hosts are one site when they are equal, when one is a subdomain of the other, or when
/// they share a parent domain of at least two labels, with two exceptions for parents under
/// which different owners live:
///
/// - A parent that ends in a two-letter label after one of `registryLabels` (`co.uk`,
///   `com.au`) is open to anyone, so the shared parent needs three labels there:
///   `a.example.co.uk` and `b.example.co.uk` are one site, `a.co.uk` and `b.co.uk` are not.
///   Under any other two-letter ending two labels suffice: `login.bank.de` and
///   `online.bank.de` are one site.
/// - A shared parent that is one of `sharedHostingSuffixes`, a parent of one, or a domain under
///   one never makes two hosts one site: `one.github.io` and `two.github.io` belong to
///   different people, and so do two buckets under `s3.amazonaws.com`. Such hosts are one site
///   only when equal or one is a subdomain of the other.
///
/// Only names `SiteHost.isValid` accepts are compared, so uppercase, IP literals, single
/// labels, ports, and trailing dots are never one site with anything. A wrong "no" costs only
/// an offer to keep a password.
enum SiteFamily {
    /// Second-level labels under a country code that registries open to anyone.
    static let registryLabels: Set<String> = [
        "co", "com", "org", "net", "gov", "ac", "edu", "or", "ne", "go", "gob", "nom",
    ]

    /// Domains under which hosting services give each customer a name of their own.
    static let sharedHostingSuffixes: Set<String> = [
        "github.io", "gitlab.io", "herokuapp.com", "azurewebsites.net", "cloudfront.net",
        "amazonaws.com", "vercel.app", "netlify.app", "pages.dev", "web.app", "firebaseapp.com",
        "appspot.com", "blogspot.com", "myshopify.com", "us.com", "workers.dev", "onrender.com",
        "fly.dev",
    ]

    static func sameSite(_ a: String, _ b: String) -> Bool {
        guard SiteHost.isValid(a), SiteHost.isValid(b) else { return false }
        if a == b || a.hasSuffix("." + b) || b.hasSuffix("." + a) { return true }
        let first = a.split(separator: ".", omittingEmptySubsequences: false)
        let second = b.split(separator: ".", omittingEmptySubsequences: false)
        var shared = 0
        while shared < min(first.count, second.count),
              first[first.count - 1 - shared] == second[second.count - 1 - shared] {
            shared += 1
        }
        guard shared >= 2 else { return false }
        let parent = first.suffix(shared).joined(separator: ".")
        if sharedHostingSuffixes.contains(where: {
            $0 == parent || $0.hasSuffix("." + parent) || parent.hasSuffix("." + $0)
        }) {
            return false
        }
        let last = first[first.count - 1]
        let penultimate = String(first[first.count - 2])
        let required = last.count == 2 && registryLabels.contains(penultimate) ? 3 : 2
        return shared >= required
    }
}

/// Sign-in services whose password opens an account that spans many sites. Such a password is
/// never kept for one site, whatever site it was typed for.
///
/// A host earns a place when the password typed on it signs in to an account used across many
/// sites or services: a mail and identity provider, or a company sign-in that opens every app
/// of a workplace. A shop's own sign-in, such as `www.amazon.com`, opens that shop alone and has
/// no place here.
enum SignInServices {
    static let hosts: Set<String> = [
        "accounts.google.com", "login.microsoftonline.com", "login.live.com", "login.microsoft.com",
        "account.microsoft.com", "appleid.apple.com", "idmsa.apple.com", "signin.aws.amazon.com",
        "login.yahoo.com", "www.facebook.com", "m.facebook.com",
    ]

    /// The domains under which each customer of a workplace sign-in service has a host of its own.
    static let tenantSuffixes: [String] = [
        ".okta.com", ".oktapreview.com", ".auth0.com", ".onelogin.com", ".pingone.com",
        ".duosecurity.com", ".b2clogin.com",
    ]

    static func contains(_ host: String) -> Bool {
        hosts.contains(host) || tenantSuffixes.contains { host.hasSuffix($0) }
    }
}

/// Why no offer to keep a typed password is made, in the order the reasons are checked.
enum OfferRefusal: Error, Equatable, Sendable, CaseIterable {
    /// No password was typed into the page.
    case nothingTyped
    /// The site asked for the password again after the form was left, or a password was typed
    /// again after it: which password works is unknown.
    case askedAgain
    /// Passwords went into two fields, or onto two pages, with no page between them that
    /// showed no password field: which value is the account's password is unknown.
    case severalSecrets
    /// A change-password or sign-up form was seen, where the value typed is a new password.
    case newPasswordForm
    /// The site asked for a sign-in code, which an unattended sign-in with this password
    /// could not answer.
    case codeAsked
    /// The password field, or the user name field, carries no name, id, or autocomplete token,
    /// so a later sign-in could not find it.
    case fieldUnidentified
    /// A value was typed on a sign-in service whose password opens more than this site
    /// (`SignInServices`).
    case signInService
    /// A value was typed on a page, or the password or user name into a form sending to a
    /// host, that is outside the site's family or its browse hosts.
    case anotherCompany

    /// What the sign-in window says; nil for `nothingTyped`, where the window says nothing.
    var sentence: String? {
        switch self {
        case .nothingTyped:
            nil
        case .askedAgain:
            "The site asked for your password more than once, so SuperVisor can't tell which one worked. It kept the session only."
        case .severalSecrets:
            "More than one password-like value was typed, so SuperVisor can't tell which one is the password."
        case .newPasswordForm:
            "This looked like a form for a new password, so SuperVisor kept the session only."
        case .codeAsked:
            "The site asked for a sign-in code, which SuperVisor can't answer by itself here, so it kept the session only."
        case .fieldUnidentified:
            "SuperVisor couldn't tell which field took the password well enough to fill it again, so it kept the session only."
        case .signInService:
            "That password signs in to more than this site, so SuperVisor won't keep it."
        case .anotherCompany:
            "That was typed on a different address than this site's, so SuperVisor can't tell it belongs here."
        }
    }

    var caseName: String {
        switch self {
        case .nothingTyped: "nothingTyped"
        case .askedAgain: "askedAgain"
        case .severalSecrets: "severalSecrets"
        case .newPasswordForm: "newPasswordForm"
        case .codeAsked: "codeAsked"
        case .fieldUnidentified: "fieldUnidentified"
        case .signInService: "signInService"
        case .anotherCompany: "anotherCompany"
        }
    }
}

/// A password the person typed into a site's own sign-in, which the app may offer to keep, with
/// the user name typed before it when there was one.
///
/// It exists only when `CredentialCapture.offer(siteHost:browseHosts:)` found nothing against
/// keeping it. The values and the fields they went into are readable only here, by
/// `grant(upgrading:)`; a window gets `usernameText` and `passwordHost`. It carries a secret, so
/// every textual rendering, `dump` included, is a fixed placeholder, and it has no encoded form.
struct PasswordOffer: Equatable, Sendable {
    fileprivate let password: CredentialCapture.Record
    fileprivate let username: CredentialCapture.Record?

    /// The user name as typed, for the window to show; nil when none was typed.
    var usernameText: String? { username?.value }

    /// The host the password was typed on.
    var passwordHost: String { password.host }

    /// A grant that signs in to `session`'s site by itself with this password, or nil when the
    /// result would not be a valid grant. Its steps fill the user name, when one was typed, and
    /// the password, each into the field and on the page it was typed at; its fill hosts are the
    /// sign-in host, then the hosts those pages and their forms belong to, each of which must be
    /// one of the session's browse hosts. Everything else comes from `session`.
    func grant(upgrading session: SiteGrant) -> SiteGrant? {
        guard !session.remembersPassword,
              let signInHost = session.signInURL.host(percentEncoded: false)?.lowercased()
        else { return nil }
        func step(_ kind: SignInStep.Kind, _ record: CredentialCapture.Record) -> SignInStep {
            SignInStep(kind: kind, origin: record.origin, path: record.path, field: record.field)
        }
        let typed = [username, password].compactMap { $0 }
        let steps = [username.map { step(.username, $0) }, step(.password, password)].compactMap { $0 }
        var fillHosts = [signInHost]
        for host in typed.map(\.host) + typed.compactMap(\.actionHost) where !fillHosts.contains(host) {
            fillHosts.append(host)
        }
        guard fillHosts.allSatisfy(session.browseHosts.contains) else { return nil }

        let grant = SiteGrant(
            username: username?.value ?? "",
            password: password.value,
            authenticatorKey: nil,
            signInURL: session.signInURL,
            startURL: session.startURL,
            fillHosts: fillHosts,
            browseHosts: session.browseHosts,
            codeKind: .none,
            codeSender: nil,
            signInSteps: steps,
            signOutControlSeen: session.signOutControlSeen,
            signInControlAbsent: session.signInControlAbsent
        )
        return grant.isValid(for: signInHost) ? grant : nil
    }
}

extension PasswordOffer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "PasswordOffer(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

extension CredentialCapture.Record {
    /// The host of `origin`.
    fileprivate var host: String { String(origin.dropFirst("https://".count)) }

    /// Whether a later sign-in could find the field: it has a name, an id, or an autocomplete
    /// token.
    fileprivate var isIdentifiable: Bool {
        !field.name.isEmpty || !field.id.isEmpty || !field.autocomplete.isEmpty
    }
}

extension CredentialCapture {
    /// The offer to keep the password typed last, or why there is none. `siteHost` is the site's
    /// sign-in host and `browseHosts` the hosts its grant lets pages load from. The refusals are
    /// checked in the order `OfferRefusal` lists them, and the first that applies is returned.
    ///
    /// Whether the password worked is judged from what was noted after it was typed: no password
    /// form was shown, and no password typed, after a page without a password field
    /// (`askedAgain`). That the sign-in got past the password form at all is the caller's to
    /// establish: `SiteEnrollment` judges a capture only after noting the page Done saves,
    /// which shows no password field.
    ///
    /// The hosts checked against `SignInServices`, the site's family, and `browseHosts` are
    /// every host a value was typed on (`hostsTypedOn`), a cleared one included, and the hosts
    /// the forms of the password and user name send to.
    func offer(siteHost: String, browseHosts: [String]) -> Result<PasswordOffer, OfferRefusal> {
        guard let password else { return .failure(.nothingTyped) }
        if askedAgain { return .failure(.askedAgain) }
        if severalSecrets { return .failure(.severalSecrets) }
        if sawNewPasswordForm { return .failure(.newPasswordForm) }
        if sawCodeField { return .failure(.codeAsked) }
        let typed = [password] + [username].compactMap { $0 }
        guard typed.allSatisfy(\.isIdentifiable) else { return .failure(.fieldUnidentified) }
        let hosts = hostsTypedOn.union(typed.map(\.host)).union(typed.compactMap(\.actionHost))
        if hosts.contains(where: SignInServices.contains) { return .failure(.signInService) }
        guard hosts.allSatisfy({ SiteFamily.sameSite($0, siteHost) && browseHosts.contains($0) }) else {
            return .failure(.anotherCompany)
        }
        return .success(PasswordOffer(password: password, username: username))
    }
}
