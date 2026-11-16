import Combine
import SwiftUI

/// ProVisor — a background agent that reads the user's own data and proposes things they
/// would want done but have not thought to ask for.
///
/// The agent is a headless Claude Code run with a standing brief, its own notes, and read-only
/// access to the user's connectors (`ProVisorCenter`, `ProVisorHome`). This module is the
/// surface around it:
/// - **Expanded:** the proposals awaiting a decision. Each opens a review screen showing why it
///   was proposed and exactly what approving does; nothing is carried out without that tap.
/// - **Banner:** a short, content-free notice when a scouting pass adds proposals. The glow it
///   raises stays until the sheet is opened, the way it does for any other new attention.
/// - **Compact:** nothing. An idea waiting is not a live activity.
///
/// Off until the user enables it: it reads their mail and spends their Claude quota.
@MainActor
final class ProVisorModule: NotchModule, ObservableObject {
    let moduleID = "provisor"
    let displayName = "ProVisor"
    let order = 35

    static let detailTakeoverID = "provisor-detail"
    /// How long the banner stays up when nothing retires it sooner.
    private static let announcementSeconds: TimeInterval = 8

    /// How many new proposals the banner is announcing, while it is up.
    @Published private(set) var announcedCount: Int?

    private let center = ProVisorCenter.shared
    private var context: NotchContext?
    private var glowSubscription: AnyCancellable?
    private var retireTask: Task<Void, Never>?
    private var expandedPresence = false

    func activate(_ context: NotchContext) {
        guard self.context == nil else { return }
        self.context = context

        center.onProposalsChanged = { [weak self] in
            self?.reconcileExpandedPresence()
        }
        center.onScoutAdded = { [weak self] count in
            self?.announce(count)
        }
        // Opening the sheet clears the glow, and that is the signal that the user looked.
        glowSubscription = AttentionGlowCenter.shared.$isRaised.sink { [weak self] raised in
            if !raised {
                self?.retireAnnouncement()
            }
        }
        center.start()
    }

    func deactivate() {
        guard let context else { return }
        let hadExpandedSection = expandedPresence
        let wasAnnouncing = announcedCount != nil

        glowSubscription?.cancel()
        glowSubscription = nil
        retireTask?.cancel()
        retireTask = nil
        center.onProposalsChanged = nil
        center.onScoutAdded = nil
        center.stop()
        SheetTakeoverCenter.shared.dismiss(id: Self.detailTakeoverID)

        announcedCount = nil
        expandedPresence = false
        if hadExpandedSection {
            context.setNeedsCompactRefresh()
        }
        // The banner holds the surface indefinitely; the hold is released before the context
        // goes, or it would pin the resting state to `.compact` for good.
        if wasAnnouncing {
            context.requestPeek(0)
        }
        self.context = nil
    }

    func expandedSection() -> AnyView? {
        guard hasVisibleProposals else { return nil }
        return AnyView(ProVisorSectionView(center: center))
    }

    func peekBanner() -> AnyView? {
        guard announcedCount != nil else { return nil }
        return AnyView(ProVisorPeekBannerView(module: self))
    }

    /// Opens the sheet on the proposals. Opening clears the glow, which retires the banner.
    func review() {
        context?.requestExpand()
    }

    private var hasVisibleProposals: Bool {
        !ProposalQueue.visible(center.proposals, now: Date()).isEmpty
    }

    /// Raises the banner for proposals a scouting pass just added, and holds the surface for
    /// it. `retireAnnouncement` is the single exit: the timeout, the sheet opening, or the
    /// module deactivating.
    private func announce(_ count: Int) {
        announcedCount = count
        AttentionGlowCenter.shared.raise()
        context?.requestPeek(.infinity)
        // With another module's banner already holding the peek the request publishes no
        // engine change; the refresh is what makes the root view re-pick the banner slot.
        context?.setNeedsCompactRefresh()

        retireTask?.cancel()
        retireTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ProVisorModule.announcementSeconds))
            guard !Task.isCancelled else { return }
            self?.retireAnnouncement()
        }
    }

    /// Withdraws the banner, then releases the hold — in that order, so the engine's release
    /// path no longer counts this module's banner as unresolved.
    private func retireAnnouncement() {
        retireTask?.cancel()
        retireTask = nil
        guard announcedCount != nil else { return }
        announcedCount = nil
        context?.requestPeek(0)
        context?.setNeedsCompactRefresh()
    }

    private func reconcileExpandedPresence() {
        let isPresent = hasVisibleProposals
        guard isPresent != expandedPresence else { return }
        expandedPresence = isPresent
        // The revision bump makes the panel re-query its sections.
        context?.setNeedsCompactRefresh()
    }
}
