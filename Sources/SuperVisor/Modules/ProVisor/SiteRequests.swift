import Foundation

/// A proposal that asks for a site (`Proposal.site`), settled by the user signing in to it.
///
/// Signing in is the answer, so the proposal is recorded `done` the way a carried-out action
/// is, with a fixed result naming the site; no run is started and no choice is recorded. Only
/// the site the request was for settles it, and only while the file on disk still asks for it
/// (`ProposalStore.settleSiteRequest`).
enum SiteRequests {
    enum Outcome: Equatable {
        case settled
        /// The site saved is not the one the request was opened for.
        case otherSite
        /// A run is carrying the proposal out, or is queued to.
        case busy
        /// On disk the proposal is settled, dismissed, or withdrawn.
        case notOpen
        /// On disk the proposal asks for another site, or for none.
        case siteChanged
        /// The file could not be read or written.
        case notRecorded

        /// A fixed name for the log.
        var logName: String {
            switch self {
            case .settled: "settled"
            case .otherSite: "other site"
            case .busy: "busy"
            case .notOpen: "not open"
            case .siteChanged: "site changed"
            case .notRecorded: "not recorded"
            }
        }
    }

    static func result(siteName: String) -> String {
        "Signed in to \(siteName)."
    }

    /// Records proposal `id` in `directory` as done with `result(siteName:)` when `savedSiteID`
    /// is `host`, no run holds the proposal, and the file on disk still asks for `host`.
    static func settle(
        proposalID id: String,
        host: String,
        savedSiteID: String,
        siteName: String,
        in directory: URL,
        isBusy: Bool,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Outcome {
        guard savedSiteID == host else { return .otherSite }
        guard !isBusy else { return .busy }
        do {
            let settlement = try ProposalStore.settleSiteRequest(
                id: id,
                in: directory,
                host: host,
                result: Proposal.displayText(result(siteName: siteName), limit: Proposal.resultLimit)
                    ?? result(siteName: host),
                now: now,
                timeZone: timeZone
            )
            switch settlement {
            case .settled: return .settled
            case .notOpen: return .notOpen
            case .siteChanged: return .siteChanged
            }
        } catch {
            AppLog.error(.provisor, "site request not recorded")
            return .notRecorded
        }
    }
}
