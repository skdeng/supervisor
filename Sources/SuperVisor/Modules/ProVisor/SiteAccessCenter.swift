import AppKit
import Combine
import Foundation
import Synchronization
import WebKit

/// The app's one owner of what a pass reads through the bridge: the granted sites as Settings
/// lists them, the texts and photo-places settings and whether each can be read, and the code
/// sources a sign-in draws on.
///
/// Building it does nothing but construct objects; the registry, the Messages database, and the
/// Photos permission are first read by `refresh()`, which Settings calls when it appears.
@MainActor
final class SiteAccessCenter: ObservableObject {
    static let shared = SiteAccessCenter(
        secretStore: KeychainSecretStore(service: SiteVault.service),
        registryURL: ProVisorHome.sitesURL,
        messages: MessagesStore(),
        photoPlaces: .library,
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

    enum PhotoPlacesStatus: Equatable {
        case off
        case on
        /// Switched on, and the user has not yet been asked to let the app read Photos.
        case accessNotAsked
        /// Switched on, and the user or a device policy refused the app access to Photos.
        case accessDenied
    }

    /// How a site reads in the settings list.
    enum SiteStatus: Equatable {
        case needsYou
        case signedIn(Date)
        /// Signed in by the person on a site whose grant keeps the session alone.
        case signedInKeepingSession(Date)
        case notSignedInYet

        /// A site reads as needing the person when its record says so or a run was turned away
        /// from it since they last signed in (`awaiting`).
        init(_ record: SiteRecord, awaiting: Set<String>) {
            if record.needsPerson || awaiting.contains(record.id) {
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
    /// The ids of the sites a run was turned away from for want of the person's sign-in since
    /// they last signed in to it. Held in memory only, so a relaunch starts with none; a site
    /// flagged in the registry stays flagged (`SiteRecord.needsPerson`).
    @Published private(set) var awaitingSignIn: Set<String> = []
    /// Follows the setting alone until `refresh()` has tried the Messages database.
    @Published private(set) var textsStatus: TextsStatus
    /// Follows the setting alone until `refresh()` has read the Photos permission.
    @Published private(set) var photoPlacesStatus: PhotoPlacesStatus

    let access: SiteAccess

    /// Called after each save, and after each sign-in by the person recorded with the stored
    /// grant kept (`personSignedIn`), once the list is refreshed, with the record and whether
    /// the site was waiting on the person: flagged as needing them, or turned away from a run
    /// since they last signed in.
    var onSiteSaved: (@MainActor (_ record: SiteRecord, _ wasAwaited: Bool) -> Void)?

    /// Called with the site's id each time a run is turned away from it for want of the
    /// person's sign-in, once `awaitingSignIn` and `sites` say so.
    var onPersonNeeded: (@MainActor (_ siteID: String) -> Void)?

    /// Where emailed codes come from. Nil means a sign-in that asks for one gets none.
    var emailedCode: (@Sendable (_ sender: String, _ since: Date) async -> String?)? {
        get { relay.source }
        set { relay.source = newValue }
    }

    private let vault: SiteVault
    private let messages: MessagesStore
    private let photoPlaces: PhotoPlaces
    private let settings: SettingsStore
    private let dataStore: WKWebsiteDataStore
    /// The code sources every sign-in this center starts draws on.
    let codes: SignInCodes
    private let relay: EmailedCodeRelay
    private let textsSwitch: TextsSwitch
    private var settingsObservation: AnyCancellable?
    /// The request for access to Photos under way. A request made while one is pending is
    /// dropped.
    private(set) var photoAccessRequest: Task<Void, Never>?

    init(
        secretStore: any SecretStore,
        registryURL: URL,
        messages: MessagesStore,
        photoPlaces: PhotoPlaces,
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
        self.photoPlaces = photoPlaces
        self.settings = settings
        self.dataStore = dataStore
        self.relay = relay
        self.textsSwitch = textsSwitch
        self.codes = codes
        textsStatus = settings.provisorReadsTexts ? .on : .off
        photoPlacesStatus = settings.provisorReadsPhotoPlaces ? .on : .off
        access = SiteAccess(
            vault: vault,
            registryURL: registryURL,
            codes: codes,
            dataStore: dataStore,
            simulatedPages: simulatedPages,
            settling: settling,
            now: now
        )
        access.onPersonNeeded = { [weak self] siteID in
            self?.personNeeded(siteID)
        }
        // A site whose start page a run could read is not waiting on the person.
        access.onOpened = { [weak self] siteID in
            self?.forgetAwaiting(siteID)
        }
        settingsObservation = settings.$provisorReadsTexts.sink { isOn in
            textsSwitch.set(isOn)
        }
    }

    // MARK: Sites

    /// Re-reads the site list and whether texts and photo places can be read.
    func refresh() {
        let current = access.sites()
        if current != sites { sites = current }
        let status = Self.textsStatus(enabled: settings.provisorReadsTexts, messages: messages)
        if status != textsStatus { textsStatus = status }
        let places = Self.photoPlacesStatus(
            enabled: settings.provisorReadsPhotoPlaces,
            access: photoPlaces.access
        )
        if places != photoPlacesStatus { photoPlacesStatus = places }
    }

    /// An enrollment for the site window, signing in with this center's code sources. It
    /// records nothing the person types.
    func makeEnrollment() -> SiteEnrollment {
        SiteEnrollment(dataStore: dataStore, codes: codes)
    }

    /// An enrollment for the sign-in window that records the user name and password the person
    /// types, so that a sign-in can be offered a password (`SiteEnrollment.recordingCredentials`).
    func makeRecordingEnrollment() -> SiteEnrollment {
        SiteEnrollment.recordingCredentials(dataStore: dataStore, codes: codes)
    }

    /// An enrollment for the sign-in window that records nothing the person types and probes
    /// the page of any sign-in (`SiteEnrollment.watchingSignIn`).
    func makeWatchingEnrollment() -> SiteEnrollment {
        SiteEnrollment.watchingSignIn(dataStore: dataStore, codes: codes)
    }

    /// Whether the sign-in window may offer to keep a password the person typed.
    var offersPasswords: Bool { settings.provisorOffersPasswords }

    /// The saved grant for a site, for signing in to it again. It holds the password.
    func storedGrant(for siteID: String) -> SiteGrant? {
        try? vault.grant(for: siteID)
    }

    /// Stores the grant and record, replacing any for the site, and marks it signed in by the
    /// person. The site stops awaiting them; `onSiteSaved` hears of the save and of whether it
    /// was awaited.
    func save(grant: SiteGrant, record: SiteRecord) throws {
        let wasAwaited = isAwaited(record.id)
        do {
            try access.add(grant: grant, record: record)
        } catch {
            refresh()
            throw error
        }
        forgetAwaiting(record.id)
        refresh()
        onSiteSaved?(record, wasAwaited)
    }

    /// Records that the person signed in to the site themselves while its stored grant stays as
    /// it is (`SiteAccess.personSignedIn`), and returns the record, or nil when the sign-in
    /// could not be confirmed or recorded. `storedPasswordWorked` says the app's own fill of
    /// the saved password was accepted. The site stops awaiting the person, and `onSiteSaved`
    /// hears of it as of a save.
    func personSignedIn(siteID: String, storedPasswordWorked: Bool) async -> SiteRecord? {
        let wasAwaited = isAwaited(siteID)
        guard let record = await access.personSignedIn(siteID: siteID, storedPasswordWorked: storedPasswordWorked) else {
            refresh()
            return nil
        }
        forgetAwaiting(siteID)
        refresh()
        onSiteSaved?(record, wasAwaited)
        return record
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
        forgetAwaiting(siteID)
    }

    /// Whether the site is flagged as needing the person, or a run was turned away from it since
    /// they last signed in. Reads the registry, so a flag written a moment ago counts.
    private func isAwaited(_ siteID: String) -> Bool {
        awaitingSignIn.contains(siteID)
            || access.sites().contains { $0.id == siteID && $0.needsPerson }
    }

    /// A `@Published` value publishes on every write, so a set that would not change is left
    /// alone.
    private func personNeeded(_ siteID: String) {
        if !awaitingSignIn.contains(siteID) {
            awaitingSignIn.insert(siteID)
        }
        refresh()
        onPersonNeeded?(siteID)
    }

    private func forgetAwaiting(_ siteID: String) {
        if awaitingSignIn.contains(siteID) {
            awaitingSignIn.remove(siteID)
        }
    }

    // MARK: Texts

    var textsEnabled: Bool { settings.provisorReadsTexts }

    /// The tools a pass reaches through the bridge, over this center's sites, texts, and photo
    /// places.
    func makeTools() -> ProVisorTools {
        ProVisorTools(
            access: access,
            messages: messages,
            textsAreOn: { [settings] in settings.provisorReadsTexts },
            photoPlaces: photoPlaces,
            photoPlacesAreOn: { [settings] in settings.provisorReadsPhotoPlaces },
            awaiting: { [weak self] in self?.awaitingSignIn ?? [] }
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

    // MARK: Photo places

    var photoPlacesEnabled: Bool { settings.provisorReadsPhotoPlaces }

    /// Turning the setting on asks the user to let the app read Photos when they have not been
    /// asked; the system shows that prompt once.
    func setPhotoPlacesEnabled(_ enabled: Bool) {
        settings.provisorReadsPhotoPlaces = enabled
        refresh()
        if photoPlacesStatus == .accessNotAsked {
            requestPhotoAccess()
        }
    }

    /// Asks the user to let the app read Photos, then reads the status again.
    func requestPhotoAccess() {
        guard photoAccessRequest == nil else { return }
        let places = photoPlaces
        photoAccessRequest = Task { [weak self] in
            _ = await places.requestAccess()
            self?.photoAccessRequest = nil
            self?.refresh()
        }
    }

    static func openPhotosAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Off when the setting is, and the permission is then left unread.
    static func photoPlacesStatus(
        enabled: Bool,
        access: () -> PhotoPlaces.Access
    ) -> PhotoPlacesStatus {
        guard enabled else { return .off }
        switch access() {
        case .allowed: return .on
        case .notAsked: return .accessNotAsked
        case .denied: return .accessDenied
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
