import AppKit
import Combine
import SwiftUI

/// Mirrors incoming message/call notifications (iMessage, WhatsApp, Telegram, Slack,
/// FaceTime, …) into the notch.
///
/// ## How it works
/// The module owns a `NotificationCenterObserver` that watches the
/// `com.apple.notificationcenterui` process via the Accessibility API and parses each new
/// banner into a `NotificationItem` (see that file for the AX approach and the permission
/// requirement). On each capture the module:
///
///   - resolves the originating app's icon off the main actor,
///   - prepends the item to a bounded recent-feed,
///   - flashes a transient **sender chip** in the compact leading slot and asks the engine
///     to `requestPeek` so the banner surfaces without a full expansion,
///   - renders a rich banner (icon + sender + preview) as its compact trailing
///     contribution while the peek is active.
///
/// The expanded section shows a short scrollable feed of recent notifications so they can be
/// re-reviewed without opening Notification Center.
///
/// ## Permission
/// Reading other apps' notifications requires the host app to be a trusted **Accessibility**
/// client. When that trust is missing the module renders an inline prompt (in the expanded
/// section) that deep-links to System Settings; the observer self-heals once access is
/// granted, with no relaunch.
@MainActor
final class NotificationsModule: NotchModule, ObservableObject {
    let moduleID = "notifications"
    let displayName = "Notifications"
    let order = 70

    /// The most recent captured notifications, newest first. Bounded to `maxFeed`.
    @Published private(set) var feed: [NotificationItem] = []
    /// The banner currently being surfaced as compact content (during a peek), if any.
    @Published private(set) var activeBanner: NotificationItem?
    /// Observer authorization / running state, mirrored for the inline permission prompt.
    @Published private(set) var observerState: NotificationCenterObserver.State = .stopped

    /// Maximum number of notifications retained in the feed.
    private let maxFeed = 20
    /// How long a captured banner stays surfaced as compact content / peek.
    private let bannerDuration: TimeInterval = 5.0

    private var context: NotchContext?
    private var observer: NotificationCenterObserver?
    private let iconResolver = NotificationAppIconResolver()

    /// Work item that clears `activeBanner` after `bannerDuration`; replaced on each capture
    /// so back-to-back notifications extend the surface rather than flicker.
    private var dismissBannerWork: DispatchWorkItem?

    // MARK: - NotchModule lifecycle

    func activate(_ context: NotchContext) {
        self.context = context

        let observer = NotificationCenterObserver(
            onCapture: { [weak self] item in
                self?.handleCapture(item)
            },
            onStateChange: { [weak self] newState in
                self?.observerState = newState
            }
        )
        self.observer = observer

        // Prompt once on first activation so the user is guided to grant Accessibility
        // access if it has not been granted yet.
        observer.start(promptForPermission: true)
    }

    func deactivate() {
        dismissBannerWork?.cancel()
        dismissBannerWork = nil
        observer?.stop()
        observer = nil
        activeBanner = nil
        context = nil
    }

    // MARK: - Capture handling

    private func handleCapture(_ item: NotificationItem) {
        // Resolve the icon off the main actor, then publish the enriched item.
        Task { [weak self, iconResolver] in
            guard let self else { return }
            let icon = await iconResolver.icon(forAppName: item.appName)
            let enriched = NotificationItem(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                body: item.body,
                appName: item.appName,
                icon: icon,
                date: item.date
            )
            self.present(enriched)
        }
    }

    private func present(_ item: NotificationItem) {
        let hadCompactContribution = (activeBanner != nil)

        // Prepend to the feed, bounded.
        feed.insert(item, at: 0)
        if feed.count > maxFeed {
            feed.removeLast(feed.count - maxFeed)
        }

        activeBanner = item

        // If we previously had no compact contribution, the pill's compact layout changes —
        // tell the engine to re-lay-out. (Subsequent banner swaps update in place via
        // @ObservedObject and don't need a refresh.)
        if !hadCompactContribution {
            context?.setNeedsCompactRefresh()
        }

        // Surface the banner transiently without stealing the expanded panel.
        context?.requestPeek(bannerDuration)

        // Schedule removal of the compact contribution.
        dismissBannerWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearActiveBanner()
        }
        dismissBannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bannerDuration, execute: work)
    }

    private func clearActiveBanner() {
        guard activeBanner != nil else { return }
        activeBanner = nil
        // The compact contribution disappeared; the pill must re-lay-out.
        context?.setNeedsCompactRefresh()
    }

    /// Clear the recent-notifications feed (expanded-panel action).
    func clearFeed() {
        feed.removeAll()
    }

    /// Re-check Accessibility trust and (re)start the observer. Wired to the inline prompt.
    func requestAccessibilityAccess() {
        NotificationCenterObserver.openAccessibilitySettings()
        // Trigger the system prompt as well in case it has never been shown.
        observer?.start(promptForPermission: true)
    }

    // MARK: - UI contributions

    func compactLeading() -> AnyView? {
        guard activeBanner != nil else { return nil }
        return AnyView(NotificationSenderChip(module: self))
    }

    func compactTrailing() -> AnyView? {
        guard activeBanner != nil else { return nil }
        return AnyView(NotificationCompactBanner(module: self))
    }

    func expandedSection() -> AnyView? {
        AnyView(NotificationsExpandedSection(module: self))
    }
}
