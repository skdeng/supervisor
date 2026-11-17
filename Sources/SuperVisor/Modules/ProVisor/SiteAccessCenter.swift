import AppKit
import Combine
import Foundation
import Synchronization
import WebKit

/// The app's one owner of site access: the granted sites as Settings lists them, the texts
/// setting and whether texts can be read, and the code sources a sign-in draws on.
///
/// Building it does nothing but construct objects; the registry and the Messages database are
/// first read by `refresh()`, which Settings calls when it appears.
@MainActor
final class SiteAccessCenter: ObservableObject {
    static let shared = SiteAccessCenter(
        secretStore: KeychainSecretStore(service: SiteVault.service),
        registryURL: ProVisorHome.sitesURL,
        messages: MessagesStore(),
        settings: .shared,
        dataStore: SiteBrowser.sharedStore
    )

    enum TextsStatus: Equatable {
        case off
        case on
        /// Texts are switched on and cannot be read, which is what a missing Full Disk Access
        /// grant looks like.
        case accessDenied
    }

    /// How a site reads in the settings list.
    enum SiteStatus: Equatable {
        case needsYou
        case signedIn(Date)
        /// Signed in by the person on a site whose grant keeps the session alone.
        case signedInKeepingSession(Date)
        case notSignedInYet

        init(_ record: SiteRecord) {
            if record.needsPerson {
                self = .needsYou
            } else if let date = record.lastSignedIn {
                self = record.keepsSessionOnly ? .signedInKeepingSession(date) : .signedIn(date)
            } else {
                self = .notSignedInYet
            }
        }
    }

    /// How often, and for how long, a sign-in looks for a texted code.
    struct CodePolling: Sendable {
        var interval: Duration = .seconds(2)
        var limit: Duration = .seconds(90)

        static let standard = CodePolling()
    }

    @Published private(set) var sites: [SiteRecord] = []
    /// Follows the setting alone until `refresh()` has tried the Messages database.
    @Published private(set) var textsStatus: TextsStatus

    let access: SiteAccess

    /// Where emailed codes come from. Nil means a sign-in that asks for one gets none.
    var emailedCode: (@Sendable (_ sender: String, _ since: Date) async -> String?)? {
        get { relay.source }
        set { relay.source = newValue }
    }

    private let vault: SiteVault
    private let messages: MessagesStore
    private let settings: SettingsStore
    private let dataStore: WKWebsiteDataStore
    /// The code sources every sign-in this center starts draws on.
    let codes: SignInCodes
    private let relay: EmailedCodeRelay
    private let textsSwitch: TextsSwitch
    private var settingsObservation: AnyCancellable?

    init(
        secretStore: any SecretStore,
        registryURL: URL,
        messages: MessagesStore,
        settings: SettingsStore,
        dataStore: WKWebsiteDataStore,
        codePolling: CodePolling = .standard,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let vault = SiteVault(store: secretStore)
        let relay = EmailedCodeRelay()
        let textsSwitch = TextsSwitch(isOn: settings.provisorReadsTexts)
        let codes = Self.makeCodes(
            messages: messages,
            textsSwitch: textsSwitch,
            relay: relay,
            polling: codePolling,
            now: now
        )
        self.vault = vault
        self.messages = messages
        self.settings = settings
        self.dataStore = dataStore
        self.relay = relay
        self.textsSwitch = textsSwitch
        self.codes = codes
        textsStatus = settings.provisorReadsTexts ? .on : .off
        access = SiteAccess(
            vault: vault,
            registryURL: registryURL,
            codes: codes,
            dataStore: dataStore,
            simulatedPages: simulatedPages,
            settling: settling,
            now: now
        )
        settingsObservation = settings.$provisorReadsTexts.sink { isOn in
            textsSwitch.set(isOn)
        }
    }

    // MARK: Sites

    /// Re-reads the site list and whether texts can be read.
    func refresh() {
        let current = access.sites()
        if current != sites { sites = current }
        let status = Self.textsStatus(enabled: settings.provisorReadsTexts, messages: messages)
        if status != textsStatus { textsStatus = status }
    }

    /// An enrollment for the Add Site window, signing in with this center's code sources.
    func makeEnrollment() -> SiteEnrollment {
        SiteEnrollment(dataStore: dataStore, codes: codes)
    }

    /// The saved grant for a site, for signing in to it again. It holds the password.
    func storedGrant(for siteID: String) -> SiteGrant? {
        try? vault.grant(for: siteID)
    }

    /// Stores the grant and record, replacing any for the site, and marks it signed in by the
    /// person.
    func save(grant: SiteGrant, record: SiteRecord) throws {
        defer { refresh() }
        try access.add(grant: grant, record: record)
    }

    /// Removes the site's sign-in, registry entry, and cookies, and throws when that could not
    /// be done; the list then shows what remains. A removal cut short after the Keychain item
    /// went still lists the site, and removing it again finishes the job.
    func remove(_ siteID: String) async throws {
        defer { refresh() }
        do {
            try await access.remove(siteID: siteID)
        } catch {
            AppLog.error(.sites, "removing site \(siteID) failed: \(error)")
            throw error
        }
    }

    // MARK: Texts

    var textsEnabled: Bool { settings.provisorReadsTexts }

    /// The tools a pass reaches through the bridge, over this center's sites and texts.
    func makeTools() -> ProVisorTools {
        ProVisorTools(
            access: access,
            messages: messages,
            textsAreOn: { [settings] in settings.provisorReadsTexts }
        )
    }

    func setTextsEnabled(_ enabled: Bool) {
        settings.provisorReadsTexts = enabled
        refresh()
    }

    static func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Off when the setting is; otherwise on exactly when the database answers a read. Any
    /// failure reads as denied access, the cause the user can do something about.
    static func textsStatus(enabled: Bool, messages: MessagesStore) -> TextsStatus {
        guard enabled else { return .off }
        do {
            _ = try messages.latestRowID()
            return .on
        } catch {
            return .accessDenied
        }
    }

    // MARK: Codes

    /// The code sources a sign-in draws on. Texts are read only while the setting is on, and
    /// polled only while a sign-in waits for a code.
    nonisolated static func makeCodes(
        messages: MessagesStore,
        textsSwitch: TextsSwitch,
        relay: EmailedCodeRelay,
        polling: CodePolling,
        now: @escaping @Sendable () -> Date
    ) -> SignInCodes {
        SignInCodes(
            authenticator: { key in
                TOTPKey.parse(key)?.code(at: now())
            },
            texted: { sender, afterRowID in
                await poll(polling) {
                    guard textsSwitch.isOn else { return nil }
                    return (try? messages.latestCode(afterRowID: afterRowID, sender: sender))?.code
                }
            },
            emailed: { sender, since in
                guard let source = await relay.current() else { return nil }
                return await source(sender, since)
            },
            messageBaseline: {
                guard textsSwitch.isOn else { return nil }
                return try? messages.latestRowID()
            },
            firstTextedCode: { afterRowID in
                await poll(polling) {
                    guard textsSwitch.isOn,
                          let found = try? messages.firstCode(afterRowID: afterRowID)
                    else { return nil }
                    return (found.code, found.sender)
                }
            }
        )
    }

    /// Reads at once and then every `interval` until `read` answers, `limit` passes, or the
    /// task is cancelled.
    nonisolated static func poll<Value: Sendable>(
        _ polling: CodePolling,
        _ read: @Sendable () -> Value?
    ) async -> Value? {
        let deadline = ContinuousClock.now + polling.limit
        while !Task.isCancelled {
            if let value = read() { return value }
            guard ContinuousClock.now + polling.interval <= deadline else { return nil }
            do {
                try await Task.sleep(for: polling.interval)
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// Whether texts may be read, readable from any thread: the code sources run off the main
/// actor and consult it on every read.
final class TextsSwitch: Sendable {
    private let state: Mutex<Bool>

    init(isOn: Bool) {
        state = Mutex(isOn)
    }

    var isOn: Bool { state.withLock { $0 } }

    func set(_ isOn: Bool) {
        state.withLock { $0 = isOn }
    }
}

/// Holds the emailed-code source, which is set after the code sources are built.
@MainActor
final class EmailedCodeRelay {
    var source: (@Sendable (_ sender: String, _ since: Date) async -> String?)?

    func current() -> (@Sendable (_ sender: String, _ since: Date) async -> String?)? {
        source
    }
}
