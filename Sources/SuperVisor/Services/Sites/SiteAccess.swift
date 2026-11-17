import Foundation
import WebKit

/// What the agent's site tools call: granted sites, and the pages a run reads on them.
///
/// A visit is one run's use of a site. It owns a `SiteBrowser` held to that site's browse
/// hosts, the page it last read, and a count of the links it followed. A visit opens a site's
/// start page and follows links that appeared on a page it read; it cannot type, click, or name
/// an address. Signing in is the app's own work, done here before the first page is returned,
/// on the pages recorded when the user granted the site and never on a page reached by a link.
///
/// This class is the single owner of the registry file: every read-modify-write goes through
/// it, on the main actor with no suspension in between.
@MainActor
final class SiteAccess {
    enum Failure: Error, Equatable {
        case unknownSite
        /// The session ended and the app may not, or could not, sign in again by itself.
        case needsPerson
        case tooManyLinks
        case noSuchLink
        case nothingOpen
        /// The site could not be reached or read, or the sign-in was cut short or failed in a
        /// way that may not repeat.
        case unavailable
    }

    /// How many links a visit may follow.
    static let linksPerVisit = 12
    /// How many visits may be open at once.
    static let maximumVisits = 8
    private static let maximumVisitIDLength = 128

    private final class Visit {
        let gate = SerialGate()
        var siteID: String?
        var browser: SiteBrowser?
        var page: PageSnapshot?
        var followed = 0
    }

    /// What the vault and registry say about a site id.
    private enum Lookup {
        case found(grant: SiteGrant, record: SiteRecord)
        case unknown
        /// The vault could not be read.
        case unreadable
    }

    private let vault: SiteVault
    private let registryURL: URL
    private let codes: SignInCodes
    private let dataStore: WKWebsiteDataStore
    private let simulatedPages: SiteBrowser.SimulatedPages?
    private let settling: SiteBrowser.Settling
    private let codeWaitLimit: Duration
    private let now: () -> Date
    private var visits: [String: Visit] = [:]
    private var signInGates: [String: SerialGate] = [:]
    /// How many sign-ins have finished for a site. A visit that began before one finished looks
    /// at the session again before trying for itself.
    private var signInsFinished: [String: Int] = [:]
    /// How many times a site's grant and record have been replaced or removed. A sign-in that
    /// began under an earlier one writes nothing about itself.
    private var recordEpochs: [String: Int] = [:]

    init(
        vault: SiteVault,
        registryURL: URL,
        codes: SignInCodes,
        dataStore: WKWebsiteDataStore = SiteBrowser.sharedStore,
        simulatedPages: SiteBrowser.SimulatedPages? = nil,
        settling: SiteBrowser.Settling = .standard,
        codeWaitLimit: Duration = SignInBroker.standardCodeWaitLimit,
        now: @escaping () -> Date = Date.init
    ) {
        self.vault = vault
        self.registryURL = registryURL
        self.codes = codes
        self.dataStore = dataStore
        self.simulatedPages = simulatedPages
        self.settling = settling
        self.codeWaitLimit = codeWaitLimit
        self.now = now
    }

    // MARK: Sites

    func sites() -> [SiteRecord] {
        SiteRegistry.load(from: registryURL)
    }

    /// Stores the grant in the vault and the record in the registry, replacing any earlier
    /// ones for the site. A person has just signed in, so attempts start over, and a sign-in
    /// under way for the site is cut off. The record's `keepsSessionOnly` is taken from the
    /// grant.
    func add(grant: SiteGrant, record: SiteRecord) throws {
        guard record.isValid, grant.isValid(for: record.id) else {
            throw SiteVault.Failure.invalidGrant
        }
        var stored = SignInAttempts.recordingPersonSignedIn(record, now: now())
        stored.keepsSessionOnly = !grant.remembersPassword
        let earlier = try? vault.grant(for: record.id)
        try vault.save(grant, for: record.id)
        let others = sites().filter { $0.id != record.id }
        do {
            try SiteRegistry.save(others + [stored], to: registryURL)
        } catch {
            if let earlier {
                try? vault.save(earlier, for: record.id)
            } else {
                try? vault.remove(record.id)
            }
            throw error
        }
        recordEpochs[record.id, default: 0] += 1
        closeVisits(of: record.id)
    }

    /// Removes the site's Keychain item and registry entry, then the cookies and site data its
    /// browse hosts left in the browser's data store, except what a site that remains also
    /// has a stake in.
    func remove(siteID: String) async throws {
        let hosts = (try vault.grant(for: siteID))?.browseHosts ?? [siteID]
        let remaining = sites().filter { $0.id != siteID }
        let keptHosts = remaining.flatMap { record in
            (try? vault.grant(for: record.id))?.browseHosts ?? [record.id]
        }
        try vault.remove(siteID)
        try SiteRegistry.save(remaining, to: registryURL)
        recordEpochs[siteID, default: 0] += 1
        closeVisits(of: siteID)
        await clearWebData(of: hosts, keeping: keptHosts)
        AppLog.notice(.sites, "removed site \(siteID)")
    }

    // MARK: Visits

    /// Opens a granted site's start page for a visit, signing in first when the session has
    /// ended. A visit that has another site open closes it. A site that is not granted gets no
    /// visit.
    ///
    /// A grant that remembers no password is never signed in to here: once its session has
    /// ended the site needs the person, and no attempt is counted.
    func open(siteID: String, visit visitID: String) async -> Result<PageSnapshot, Failure> {
        guard !visitID.isEmpty, visitID.count <= Self.maximumVisitIDLength else {
            return .failure(.unavailable)
        }
        let visit: Visit
        if let existing = visits[visitID] {
            visit = existing
        } else {
            switch lookup(siteID) {
            case .unknown: return .failure(.unknownSite)
            case .unreadable: return .failure(.unavailable)
            case .found: break
            }
            guard visits.count < Self.maximumVisits else { return .failure(.unavailable) }
            visit = Visit()
            visits[visitID] = visit
        }
        return await visit.gate.perform { await openLocked(siteID: siteID, visit: visit) }
    }

    /// Follows link number `index` (counted from 1) of the page the visit last read, by loading
    /// its address. Nothing on the page is clicked.
    func follow(link index: Int, visit visitID: String) async -> Result<PageSnapshot, Failure> {
        guard let visit = visits[visitID], visit.page != nil else { return .failure(.nothingOpen) }
        return await visit.gate.perform {
            guard let page = visit.page, let browser = visit.browser else {
                return .failure(.nothingOpen)
            }
            guard visit.followed < Self.linksPerVisit else { return .failure(.tooManyLinks) }
            guard index >= 1, page.links.indices.contains(index - 1) else {
                return .failure(.noSuchLink)
            }
            visit.followed += 1
            do {
                let next = try await browser.open(page.links[index - 1].url)
                visit.page = next
                return .success(next)
            } catch {
                return .failure(Self.failure(for: error, refused: .noSuchLink))
            }
        }
    }

    /// The page the visit last read.
    func currentPage(visit visitID: String) -> PageSnapshot? {
        visits[visitID]?.page
    }

    /// The id of the site the visit last opened; nil for a visit that has opened none or whose
    /// site was replaced or removed.
    func siteID(visit visitID: String) -> String? {
        visits[visitID]?.siteID
    }

    /// Releases the visit's browser, which ends a sign-in the visit has under way.
    func end(visit visitID: String) {
        visits.removeValue(forKey: visitID)?.browser?.close()
    }

    // MARK: Opening

    private func lookup(_ siteID: String) -> Lookup {
        let grant: SiteGrant?
        do {
            grant = try vault.grant(for: siteID)
        } catch SiteVault.Failure.invalidSite {
            return .unknown
        } catch {
            AppLog.error(.sites, "the vault could not be read for \(siteID)")
            return .unreadable
        }
        guard let grant, let record = record(siteID) else { return .unknown }
        return .found(grant: grant, record: record)
    }

    private func openLocked(siteID: String, visit: Visit) async -> Result<PageSnapshot, Failure> {
        // The links of an earlier page are not links of whatever this call ends with.
        visit.page = nil
        let grant: SiteGrant
        let site: SiteRecord
        switch lookup(siteID) {
        case let .found(found, record): (grant, site) = (found, record)
        case .unknown: return .failure(.unknownSite)
        case .unreadable: return .failure(.unavailable)
        }
        if site.needsPerson { return .failure(.needsPerson) }

        let epoch = recordEpochs[siteID, default: 0]
        let finishedAtStart = signInsFinished[siteID, default: 0]
        if visit.siteID != siteID {
            visit.browser?.close()
            visit.browser = nil
            visit.siteID = siteID
        }
        let browser = visit.browser ?? SiteBrowser(
            policy: Self.policy(for: grant),
            dataStore: dataStore,
            simulatedPages: simulatedPages,
            settling: settling
        )
        visit.browser = browser
        browser.policy = Self.policy(for: grant)
        let broker = SignInBroker(browser: browser, codeWaitLimit: codeWaitLimit, now: now)

        do {
            _ = try await browser.open(grant.startURL)
            if try await broker.isSignedIn(grant) {
                return .success(try await remember(browser.snapshot(), in: visit))
            }
        } catch {
            return .failure(Self.failure(for: error, refused: .needsPerson))
        }

        guard grant.remembersPassword else {
            markNeedsPerson(siteID: siteID, epoch: epoch)
            return .failure(.needsPerson)
        }
        if case let .failure(failure) = await signIn(
            siteID: siteID,
            grant: grant,
            browser: browser,
            broker: broker,
            finishedAtStart: finishedAtStart
        ) {
            return .failure(failure)
        }
        do {
            return .success(try await remember(browser.snapshot(), in: visit))
        } catch {
            return .failure(Self.failure(for: error, refused: .needsPerson))
        }
    }

    private func remember(_ page: PageSnapshot, in visit: Visit) -> PageSnapshot {
        visit.page = page
        return page
    }

    /// Signs in once for the site, however many visits ask at the same time. A visit that began
    /// before another sign-in finished looks at the session again before trying for itself,
    /// since that sign-in may have restored it.
    ///
    /// The attempt is counted in the registry before the sign-in starts, so a sign-in that
    /// cannot be recorded is not made, and the outcome is written when it ends. An attempt cut
    /// short is taken back.
    private func signIn(
        siteID: String,
        grant: SiteGrant,
        browser: SiteBrowser,
        broker: SignInBroker,
        finishedAtStart: Int
    ) async -> Result<Void, Failure> {
        guard mayAttempt(siteID) else { return .failure(.needsPerson) }
        let gate = signInGates[siteID] ?? SerialGate()
        signInGates[siteID] = gate
        return await gate.perform {
            if signInsFinished[siteID, default: 0] != finishedAtStart {
                do {
                    _ = try await browser.open(grant.startURL)
                    if try await broker.isSignedIn(grant) { return .success(()) }
                } catch {
                    return .failure(Self.failure(for: error, refused: .needsPerson))
                }
            }
            guard let before = record(siteID),
                  SignInAttempts.mayAttempt(before, now: now(), timeZone: .current)
            else { return .failure(.needsPerson) }

            let epoch = recordEpochs[siteID, default: 0]
            let counted = SignInAttempts.beginning(attemptOn: before, now: now(), timeZone: .current)
            guard store(counted) else {
                AppLog.error(.sites, "the attempt for \(siteID) could not be recorded, so no sign-in was made")
                return .failure(.unavailable)
            }

            let outcome = await broker.signIn(with: grant, codes: codes)
            signInsFinished[siteID, default: 0] += 1
            settleAttempt(siteID: siteID, epoch: epoch, before: before, outcome: outcome)

            switch outcome {
            case .signedIn:
                AppLog.notice(.sites, "sign-in for \(siteID): signed in")
                return .success(())
            case .interrupted:
                AppLog.notice(.sites, "sign-in for \(siteID): interrupted")
                return .failure(.unavailable)
            case let .needsPerson(reason):
                AppLog.notice(.sites, "sign-in for \(siteID): stopped, \(reason.rawValue)")
                return outcome.attemptOutcome == .needsPerson ? .failure(.needsPerson) : .failure(.unavailable)
            }
        }
    }

    /// Writes how an attempt ended, unless the site's grant and record were replaced or removed
    /// while it ran, in which case the new ones are left as they are.
    private func settleAttempt(siteID: String, epoch: Int, before: SiteRecord, outcome: SignInOutcome) {
        guard recordEpochs[siteID, default: 0] == epoch, let current = record(siteID) else { return }
        let updated: SiteRecord
        if let attemptOutcome = outcome.attemptOutcome {
            updated = SignInAttempts.settling(current, outcome: attemptOutcome, now: now())
        } else {
            updated = SignInAttempts.abandoning(current, restoring: before)
        }
        if !store(updated) {
            AppLog.error(.sites, "the outcome of an attempt for \(siteID) could not be recorded")
        }
    }

    /// Flags the site as needing the person, unless its grant and record were replaced or
    /// removed since `epoch`.
    private func markNeedsPerson(siteID: String, epoch: Int) {
        guard recordEpochs[siteID, default: 0] == epoch, var current = record(siteID) else { return }
        current.needsPerson = true
        if store(current) {
            AppLog.notice(.sites, "session for \(siteID) ended; it needs the person")
        } else {
            AppLog.error(.sites, "the ended session for \(siteID) could not be recorded")
        }
    }

    private func mayAttempt(_ siteID: String) -> Bool {
        guard let record = record(siteID) else { return false }
        return SignInAttempts.mayAttempt(record, now: now(), timeZone: .current)
    }

    private func record(_ siteID: String) -> SiteRecord? {
        sites().first { $0.id == siteID }
    }

    /// Replaces the site's record, which must exist, and says whether the registry was written.
    /// Nothing suspends between the read and the write.
    private func store(_ record: SiteRecord) -> Bool {
        let records = sites()
        guard records.contains(where: { $0.id == record.id }) else { return false }
        do {
            try SiteRegistry.save(records.map { $0.id == record.id ? record : $0 }, to: registryURL)
            return true
        } catch {
            return false
        }
    }

    private static func policy(for grant: SiteGrant) -> SiteNavigationPolicy {
        SiteNavigationPolicy(browseHosts: Set(grant.browseHosts))
    }

    /// Maps a browser failure to the visit's: an address or page off the site's hosts is
    /// `refused`, anything else is a site that cannot be reached.
    private static func failure(for error: any Error, refused: Failure) -> Failure {
        switch error as? SiteBrowser.Failure {
        case .leftSite?, .notAllowed?: refused
        default: .unavailable
        }
    }

    private func closeVisits(of siteID: String) {
        for visit in visits.values where visit.siteID == siteID {
            visit.browser?.close()
            visit.browser = nil
            visit.page = nil
            visit.siteID = nil
        }
    }

    // MARK: Web data

    /// Removes the cookies and site data whose domain is one of `hosts` or a parent of one,
    /// leaving any that is also a parent of one of `keptHosts`. Data is kept per registrable
    /// domain, so a site that shares the domain keeps its data and its session.
    private func clearWebData(of hosts: [String], keeping keptHosts: [String]) async {
        func parent(of domain: String, in list: [String]) -> Bool {
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            guard bare.contains(".") else { return false }
            return list.contains { $0 == bare || $0.hasSuffix("." + bare) }
        }
        func shouldClear(_ domain: String) -> Bool {
            parent(of: domain, in: hosts) && !parent(of: domain, in: keptHosts)
        }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        await dataStore.removeData(ofTypes: types, for: records.filter { shouldClear($0.displayName) })
        let cookieStore = dataStore.httpCookieStore
        for cookie in await cookieStore.allCookies() where shouldClear(cookie.domain) {
            await cookieStore.deleteCookie(cookie)
        }
    }
}
