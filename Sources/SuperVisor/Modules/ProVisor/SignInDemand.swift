import Foundation

/// The sites the person is being asked to sign in to, derived from what ProVisor knows: the
/// granted sites that need them, and the sites its proposals ask for. It reads no file and
/// starts nothing.
enum SignInDemand {
    /// One site and why it is wanted.
    struct Item: Equatable, Identifiable {
        enum Kind: Equatable {
            /// A site a proposal asks for that is not granted. `recognised` says whether the
            /// host is one the person's own browsers have visited.
            case requested(recognised: Bool)
            /// A granted site that needs the person: its session ended, or a run was turned
            /// away from it. `keepsSession` says the grant holds a session and no password.
            case signedOut(keepsSession: Bool)
        }

        /// The site's host, which is also its id as a granted site.
        let host: String
        let displayName: String
        let kind: Kind
        /// The earliest open proposal that asks for this host.
        let proposalID: String?
        /// The granted site's record is flagged as needing the person (`SiteRecord.needsPerson`);
        /// false for a site a run was only turned away from, and for a requested host.
        var needsPerson = false

        var id: String { host }

        /// Whether the app may put this site in front of the person as a sign-in, on the banner
        /// or as a sheet row: a granted site, named as the person named it, or a requested host
        /// the person's own browsers have visited. A host the agent names that they never
        /// visited stays an ordinary proposal, whose review window opens its page with a
        /// caution: the agent reads mail from anyone, and a look-alike host shown as a sign-in
        /// prompt would carry the app's authority.
        var isAnnounceable: Bool {
            switch kind {
            case .signedOut, .requested(recognised: true):
                return true
            case .requested(recognised: false):
                return false
            }
        }
    }

    /// The items to offer as sign-ins: the announceable ones, less the granted sites the person
    /// put off (`SignInPostponements`). A requested host cannot be put off; its proposal's
    /// Dismiss declines it.
    static func prompts(in items: [Item], postponed: Set<String>) -> [Item] {
        items.filter { item in
            guard item.isAnnounceable else { return false }
            if case .signedOut = item.kind { return !postponed.contains(item.host) }
            return true
        }
    }

    /// The proposals a sign-in prompt stands for: their request is answered by signing in, so
    /// they are neither shown as a separate row nor counted as new ideas.
    static func coveredProposalIDs(_ prompts: [Item]) -> Set<String> {
        Set(prompts.compactMap(\.proposalID))
    }

    /// One item per site in demand: a granted site that is flagged as needing the person or that
    /// a run was turned away from (`awaiting`), and any other host an open request names.
    /// Granted sites come first, ordered by name and then host, then the requested hosts,
    /// ordered by when they were asked for and then by host.
    ///
    /// An open request for a granted host joins that site's item and gives it the proposal's
    /// id; a granted site that is neither flagged nor awaited is not in demand, whatever asks
    /// for it. `recognised` answers whether the person's browsers know a host that is not
    /// granted, and nil while that is not yet known: a requested host is left out until it is.
    static func items(
        proposals: [Proposal],
        sites: [SiteRecord],
        awaiting: Set<String>,
        now: Date,
        recognised: (String) -> Bool?
    ) -> [Item] {
        let requests = openRequests(in: proposals, now: now)

        let signedOut = sites
            .filter { $0.needsPerson || awaiting.contains($0.id) }
            .sorted { first, second in
                let (firstName, secondName) = (first.name.lowercased(), second.name.lowercased())
                if firstName != secondName { return firstName < secondName }
                return first.id < second.id
            }
            .map { site in
                Item(
                    host: site.id,
                    displayName: site.name,
                    kind: .signedOut(keepsSession: site.keepsSessionOnly),
                    proposalID: requests[site.id]?.id,
                    needsPerson: site.needsPerson
                )
            }

        let granted = Set(sites.map(\.id))
        let requested = requests
            .filter { !granted.contains($0.key) }
            .sorted { first, second in
                if first.value.created != second.value.created {
                    return first.value.created < second.value.created
                }
                return first.key < second.key
            }
            .compactMap { host, proposal in
                recognised(host).map { known in
                    Item(
                        host: host,
                        displayName: host,
                        kind: .requested(recognised: known),
                        proposalID: proposal.id
                    )
                }
            }
        return signedOut + requested
    }

    /// The hosts that are in demand but have no item yet: not granted, named by an open
    /// request, and with no answer yet from `recognised`.
    static func hostsAwaitingRecognition(
        proposals: [Proposal],
        sites: [SiteRecord],
        now: Date,
        recognised: (String) -> Bool?
    ) -> Set<String> {
        let granted = Set(sites.map(\.id))
        return Set(
            openRequests(in: proposals, now: now).keys
                .filter { !granted.contains($0) && recognised($0) == nil }
        )
    }

    /// What saving the sign-in for a site does to ProVisor's open work.
    struct SaveEffect: Equatable {
        /// The proposal the save answers: the earliest open request that names the site.
        let settles: String?
        /// Whether a follow-up pass is owed, so the check that waited on the site is made.
        let owesPass: Bool
    }

    /// The effect of saving the sign-in for `siteID`. The save answers the earliest open request
    /// for that site, and a pass is owed when there was such a request or the site was waiting on
    /// the person (`wasAwaited`: flagged as needing them, or a run was turned away from it).
    /// A request for any other site has no part in it.
    static func effectOfSaving(
        _ siteID: String,
        proposals: [Proposal],
        now: Date,
        wasAwaited: Bool
    ) -> SaveEffect {
        let request = openRequests(in: proposals, now: now)[siteID]
        return SaveEffect(settles: request?.id, owesPass: request != nil || wasAwaited)
    }

    /// The ids of the open requests (`openRequests`) for `hosts`.
    static func requestIDs(forHosts hosts: Set<String>, in proposals: [Proposal], now: Date) -> Set<String> {
        Set(openRequests(in: proposals, now: now).filter { hosts.contains($0.key) }.map(\.value.id))
    }

    /// When the demand next changes by the clock alone: the soonest expiry among the open
    /// requests, after which a request leaves the demand or a later one for its host takes its
    /// place. Nil when no open request expires.
    static func nextExpiry(of proposals: [Proposal], now: Date) -> Date? {
        openRequests(in: proposals, now: now).values.compactMap(\.expires).min()
    }

    /// The proposals that still ask for a site, by the host they ask for: those that can still
    /// be decided and have not expired, and the earliest of any that ask for the same host
    /// (`ProposalQueue.repeatedSiteRequests`).
    static func openRequests(in proposals: [Proposal], now: Date) -> [String: Proposal] {
        let repeated = ProposalQueue.repeatedSiteRequests(in: proposals, now: now)
        var requests: [String: Proposal] = [:]
        for proposal in proposals {
            guard proposal.isOpen, !ProposalReview.isExpired(proposal, now: now),
                  !repeated.contains(proposal.id), let host = proposal.site
            else { continue }
            requests[host] = proposal
        }
        return requests
    }
}

/// The granted sites the person answered "Not now" for, held in memory only.
///
/// A site put off is offered again once a run is next turned away from it. It is also
/// forgotten once it is no longer a granted site in demand, which is what saving its sign-in,
/// removing it, or a run reading it does, so a later need starts afresh.
struct SignInPostponements: Equatable {
    private(set) var hosts: Set<String> = []

    /// Puts off a granted site in demand. A requested host is never put off.
    mutating func postpone(_ item: SignInDemand.Item) {
        guard case .signedOut = item.kind else { return }
        hosts.insert(item.host)
    }

    mutating func turnedAway(_ host: String) {
        hosts.remove(host)
    }

    /// Forgets every host that is not a granted site in `demand`.
    mutating func prune(keeping demand: [SignInDemand.Item]) {
        let signedOut = demand.compactMap { item -> String? in
            if case .signedOut = item.kind { return item.host }
            return nil
        }
        hosts.formIntersection(signedOut)
    }
}

/// Keeps count of which sites the person has been told about, so each is announced once. A site
/// that leaves the demand is forgotten, so being turned away from it again announces it again.
struct SignInAnnouncer {
    /// The hosts in demand at the last look. Nil until seeded.
    private var known: Set<String>?

    /// Takes the items in demand at the first load after a start as already known, so a site
    /// that was waiting before the app launched is never announced as new. `pending` names the
    /// hosts in demand that have no item yet (`SignInDemand.hostsAwaitingRecognition`); they
    /// were waiting too.
    mutating func seedIfNeeded(with items: [SignInDemand.Item], pending: Set<String> = []) {
        if known == nil {
            known = Set(items.map(\.host)).union(pending)
        }
    }

    /// The items in `items` whose host was not in demand at the last look. Nothing is news
    /// before the announcer is seeded. A host in `pending` stays as it was while it has no item:
    /// known if it was known, and announced with its item if it was not.
    mutating func newItems(in items: [SignInDemand.Item], pending: Set<String> = []) -> [SignInDemand.Item] {
        guard let known else { return [] }
        self.known = Set(items.map(\.host)).union(known.intersection(pending))
        return items.filter { !known.contains($0.host) }
    }
}
