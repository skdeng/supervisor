import AppKit
import Foundation

/// A single notification banner captured from macOS Notification Center.
///
/// Notification banners surfaced by `com.apple.notificationcenterui` expose their text
/// through the Accessibility tree but not a stable identifier, so we synthesize a UUID per
/// capture and de-duplicate on the visible text + source within a short window (see
/// `NotificationCenterObserver`).
struct NotificationItem: Identifiable, Equatable {
    let id: UUID
    /// The notification title — typically the sender's name or the conversation title.
    let title: String
    /// The secondary line — for messaging apps this is usually the conversation/group, and
    /// for some apps it is empty.
    let subtitle: String?
    /// The notification body — the message preview text.
    let body: String?
    /// Display name of the originating app as read from the banner (best effort).
    let appName: String?
    /// The originating app's icon, resolved from the running-app list or Launch Services.
    let icon: NSImage?
    /// When this banner was captured.
    let date: Date

    init(
        id: UUID = UUID(),
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        appName: String? = nil,
        icon: NSImage? = nil,
        date: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.appName = appName
        self.icon = icon
        self.date = date
    }

    static func == (lhs: NotificationItem, rhs: NotificationItem) -> Bool {
        lhs.id == rhs.id
    }

    /// The single-line preview shown in compact contexts: the body when present, else the
    /// subtitle, else nothing.
    var preview: String? {
        if let body, !body.isEmpty { return body }
        if let subtitle, !subtitle.isEmpty { return subtitle }
        return nil
    }

    /// The short sender chip label shown briefly in the compact leading slot.
    var senderLabel: String {
        if !title.isEmpty { return title }
        if let appName, !appName.isEmpty { return appName }
        return "Notification"
    }

    /// A stable signature used to suppress duplicate captures of the same banner. The AX
    /// tree can report the same banner via several notifications as it animates in, so we
    /// collapse on the visible content rather than the synthesized id.
    var dedupeSignature: String {
        [title, subtitle ?? "", body ?? "", appName ?? ""].joined(separator: "\u{1F}")
    }
}
