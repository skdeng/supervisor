import Foundation

/// What ProVisor's banner is announcing: a count of new proposals, or a site the person is
/// asked to sign in to. A sign-in outranks the count, since it is the one that waits on them.
enum ProVisorAnnouncement: Equatable {
    /// How many proposals needing a decision have been added while the banner was up.
    case ideas(Int)
    /// The site named on the banner, how many other sites in the demand are waiting too, and
    /// how many new proposals the sign-in is covering, which are announced if it leaves unseen.
    case signIn(SignInDemand.Item, more: Int, ideasBehind: Int)

    enum Event: Equatable {
        /// A finished run added this many proposals needing a decision.
        case ideasAdded(Int)
        /// `fresh` entered the demand and has not been announced; `demand` is the whole of it.
        case signInNeeded(fresh: [SignInDemand.Item], demand: [SignInDemand.Item])
        /// The demand changed; `demand` is the whole of it.
        case demandChanged([SignInDemand.Item])
        /// ProVisor's glow claim ended: the sheet was opened, or the banner's own action ran.
        /// Either way the person has seen what was announced.
        case glowCleared
        /// The count has been up for its full time.
        case ideasTimedOut
    }

    /// The announcement after `event`.
    ///
    /// Only items that may be announced (`SignInDemand.Item.isAnnounceable`) are ever named or
    /// counted. A sign-in replaces a count, and a count arriving under a sign-in leaves the
    /// sign-in up; either way the count is kept behind it. A second sign-in arriving under one
    /// keeps the named site, so the button never changes under a cursor, and grows `more`.
    /// A named site that leaves the demand retires the sign-in with no other site promoted into
    /// its place, since the sheet lists the rest; the count behind it, if any, takes its place,
    /// as nobody has seen it yet.
    static func next(_ current: ProVisorAnnouncement?, on event: Event) -> ProVisorAnnouncement? {
        switch event {
        case let .ideasAdded(count):
            guard count > 0 else { return current }
            switch current {
            case nil:
                return .ideas(count)
            case let .ideas(shown):
                return .ideas(shown + count)
            case let .signIn(named, more, behind):
                return .signIn(named, more: more, ideasBehind: behind + count)
            }

        case let .signInNeeded(fresh, demand):
            let behind = ideasBehind(current)
            if case let .signIn(named, _, _) = current,
               let kept = signIn(named, in: demand, ideasBehind: behind)
            {
                return kept
            }
            let announceable = Set(demand.filter(\.isAnnounceable).map(\.host))
            if let first = fresh.first(where: { $0.isAnnounceable && announceable.contains($0.host) }) {
                return signIn(first, in: demand, ideasBehind: behind)
            }
            if case .signIn = current { return uncovered(behind) }
            return current

        case let .demandChanged(demand):
            guard case let .signIn(named, _, behind) = current else { return current }
            return signIn(named, in: demand, ideasBehind: behind) ?? uncovered(behind)

        case .glowCleared:
            return nil

        case .ideasTimedOut:
            guard case .ideas = current else { return current }
            return nil
        }
    }

    /// The proposals `current` is announcing as a count, shown or kept behind a sign-in.
    private static func ideasBehind(_ current: ProVisorAnnouncement?) -> Int {
        switch current {
        case nil: return 0
        case let .ideas(count): return count
        case let .signIn(_, _, behind): return behind
        }
    }

    /// What is left when a sign-in retires unseen: the count it covered, or nothing.
    private static func uncovered(_ behind: Int) -> ProVisorAnnouncement? {
        behind > 0 ? .ideas(behind) : nil
    }

    /// The sign-in announcement for `named` as `demand` has it, or nil when `demand` holds no
    /// announceable item for its host.
    private static func signIn(
        _ named: SignInDemand.Item,
        in demand: [SignInDemand.Item],
        ideasBehind: Int
    ) -> ProVisorAnnouncement? {
        let announceable = demand.filter(\.isAnnounceable)
        guard let current = announceable.first(where: { $0.host == named.host }) else { return nil }
        return .signIn(current, more: announceable.count - 1, ideasBehind: ideasBehind)
    }

    /// What moving the banner from one announcement to the next asks of the module.
    struct Effects: Equatable {
        enum IdeasTimer: Equatable {
            /// Start the count's timeout, replacing any running.
            case start
            case cancel
        }

        /// Raise ProVisor's glow claim: something the person has not seen is announced.
        var raisesGlow = false
        /// Take an indefinite hold on the surface for the banner.
        var holds = false
        /// Release the hold: the banner is withdrawn.
        var releases = false
        var ideasTimer: IdeasTimer?
        /// Ask the engine to re-pick and re-lay-out the banner.
        var refreshes = false

        /// The effects of moving from `old` to `new`. A new banner raises the glow and takes the
        /// hold, and a withdrawn one releases it. Within a hold already taken, a newly named site
        /// or a grown count raises the glow again (a no-op while the claim stands), and a sign-in
        /// that keeps its site neither raises nor holds. A count that appears or grows restarts
        /// its timeout; a count that leaves cancels it.
        static func between(_ old: ProVisorAnnouncement?, _ new: ProVisorAnnouncement?) -> Effects {
            var effects = Effects()
            guard old != new else { return effects }
            effects.refreshes = true

            switch (old, new) {
            case (nil, .some):
                effects.raisesGlow = true
                effects.holds = true
            case (.some, nil):
                effects.releases = true
            case let (.some(.signIn(was, _, _)), .some(.signIn(named, _, _))):
                effects.raisesGlow = was.host != named.host
            case (.some(.ideas), .some(.signIn)):
                effects.raisesGlow = true
            case let (.some(.ideas(was)), .some(.ideas(count))):
                effects.raisesGlow = count > was
            case (.some(.signIn), .some(.ideas)), (nil, nil):
                break
            }

            switch (old, new) {
            case let (.ideas(was), .ideas(count)) where count > was:
                effects.ideasTimer = .start
            case (.ideas, .ideas):
                break
            case (_, .ideas):
                effects.ideasTimer = .start
            case (.ideas, _):
                effects.ideasTimer = .cancel
            default:
                break
            }
            return effects
        }
    }
}
