import Foundation
import Security

/// Named secrets, one per account.
protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    /// Stores `data` as a new item, replacing any item already stored for `account`.
    func write(_ data: Data, account: String) throws
    /// Removes the item for `account`. A missing item is not an error.
    func delete(account: String) throws
}

/// A Keychain call failed with this `OSStatus`.
struct KeychainError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus

    var description: String { "Keychain error \(status)" }
}

/// Replaces an item by deleting it and adding a new one, putting the earlier item back when
/// the add fails so a failed write does not destroy what was stored.
enum SecretReplacement {
    static func replace(
        _ data: Data,
        account: String,
        read: (String) throws -> Data?,
        delete: (String) throws -> Void,
        add: (Data, String) throws -> Void
    ) throws {
        let earlier = try read(account)
        try delete(account)
        do {
            try add(data, account)
        } catch {
            if let earlier { try? add(earlier, account) }
            throw error
        }
    }
}

/// Generic-password items in the user's login keychain under one service name.
///
/// Every operation names the login keychain by path. The default keychain is a user setting;
/// were it pointed at another keychain, a new item holding a password would be created there,
/// under access rules this app did not choose. When the named keychain cannot be opened, the
/// operation throws.
struct KeychainSecretStore: SecretStore {
    let service: String
    /// The keychain file every operation addresses: the login keychain unless a test names
    /// another.
    var keychainPath = KeychainSecretStore.loginKeychainPath

    static var loginKeychainPath: String {
        NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
    }

    func read(account: String) throws -> Data? {
        var query = try pinnedQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Deletes any existing item and adds a new one; it never updates in place. An item planted
    /// in advance under the same name keeps its own access list when updated, so whoever
    /// planted it could read the password. A fresh item is readable by this app alone.
    func write(_ data: Data, account: String) throws {
        try SecretReplacement.replace(
            data,
            account: account,
            read: { try read(account: $0) },
            delete: { try delete(account: $0) },
            add: { try add($0, account: $1) }
        )
    }

    func delete(account: String) throws {
        let status = SecItemDelete(try pinnedQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func add(_ data: Data, account: String) throws {
        var attributes = identity(account)
        attributes[kSecValueData as String] = data
        attributes[kSecUseKeychain as String] = try pinnedKeychain()
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func identity(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The item's identity, restricted to the login keychain.
    private func pinnedQuery(_ account: String) throws -> [String: Any] {
        var query = identity(account)
        query[kSecMatchSearchList as String] = [try pinnedKeychain()]
        return query
    }

    private func pinnedKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let opened = SecKeychainOpen(keychainPath, &keychain)
        guard opened == errSecSuccess, let keychain else {
            throw KeychainError(status: opened == errSecSuccess ? errSecNoSuchKeychain : opened)
        }
        // Opening a path that holds no keychain succeeds; asking for its status does not.
        var state = SecKeychainStatus()
        let status = SecKeychainGetStatus(keychain, &state)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return keychain
    }
}

/// A form field, identified the way it was when the user granted the site.
struct FieldKey: Codable, Equatable, Sendable {
    /// Empty when the field has none.
    let name: String
    let id: String
    let autocomplete: String
    /// The input's `type` attribute, lowercased.
    let type: String
}

/// One fill the app performed while the user watched it sign in: which value, on exactly which
/// page, into exactly which field.
struct SignInStep: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case username, password, code
    }

    let kind: Kind
    /// `https://host`, with no port.
    let origin: String
    /// `location.pathname` at the time of the fill.
    let path: String
    let field: FieldKey
}

/// What the user granted for one site: the secrets, and everything that decides where they
/// may be used. It lives in the Keychain as one item because a plain file can be edited by
/// anything running as the user, and an edited sign-in address would send the password there.
struct SiteGrant: Codable, Equatable, Sendable {
    enum CodeKind: String, Codable, Sendable {
        case none, authenticator, text, email
    }

    static let maximumHosts = 12
    static let maximumUsernameLength = 256
    static let maximumPasswordLength = 1024
    static let maximumSteps = 6
    static let maximumStepPathLength = 512
    static let maximumFieldKeyLength = 128

    let username: String
    let password: String
    /// The base32 secret or `otpauth` URI the site's authenticator codes come from.
    let authenticatorKey: String?
    let signInURL: URL
    let startURL: URL
    /// Hosts where the password may be filled. Entries match exact hosts only, never as
    /// suffixes: a suffix match on `co.uk` would cover every site under it.
    let fillHosts: [String]
    /// Hosts whose pages may load in the main frame. Entries match exact hosts only, never as
    /// suffixes.
    let browseHosts: [String]
    let codeKind: CodeKind
    /// The handle (phone number, short code, or address) the site's codes come from.
    let codeSender: String?
    /// The fills the app performed while the user watched it sign in, in the order made. The
    /// app signs in by itself only through these, each on the exact page and into the exact
    /// field it was recorded for. An empty list means the app cannot sign in by itself.
    let signInSteps: [SignInStep]
    /// Whether the page the user ended the enrollment on showed a link or button that signs out.
    /// A start page that shows none is then not a signed-in page.
    let signOutControlSeen: Bool

    init(
        username: String,
        password: String,
        authenticatorKey: String?,
        signInURL: URL,
        startURL: URL,
        fillHosts: [String],
        browseHosts: [String],
        codeKind: CodeKind,
        codeSender: String?,
        signInSteps: [SignInStep] = [],
        signOutControlSeen: Bool = false
    ) {
        self.username = username
        self.password = password
        self.authenticatorKey = authenticatorKey
        self.signInURL = signInURL
        self.startURL = startURL
        self.fillHosts = fillHosts
        self.browseHosts = browseHosts
        self.codeKind = codeKind
        self.codeSender = codeSender
        self.signInSteps = signInSteps
        self.signOutControlSeen = signOutControlSeen
    }

    /// A stored grant without the `signInSteps` or `signOutControlSeen` key reads as one with
    /// no steps and no sign-out control seen.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        username = try values.decode(String.self, forKey: .username)
        password = try values.decode(String.self, forKey: .password)
        authenticatorKey = try values.decodeIfPresent(String.self, forKey: .authenticatorKey)
        signInURL = try values.decode(URL.self, forKey: .signInURL)
        startURL = try values.decode(URL.self, forKey: .startURL)
        fillHosts = try values.decode([String].self, forKey: .fillHosts)
        browseHosts = try values.decode([String].self, forKey: .browseHosts)
        codeKind = try values.decode(CodeKind.self, forKey: .codeKind)
        codeSender = try values.decodeIfPresent(String.self, forKey: .codeSender)
        signInSteps = try values.decodeIfPresent([SignInStep].self, forKey: .signInSteps) ?? []
        signOutControlSeen = try values.decodeIfPresent(Bool.self, forKey: .signOutControlSeen) ?? false
    }

    /// Whether this grant may be stored for, and used at, `siteID`.
    ///
    /// The site id is the sign-in host. Both URLs are `https` with no credentials and no
    /// explicit port, and each host is in the browse list; the sign-in host is in the fill
    /// list, which lies within the browse list. Each recorded step names a fill host's origin,
    /// an absolute path, and bounded field attributes, and the steps use each kind once. A
    /// grant that fails any rule is never used.
    func isValid(for siteID: String) -> Bool {
        guard SiteHost.isValid(siteID),
              let signInHost = Self.secureHost(of: signInURL),
              let startHost = Self.secureHost(of: startURL),
              signInHost == siteID,
              Self.isValidList(fillHosts),
              Self.isValidList(browseHosts),
              browseHosts.contains(signInHost),
              browseHosts.contains(startHost),
              fillHosts.contains(signInHost),
              fillHosts.allSatisfy(browseHosts.contains),
              (1...Self.maximumUsernameLength).contains(username.count),
              (1...Self.maximumPasswordLength).contains(password.count),
              areValidSteps
        else { return false }

        if let authenticatorKey, TOTPKey.parse(authenticatorKey) == nil { return false }
        switch codeKind {
        case .none:
            return codeSender == nil
        case .authenticator:
            return authenticatorKey != nil && codeSender == nil
        case .text, .email:
            guard let codeSender else { return false }
            return codeSender.range(
                of: #"\A[A-Za-z0-9+@._-]{2,80}\z"#,
                options: .regularExpression
            ) != nil
        }
    }

    private var areValidSteps: Bool {
        guard signInSteps.count <= Self.maximumSteps,
              Set(signInSteps.map(\.kind)).count == signInSteps.count
        else { return false }
        return signInSteps.allSatisfy { step in
            guard step.origin.hasPrefix("https://"),
                  fillHosts.contains(String(step.origin.dropFirst("https://".count))),
                  step.path.hasPrefix("/"),
                  step.path.count <= Self.maximumStepPathLength,
                  [step.field.name, step.field.id, step.field.autocomplete, step.field.type]
                      .allSatisfy({ $0.count <= Self.maximumFieldKeyLength })
            else { return false }
            return step.kind != .code || codeKind != .none
        }
    }

    private static func isValidList(_ hosts: [String]) -> Bool {
        (1...maximumHosts).contains(hosts.count)
            && Set(hosts).count == hosts.count
            && hosts.allSatisfy(SiteHost.isValid)
    }

    /// The lowercased host of an `https` URL that carries no user, password, or port; else nil.
    private static func secureHost(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let host = url.host(percentEncoded: false)
        else { return nil }
        return host.lowercased()
    }
}

/// Every textual rendering is a fixed placeholder, so a grant interpolated into a log line or
/// a failed assertion shows nothing.
extension SiteGrant: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "SiteGrant(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// Site grants, one Keychain item per site, stored as JSON under the site's id.
struct SiteVault: Sendable {
    static let service = "com.supervisor.SuperVisor.site"
    /// The largest stored item that is read back; a larger one reads as absent.
    static let maximumGrantBytes = 16 << 10

    enum Failure: Error, Equatable {
        /// The id is not a valid site host.
        case invalidSite
        /// The grant does not satisfy `SiteGrant.isValid(for:)` for the id it was saved under.
        case invalidGrant
        /// The grant encodes to more than `maximumGrantBytes`.
        case tooLarge
    }

    let store: any SecretStore

    /// The grant saved for `siteID`. Nil when none is stored, or the stored item is oversized,
    /// not a grant, or not valid for that id.
    func grant(for siteID: String) throws -> SiteGrant? {
        try requireHost(siteID)
        guard let data = try store.read(account: siteID),
              data.count <= Self.maximumGrantBytes,
              let grant = try? JSONDecoder().decode(SiteGrant.self, from: data),
              grant.isValid(for: siteID)
        else { return nil }
        return grant
    }

    func save(_ grant: SiteGrant, for siteID: String) throws {
        guard grant.isValid(for: siteID) else { throw Failure.invalidGrant }
        let data = try JSONEncoder().encode(grant)
        guard data.count <= Self.maximumGrantBytes else { throw Failure.tooLarge }
        try store.write(data, account: siteID)
    }

    func remove(_ siteID: String) throws {
        try requireHost(siteID)
        try store.delete(account: siteID)
    }

    private func requireHost(_ siteID: String) throws {
        guard SiteHost.isValid(siteID) else { throw Failure.invalidSite }
    }
}
