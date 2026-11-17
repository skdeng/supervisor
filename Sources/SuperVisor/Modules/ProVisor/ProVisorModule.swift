import Combine
import SwiftUI

/// ProVisor — a background agent that reads the user's own data and proposes things they
/// would want done but have not thought to ask for.
///
/// The agent is a headless Claude Code run with a standing brief, its own notes, and read-only
/// access to the user's connectors (`ProVisorCenter`, `ProVisorHome`). This module is the
/// surface around it:
/// - **Expanded:** the sites waiting on the person's sign-in, then the proposals awaiting a
///   decision. Each proposal opens the review window (`ProVisorReviewWindow`), which shows why
///   it was proposed and the ways to act on it, and takes an instruction typed in their place;
///   nothing is carried out without a tap there.
/// - **Banner:** one announcement at a time (`ProVisorAnnouncement`): a site to sign in to, held
///   until the person acts on it or opens the sheet, or else a content-free count of the
///   proposals a pass added, which retires after a few seconds. The glow either raises stays
///   until the sheet is opened, the way it does for any other new attention.
/// - **Compact:** nothing. An idea waiting is not a live activity.
///
/// Off until the user enables it: it reads their mail and spends their Claude quota.
@MainActor
final class ProVisorModule: NotchModule, ObservableObject {
    let moduleID = "provisor"
    let displayName = "ProVisor"
    let order = 35

    /// How long a count of new proposals stays up when nothing retires it sooner.
    private static let ideasSeconds: TimeInterval = 8

    /// What the banner is announcing, while it is up.
    @Published private(set) var announcement: ProVisorAnnouncement?

    private let center = ProVisorCenter.shared
    private var context: NotchContext?
    private var glowSubscription: AnyCancellable?
    private var promptsSubscription: AnyCancellable?
    private var ideasTimeout: Task<Void, Never>?
    private var expandedPresence = false

    func activate(_ context: NotchContext) {
        guard self.context == nil else { return }
        self.context = context

        center.onProposalsChanged = { [weak self] in
            self?.reconcileExpandedPresence()
        }
        center.onProposalsAdded = { [weak self] count in
            self?.receive(.ideasAdded(count))
        }
        center.onSignInNeeded = { [weak self] fresh in
            guard let self else { return }
            receive(.signInNeeded(fresh: fresh, demand: center.signInPrompts))
        }
        // The published value is delivered before it is stored, so the sink uses what it is
        // handed rather than reading the center back.
        promptsSubscription = center.$signInPrompts.dropFirst().sink { [weak self] prompts in
            self?.receive(.demandChanged(prompts))
            self?.reconcileExpandedPresence(prompts: prompts)
        }
        // Opening the sheet ends every glow claim, and the end of ProVisor's own claim is the
        // signal that the person looked. Another module ending its claim leaves this one.
        glowSubscription = AttentionGlowCenter.shared.claimPublisher(for: moduleID)
            .sink { [weak self] claimed in
                if !claimed {
                    self?.receive(.glowCleared)
                }
            }
        center.start()
    }

    func deactivate() {
        guard let context else { return }
        let hadExpandedSection = expandedPresence
        let wasAnnouncing = announcement != nil

        glowSubscription?.cancel()
        glowSubscription = nil
        promptsSubscription?.cancel()
        promptsSubscription = nil
        ideasTimeout?.cancel()
        ideasTimeout = nil
        center.onProposalsChanged = nil
        center.onProposalsAdded = nil
        center.onSignInNeeded = nil
        center.stop()
        ProVisorReviewWindow.shared.close()
        // A disabled module leaves no glow orbiting for attention it can no longer show.
        AttentionGlowCenter.shared.clear(for: moduleID)

        announcement = nil
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
        guard hasSectionContent() else { return nil }
        return AnyView(
            ProVisorSectionView(
                center: center,
                onReview: { [weak self] id in self?.openReview(id) },
                onSignIn: { [weak self] item in self?.openSignIn(item) }
            )
        )
    }

    func peekBanner() -> AnyView? {
        guard announcement != nil else { return nil }
        return AnyView(ProVisorPeekBannerView(module: self))
    }

    /// Opens the sheet on the proposals. Opening clears the glow, which retires the banner.
    func review() {
        context?.requestExpand()
    }

    /// Opens the window to sign in to the site the banner names, and acknowledges the
    /// attention: ProVisor's glow claim ends, and the banner retires with it. The sheet keeps
    /// the site's row until the sign-in is saved. Collapsing is left alone, since a collapse
    /// request drops every other module's banner hold with this one.
    func signIn(_ item: SignInDemand.Item) {
        ProVisorSiteWindow.shared.showSignIn(item)
        AttentionGlowCenter.shared.clear(for: moduleID)
        receive(.glowCleared)
    }

    /// Opens the review window on one proposal and closes the sheet, which would otherwise sit
    /// over the window until the cursor left it.
    private func openReview(_ id: String) {
        ProVisorReviewWindow.shared.show(id, center: center)
        context?.requestCollapse()
    }

    /// Opens the sign-in window from a sheet row and closes the sheet, as `openReview` does.
    private func openSignIn(_ item: SignInDemand.Item) {
        ProVisorSiteWindow.shared.showSignIn(item)
        context?.requestCollapse()
    }

    private func hasSectionContent(prompts: [SignInDemand.Item]? = nil) -> Bool {
        !(prompts ?? center.signInPrompts).isEmpty
            || !ProposalQueue.visible(center.proposals, now: Date()).isEmpty
    }

    /// Moves the banner to what `event` makes of it and applies what that move asks for
    /// (`ProVisorAnnouncement.Effects`). Withdrawing the banner and then releasing the hold, in
    /// that order, is the single exit, so the engine's release path no longer counts this
    /// module's banner as unresolved.
    private func receive(_ event: ProVisorAnnouncement.Event) {
        let previous = announcement
        let next = ProVisorAnnouncement.next(previous, on: event)
        let effects = ProVisorAnnouncement.Effects.between(previous, next)

        if effects.raisesGlow {
            AttentionGlowCenter.shared.raise(for: moduleID)
        }
        switch effects.ideasTimer {
        case .start:
            restartIdeasTimeout()
        case .cancel:
            ideasTimeout?.cancel()
            ideasTimeout = nil
        case nil:
            break
        }

        announcement = next
        if effects.holds {
            context?.requestPeek(.infinity)
        }
        if effects.releases {
            context?.requestPeek(0)
        }
        // With another module's banner already holding the peek a hold publishes no engine
        // change, and a banner that changed size within a hold needs re-laying-out; the refresh
        // is what makes the root view re-pick the banner slot.
        if effects.refreshes {
            context?.setNeedsCompactRefresh()
        }
    }

    private func restartIdeasTimeout() {
        ideasTimeout?.cancel()
        ideasTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ProVisorModule.ideasSeconds))
            guard !Task.isCancelled else { return }
            self?.ideasTimeout = nil
            self?.receive(.ideasTimedOut)
        }
    }

    private func reconcileExpandedPresence(prompts: [SignInDemand.Item]? = nil) {
        let isPresent = hasSectionContent(prompts: prompts)
        guard isPresent != expandedPresence else { return }
        expandedPresence = isPresent
        // The revision bump makes the panel re-query its sections.
        context?.setNeedsCompactRefresh()
    }
}
