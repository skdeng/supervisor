import Foundation
import Security
import Testing

@testable import SuperVisor

/// A secret store that lives in memory, for exercising `SiteVault` without the Keychain.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    var accounts: Set<String> {
        lock.withLock { Set(items.keys) }
    }

    func read(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func write(_ data: Data, account: String) throws {
        lock.withLock { items[account] = data }
    }

    func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

private let samplePassword = "correct horse battery staple"
private let sampleKey = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

/// A valid grant for `example.com` unless a parameter says otherwise.
private func makeGrant(
    username: String = "alice@example.com",
    password: String = samplePassword,
    key: String? = nil,
    signIn: String = "https://example.com/login",
    start: String = "https://www.example.com/home",
    fill: [String] = ["example.com"],
    browse: [String] = ["example.com", "www.example.com"],
    kind: SiteGrant.CodeKind = .none,
    sender: String? = nil
) -> SiteGrant {
    SiteGrant(
        username: username,
        password: password,
        authenticatorKey: key,
        signInURL: URL(string: signIn)!,
        startURL: URL(string: start)!,
        fillHosts: fill,
        browseHosts: browse,
        codeKind: kind,
        codeSender: sender
    )
}

@Suite("Site vault")
struct SiteVaultTests {
    @Test("A saved grant reads back whole")
    func roundTrip() throws {
        let vault = SiteVault(store: InMemorySecretStore())
        let grant = makeGrant(key: sampleKey, kind: .authenticator)

        try vault.save(grant, for: "example.com")

        #expect(try vault.grant(for: "example.com") == grant)
    }

    @Test("A grant with a text sender reads back with it")
    func grantWithSender() throws {
        let vault = SiteVault(store: InMemorySecretStore())
        let grant = makeGrant(kind: .text, sender: "24273")

        try vault.save(grant, for: "example.com")

        #expect(try vault.grant(for: "example.com") == grant)
    }

    @Test("Each site has its own grant")
    func sitesAreSeparate() throws {
        let vault = SiteVault(store: InMemorySecretStore())
        let other = makeGrant(
            username: "second",
            signIn: "https://other.example.org/login",
            start: "https://other.example.org/",
            fill: ["other.example.org"],
            browse: ["other.example.org"]
        )

        try vault.save(makeGrant(username: "first"), for: "example.com")
        try vault.save(other, for: "other.example.org")

        #expect(try vault.grant(for: "example.com")?.username == "first")
        #expect(try vault.grant(for: "other.example.org")?.username == "second")
    }

    @Test("Saving again replaces the grant")
    func overwrite() throws {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)

        try vault.save(makeGrant(username: "old", key: sampleKey), for: "example.com")
        try vault.save(makeGrant(username: "new"), for: "example.com")

        #expect(try vault.grant(for: "example.com") == makeGrant(username: "new"))
        #expect(store.accounts == ["example.com"])
    }

    @Test("A removed grant is gone, and removing one that is absent is fine")
    func remove() throws {
        let vault = SiteVault(store: InMemorySecretStore())
        try vault.save(makeGrant(), for: "example.com")
        try vault.save(
            makeGrant(
                username: "other",
                signIn: "https://other.example.org/login",
                start: "https://other.example.org/",
                fill: ["other.example.org"],
                browse: ["other.example.org"]
            ),
            for: "other.example.org"
        )

        try vault.remove("example.com")
        try vault.remove("example.com")

        #expect(try vault.grant(for: "example.com") == nil)
        #expect(try vault.grant(for: "other.example.org")?.username == "other")
    }

    @Test("A site with nothing saved has no grant")
    func absent() throws {
        #expect(try SiteVault(store: InMemorySecretStore()).grant(for: "example.com") == nil)
    }

    @Test("The grant is stored under the site's id, as JSON that carries its destinations")
    func storedUnderSiteID() throws {
        let store = InMemorySecretStore()
        try SiteVault(store: store).save(makeGrant(), for: "example.com")

        let data = try #require(try store.read(account: "example.com"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["username"] as? String == "alice@example.com")
        #expect(object["password"] as? String == samplePassword)
        #expect(object["signInURL"] as? String == "https://example.com/login")
        #expect(object["fillHosts"] as? [String] == ["example.com"])
        #expect(object["browseHosts"] as? [String] == ["example.com", "www.example.com"])
        #expect(object["codeKind"] as? String == "none")
    }

    @Test(
        "An id that is not a site host is refused",
        arguments: ["", "Example.com", "example", "127.0.0.1", "example.com.", "a b.com", "../x.com"]
    )
    func invalidSiteID(_ siteID: String) {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)

        #expect(throws: SiteVault.Failure.invalidGrant) { try vault.save(makeGrant(), for: siteID) }
        #expect(throws: SiteVault.Failure.invalidSite) { try vault.grant(for: siteID) }
        #expect(throws: SiteVault.Failure.invalidSite) { try vault.remove(siteID) }
        #expect(store.accounts.isEmpty)
    }

    @Test("A grant that is not valid for its id is refused at save and stores nothing")
    func invalidGrantRefused() {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)

        // Valid for example.com, saved under another host.
        #expect(throws: SiteVault.Failure.invalidGrant) {
            try vault.save(makeGrant(), for: "www.example.com")
        }
        #expect(throws: SiteVault.Failure.invalidGrant) {
            try vault.save(makeGrant(signIn: "http://example.com/login"), for: "example.com")
        }
        #expect(throws: SiteVault.Failure.invalidGrant) {
            try vault.save(makeGrant(kind: .authenticator), for: "example.com")
        }
        #expect(store.accounts.isEmpty)
    }

    @Test("A stored item that is not a grant reads as absent")
    func garbageReadsAsAbsent() throws {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)

        for garbage in [
            Data("not json".utf8),
            Data("[]".utf8),
            Data(#"{"username":"a"}"#.utf8),
            Data(#"{"username":1,"password":2}"#.utf8),
            Data([0xFF, 0xFE, 0x00]),
            Data(),
        ] {
            try store.write(garbage, account: "example.com")
            #expect(try vault.grant(for: "example.com") == nil)
        }
    }

    @Test("A stored grant that is not valid for its id reads as absent")
    func tamperedGrantReadsAsAbsent() throws {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)
        try vault.save(makeGrant(), for: "example.com")
        let stored = try #require(try store.read(account: "example.com"))
        func tampered(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var object = try #require(JSONSerialization.jsonObject(with: stored) as? [String: Any])
            change(&object)
            return try JSONSerialization.data(withJSONObject: object)
        }

        // The untouched item reads back.
        #expect(try vault.grant(for: "example.com") != nil)

        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("sign-in address pointed elsewhere", { $0["signInURL"] = "https://evil.example.net/login" }),
            ("fill list pointed elsewhere", { $0["fillHosts"] = ["evil.example.net"] }),
            ("fill list widened past browse", { $0["fillHosts"] = ["example.com", "evil.example.net"] }),
            ("browse list emptied", { $0["browseHosts"] = [String]() }),
            ("explicit port added", { $0["signInURL"] = "https://example.com:8443/login" }),
            ("downgraded to http", { $0["signInURL"] = "http://example.com/login" }),
            ("sender on a kind that has none", { $0["codeSender"] = "24273" }),
        ]
        for (name, edit) in edits {
            try store.write(try tampered(edit), account: "example.com")
            #expect(try vault.grant(for: "example.com") == nil, "\(name)")
        }

        // A grant copied to another account does not match that account's id.
        try store.write(stored, account: "other.example.org")
        #expect(try vault.grant(for: "other.example.org") == nil)
    }

    @Test("A stored item over 16 KiB reads as absent, and one at the limit is read")
    func oversizedReadsAsAbsent() throws {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)
        func grant(padding: Int) -> SiteGrant {
            makeGrant(start: "https://www.example.com/" + String(repeating: "p", count: padding))
        }
        let probe = try JSONEncoder().encode(grant(padding: 0))
        let padding = SiteVault.maximumGrantBytes - probe.count

        let atLimitData = try JSONEncoder().encode(grant(padding: padding))
        #expect(atLimitData.count == 16 << 10)
        try store.write(atLimitData, account: "example.com")
        #expect(try vault.grant(for: "example.com") == grant(padding: padding))

        let over = try JSONEncoder().encode(grant(padding: padding + 1))
        #expect(over.count == (16 << 10) + 1)
        try store.write(over, account: "example.com")
        #expect(try vault.grant(for: "example.com") == nil)
    }

    @Test("A grant too large to read back is refused at save")
    func oversizedSaveRefused() {
        let store = InMemorySecretStore()
        let vault = SiteVault(store: store)
        let huge = makeGrant(start: "https://www.example.com/" + String(repeating: "p", count: 17 << 10))

        #expect(throws: SiteVault.Failure.tooLarge) { try vault.save(huge, for: "example.com") }
        #expect(store.accounts.isEmpty)
    }

    @Test("A grant prints as a fixed placeholder however it is rendered")
    func redaction() {
        let grant = makeGrant(key: sampleKey, kind: .authenticator)
        var dumped = ""
        dump(grant, to: &dumped)
        let renderings = [
            grant.description,
            grant.debugDescription,
            "\(grant)",
            String(describing: grant),
            String(reflecting: grant),
            dumped,
            String(describing: [grant]),
            String(describing: Optional(grant)),
        ]

        for rendering in renderings {
            #expect(rendering.contains("redacted"))
            #expect(!rendering.contains(samplePassword))
            #expect(!rendering.contains("alice"))
            #expect(!rendering.contains(sampleKey))
            #expect(!rendering.contains("example.com"))
        }
    }

    @Test("A Keychain failure names its status and nothing else")
    func keychainErrorDescription() {
        #expect(KeychainError(status: errSecAuthFailed).description == "Keychain error \(errSecAuthFailed)")
    }

    // MARK: Keychain

    private static let keychainService = "com.supervisor.SuperVisor.tests"

    private func loginKeychainPath() -> String {
        KeychainSecretStore.loginKeychainPath
    }

    private func loginKeychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainOpen(loginKeychainPath(), &keychain)
        try #require(status == errSecSuccess)
        return try #require(keychain)
    }

    private func keychainQuery(account: String) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [try loginKeychain()],
        ]
    }

    /// When the item was created. An update in place keeps it; a new item gets its own. The
    /// Keychain stores it to the second.
    private func creationDate(account: String) throws -> Date {
        var query = try keychainQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try #require(status == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        return try #require(attributes[kSecAttrCreationDate as String] as? Date)
    }

    /// The file of the keychain that holds the item, found with a search that is not pinned.
    private func holdingKeychainPath(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        try #require(status == errSecSuccess)
        let reference = try #require(item)
        var keychain: SecKeychain?
        let found = SecKeychainItemCopyKeychain(unsafeDowncast(reference, to: SecKeychainItem.self), &keychain)
        try #require(found == errSecSuccess)
        var length: UInt32 = 4_096
        var buffer = [CChar](repeating: 0, count: Int(length))
        let path = SecKeychainGetPath(keychain, &length, &buffer)
        try #require(path == errSecSuccess)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Adds and removes items in the login keychain, and the first run from a build with a new
    /// signature can raise an access prompt, so it runs only on request:
    /// `SUPERVISOR_KEYCHAIN_TESTS=1 swift test --filter SiteVaultTests`.
    @Test(
        "The Keychain store keeps items in the login keychain, and writing again replaces the item",
        .enabled(if: ProcessInfo.processInfo.environment["SUPERVISOR_KEYCHAIN_TESTS"] == "1")
    )
    func keychainRoundTrip() throws {
        let store = KeychainSecretStore(service: Self.keychainService)
        let account = "roundtrip-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }

        #expect(try store.read(account: account) == nil)

        // A store pointed at a keychain that does not exist fails every operation; none falls
        // back to the default keychain.
        let missing = KeychainSecretStore(
            service: Self.keychainService,
            keychainPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("absent-\(UUID().uuidString).keychain-db").path
        )
        #expect(throws: KeychainError.self) { try missing.read(account: account) }
        #expect(throws: KeychainError.self) { try missing.write(Data("stray".utf8), account: account) }
        #expect(throws: KeychainError.self) { try missing.delete(account: account) }
        #expect(try store.read(account: account) == nil)

        try store.write(Data("first".utf8), account: account)
        #expect(try store.read(account: account) == Data("first".utf8))
        let created = try creationDate(account: account)
        let holder = URL(fileURLWithPath: try holdingKeychainPath(account: account))
        #expect(holder.resolvingSymlinksInPath() == URL(fileURLWithPath: loginKeychainPath()).resolvingSymlinksInPath())

        // Control: an update in place keeps the creation date, so a store that updated would
        // fail the comparison below.
        Thread.sleep(forTimeInterval: 1.1)
        let updated = SecItemUpdate(
            try keychainQuery(account: account) as CFDictionary,
            [kSecValueData as String: Data("updated".utf8)] as CFDictionary
        )
        #expect(updated == errSecSuccess)
        #expect(try store.read(account: account) == Data("updated".utf8))
        #expect(try creationDate(account: account) == created)

        try store.write(Data("second".utf8), account: account)
        #expect(try store.read(account: account) == Data("second".utf8))
        #expect(try creationDate(account: account) > created)

        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        // Deleting what is absent succeeds.
        try store.delete(account: account)
    }
}

@Suite("Site grants")
struct SiteGrantTests {
    private static let key = sampleKey

    @Test("A well-formed grant is valid for its site, whatever its code kind")
    func wellFormed() {
        #expect(makeGrant().isValid(for: "example.com"))
        #expect(makeGrant(key: Self.key).isValid(for: "example.com"))
        #expect(makeGrant(key: Self.key, kind: .authenticator).isValid(for: "example.com"))
        #expect(makeGrant(kind: .text, sender: "24273").isValid(for: "example.com"))
        #expect(makeGrant(kind: .text, sender: "+14155550123").isValid(for: "example.com"))
        #expect(makeGrant(kind: .email, sender: "no-reply@example.com").isValid(for: "example.com"))
    }

    @Test("The site id must be a host, and the sign-in URL's host")
    func siteIDMatchesSignInHost() {
        let grant = makeGrant()

        #expect(!grant.isValid(for: "www.example.com"))
        #expect(!grant.isValid(for: "other.example.org"))
        #expect(!grant.isValid(for: "Example.com"))
        #expect(!grant.isValid(for: ""))
        #expect(!grant.isValid(for: "example"))
        // A sign-in URL written with capitals still names the lowercase host.
        #expect(makeGrant(signIn: "https://EXAMPLE.com/login").isValid(for: "example.com"))
    }

    @Test("Both URLs must be https")
    func urlsMustBeHTTPS() {
        #expect(!makeGrant(signIn: "http://example.com/login").isValid(for: "example.com"))
        #expect(!makeGrant(signIn: "ftp://example.com/login").isValid(for: "example.com"))
        #expect(!makeGrant(start: "http://www.example.com/home").isValid(for: "example.com"))
        #expect(!makeGrant(start: "file:///etc/hosts").isValid(for: "example.com"))
        #expect(makeGrant(signIn: "HTTPS://example.com/login").isValid(for: "example.com"))
    }

    @Test("Neither URL may carry a user or password")
    func urlsMustNotCarryCredentials() {
        for signIn in [
            "https://user@example.com/login",
            "https://user:secret@example.com/login",
            "https://@example.com/login",
        ] {
            #expect(!makeGrant(signIn: signIn).isValid(for: "example.com"), "\(signIn)")
        }
        for start in ["https://user@www.example.com/home", "https://user:secret@www.example.com/home"] {
            #expect(!makeGrant(start: start).isValid(for: "example.com"), "\(start)")
        }
    }

    @Test("Neither URL may carry an explicit port")
    func urlsMustNotCarryPorts() {
        #expect(!makeGrant(signIn: "https://example.com:443/login").isValid(for: "example.com"))
        #expect(!makeGrant(signIn: "https://example.com:8443/login").isValid(for: "example.com"))
        #expect(!makeGrant(start: "https://www.example.com:8443/home").isValid(for: "example.com"))
        #expect(!makeGrant(start: "https://www.example.com:443/home").isValid(for: "example.com"))
    }

    @Test("Each URL's host must be a browse host, and the sign-in host a fill host")
    func urlHostsMustBeListed() {
        #expect(!makeGrant(start: "https://other.example.com/").isValid(for: "example.com"))
        #expect(!makeGrant(fill: ["www.example.com"], browse: ["www.example.com"]).isValid(for: "example.com"))
        #expect(!makeGrant(fill: ["www.example.com"]).isValid(for: "example.com"))
        #expect(makeGrant(start: "https://example.com/home", browse: ["example.com"]).isValid(for: "example.com"))
    }

    @Test("Hosts match exactly, never as a suffix or a prefix")
    func hostsMatchExactly() {
        #expect(!makeGrant(start: "https://www.example.com.evil.net/").isValid(for: "example.com"))
        #expect(!makeGrant(start: "https://notexample.com/").isValid(for: "example.com"))
        #expect(!makeGrant(start: "https://evil.co.uk/", browse: ["example.com", "co.uk"]).isValid(for: "example.com"))
        #expect(
            !makeGrant(
                signIn: "https://shop.co.uk/login",
                start: "https://shop.co.uk/",
                fill: ["co.uk"],
                browse: ["co.uk"]
            ).isValid(for: "shop.co.uk")
        )
        #expect(
            makeGrant(
                signIn: "https://shop.co.uk/login",
                start: "https://shop.co.uk/",
                fill: ["shop.co.uk"],
                browse: ["shop.co.uk"]
            ).isValid(for: "shop.co.uk")
        )
    }

    @Test("Every fill host must also be a browse host")
    func fillHostsAreBrowseHosts() {
        #expect(!makeGrant(fill: ["example.com", "pay.example.com"]).isValid(for: "example.com"))
        #expect(
            makeGrant(
                fill: ["example.com", "pay.example.com"],
                browse: ["example.com", "www.example.com", "pay.example.com"]
            ).isValid(for: "example.com")
        )
    }

    @Test("Host lists hold 1 to 12 valid hosts with no repeats")
    func hostListShape() {
        #expect(!makeGrant(fill: []).isValid(for: "example.com"))
        #expect(!makeGrant(browse: []).isValid(for: "example.com"))
        #expect(!makeGrant(browse: ["example.com", "www.example.com", "EXAMPLE.org"]).isValid(for: "example.com"))
        #expect(!makeGrant(fill: ["example.com", "127.0.0.1"]).isValid(for: "example.com"))
        #expect(!makeGrant(browse: ["example.com", "www.example.com", "www.example.com"]).isValid(for: "example.com"))
        #expect(!makeGrant(fill: ["example.com", "example.com"]).isValid(for: "example.com"))

        let hosts = (0..<13).map { "h\($0).example.com" }
        func browsing(_ count: Int) -> SiteGrant {
            makeGrant(
                signIn: "https://h0.example.com/login",
                start: "https://h1.example.com/home",
                fill: ["h0.example.com"],
                browse: Array(hosts.prefix(count))
            )
        }
        func filling(_ count: Int) -> SiteGrant {
            makeGrant(
                signIn: "https://h0.example.com/login",
                start: "https://h1.example.com/home",
                fill: Array(hosts.prefix(count)),
                browse: Array(hosts.prefix(count))
            )
        }
        #expect(browsing(12).isValid(for: "h0.example.com"))
        #expect(!browsing(13).isValid(for: "h0.example.com"))
        #expect(filling(12).isValid(for: "h0.example.com"))
        #expect(!filling(13).isValid(for: "h0.example.com"))
    }

    @Test("A username holds 1 to 256 characters and a password 1 to 1,024")
    func credentialLengths() {
        #expect(!makeGrant(username: "").isValid(for: "example.com"))
        #expect(makeGrant(username: String(repeating: "u", count: 256)).isValid(for: "example.com"))
        #expect(!makeGrant(username: String(repeating: "u", count: 257)).isValid(for: "example.com"))
        #expect(!makeGrant(password: "").isValid(for: "example.com"))
        #expect(makeGrant(password: String(repeating: "p", count: 1_024)).isValid(for: "example.com"))
        #expect(!makeGrant(password: String(repeating: "p", count: 1_025)).isValid(for: "example.com"))
    }

    @Test("An authenticator key must parse, and a grant of that kind must have one")
    func authenticatorKeyRules() {
        #expect(!makeGrant(key: "not base32!").isValid(for: "example.com"))
        #expect(!makeGrant(key: "GEZDGNBV").isValid(for: "example.com"))
        #expect(!makeGrant(key: "otpauth://hotp/x?secret=\(Self.key)&counter=1").isValid(for: "example.com"))
        #expect(makeGrant(key: "otpauth://totp/x?secret=\(Self.key)&digits=8").isValid(for: "example.com"))
        #expect(!makeGrant(kind: .authenticator).isValid(for: "example.com"))
        #expect(!makeGrant(key: "GEZDGNBV", kind: .authenticator).isValid(for: "example.com"))
    }

    @Test("A code sender is required for text and email, and absent for the other kinds")
    func codeSenderRules() {
        #expect(!makeGrant(kind: .text).isValid(for: "example.com"))
        #expect(!makeGrant(kind: .email).isValid(for: "example.com"))
        #expect(!makeGrant(sender: "24273").isValid(for: "example.com"))
        #expect(!makeGrant(key: Self.key, kind: .authenticator, sender: "24273").isValid(for: "example.com"))
    }

    @Test(
        "A code sender is a phone number, short code, or address of 2 to 80 safe characters",
        arguments: ["24273", "+14155550123", "no-reply@example.com", "a.b_c-d+e@x.co", "ab", String(repeating: "s", count: 80)]
    )
    func validSenders(_ sender: String) {
        #expect(makeGrant(kind: .text, sender: sender).isValid(for: "example.com"))
        #expect(makeGrant(kind: .email, sender: sender).isValid(for: "example.com"))
    }

    @Test(
        "Any other sender is refused",
        arguments: [
            "",
            "x",
            String(repeating: "s", count: 81),
            "a b",
            "24273\n",
            "\n24273",
            "24273 ",
            "<script>",
            "évil@example.com",
            "a;b",
            "a/b",
            "24273\u{0000}",
        ]
    )
    func invalidSenders(_ sender: String) {
        #expect(!makeGrant(kind: .text, sender: sender).isValid(for: "example.com"))
        #expect(!makeGrant(kind: .email, sender: sender).isValid(for: "example.com"))
    }
}

@Suite("Secret replacement")
struct SecretReplacementTests {
    private struct Failure: Error, Equatable {
        let name: String
    }

    /// A store of accounts whose primitives record what was done and fail on request.
    private final class Fake {
        var items: [String: Data]
        var log: [String] = []
        var readError: Failure?
        var deleteError: Failure?
        /// The errors the successive adds fail with; an add past the end succeeds.
        var addErrors: [Failure?] = []
        private var adds = 0

        init(items: [String: Data] = [:]) {
            self.items = items
        }

        func replace(_ data: Data, account: String) throws {
            try SecretReplacement.replace(
                data,
                account: account,
                read: { account in
                    self.log.append("read")
                    if let error = self.readError { throw error }
                    return self.items[account]
                },
                delete: { account in
                    self.log.append("delete")
                    if let error = self.deleteError { throw error }
                    self.items[account] = nil
                },
                add: { data, account in
                    self.log.append("add")
                    defer { self.adds += 1 }
                    if self.adds < self.addErrors.count, let error = self.addErrors[self.adds] { throw error }
                    self.items[account] = data
                }
            )
        }
    }

    @Test("An item is replaced by deleting it and adding the new one")
    func replaces() throws {
        let fake = Fake(items: ["a": Data("old".utf8)])

        try fake.replace(Data("new".utf8), account: "a")

        #expect(fake.items == ["a": Data("new".utf8)])
        #expect(fake.log == ["read", "delete", "add"])
    }

    @Test("A first write adds the item")
    func firstWrite() throws {
        let fake = Fake()

        try fake.replace(Data("new".utf8), account: "a")

        #expect(fake.items == ["a": Data("new".utf8)])
    }

    @Test("When the add fails the earlier item is put back and the failure is thrown")
    func failedAddRestores() {
        let fake = Fake(items: ["a": Data("old".utf8), "b": Data("other".utf8)])
        fake.addErrors = [Failure(name: "add")]

        #expect(throws: Failure(name: "add")) {
            try fake.replace(Data("new".utf8), account: "a")
        }

        #expect(fake.items == ["a": Data("old".utf8), "b": Data("other".utf8)])
        #expect(fake.log == ["read", "delete", "add", "add"])
    }

    @Test("When the add fails and nothing was stored, nothing is restored")
    func failedAddWithNothingToRestore() {
        let fake = Fake()
        fake.addErrors = [Failure(name: "add")]

        #expect(throws: Failure(name: "add")) {
            try fake.replace(Data("new".utf8), account: "a")
        }

        #expect(fake.items.isEmpty)
        #expect(fake.log == ["read", "delete", "add"])
    }

    @Test("When the restore also fails the original failure is the one thrown")
    func failedRestore() {
        let fake = Fake(items: ["a": Data("old".utf8)])
        fake.addErrors = [Failure(name: "add"), Failure(name: "restore")]

        #expect(throws: Failure(name: "add")) {
            try fake.replace(Data("new".utf8), account: "a")
        }

        #expect(fake.log == ["read", "delete", "add", "add"])
    }

    @Test("When the earlier item cannot be read, nothing is deleted")
    func failedRead() {
        let fake = Fake(items: ["a": Data("old".utf8)])
        fake.readError = Failure(name: "read")

        #expect(throws: Failure(name: "read")) {
            try fake.replace(Data("new".utf8), account: "a")
        }

        #expect(fake.items == ["a": Data("old".utf8)])
        #expect(fake.log == ["read"])
    }

    @Test("When the delete fails, nothing is added and the earlier item stays")
    func failedDelete() {
        let fake = Fake(items: ["a": Data("old".utf8)])
        fake.deleteError = Failure(name: "delete")

        #expect(throws: Failure(name: "delete")) {
            try fake.replace(Data("new".utf8), account: "a")
        }

        #expect(fake.items == ["a": Data("old".utf8)])
        #expect(fake.log == ["read", "delete"])
    }
}
