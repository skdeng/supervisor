import AppKit
import Foundation

/// Resolves an app icon from the loose information available on a captured notification
/// banner.
///
/// Notification Center's AX tree does not expose the originating bundle id, only display
/// text. The most reliable signal is the banner's app-name label (e.g. "Messages",
/// "WhatsApp", "Slack"). We resolve that to an icon by, in order:
///
///   1. Matching a running application's `localizedName` (covers the common case where the
///      sending app is open — iMessage, Slack, Telegram, etc.).
///   2. A curated bundle-id map for well-known messaging apps, resolved through Launch
///      Services (`NSWorkspace.urlForApplication`).
///   3. Launch Services lookup by display name as an app on disk.
///
/// All lookups are cached. This type is an actor so resolution can run off the main thread
/// (Launch Services and the running-app scan are not free) while the cache stays
/// thread-safe; callers `await` an `NSImage` and hop back to the main actor to publish it.
actor NotificationAppIconResolver {
    private var cache: [String: NSImage] = [:]

    /// Well-known messaging/calling apps keyed by the display name macOS shows on the
    /// banner. Values are bundle identifiers resolved through Launch Services. Names are
    /// matched case-insensitively.
    private static let knownBundleIDs: [String: String] = [
        "messages": "com.apple.MobileSMS",
        "facetime": "com.apple.FaceTime",
        "mail": "com.apple.mail",
        "phone": "com.apple.mobilephone",
        "whatsapp": "net.whatsapp.WhatsApp",
        "telegram": "ru.keepcoder.Telegram",
        "telegram lite": "org.telegram.desktop",
        "slack": "com.tinyspeck.slackmacgap",
        "signal": "org.whispersystems.signal-desktop",
        "discord": "com.hnc.Discord",
        "messenger": "com.facebook.archon",
        "microsoft teams": "com.microsoft.teams2",
        "teams": "com.microsoft.teams2",
        "zoom": "us.zoom.xos",
    ]

    /// Resolve an icon for the given banner app name. Returns nil only when no signal is
    /// available at all.
    func icon(forAppName appName: String?) -> NSImage? {
        guard let appName, !appName.isEmpty else { return nil }
        let key = appName.lowercased()

        if let cached = cache[key] {
            return cached
        }

        if let image = resolve(appName: appName, key: key) {
            cache[key] = image
            return image
        }
        return nil
    }

    private func resolve(appName: String, key: String) -> NSImage? {
        // 1. Running application whose localized name matches the banner label.
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(appName) == .orderedSame
        }), let icon = running.icon {
            return icon
        }

        // 2. Curated bundle-id map -> Launch Services.
        if let bundleID = Self.knownBundleIDs[key],
           let icon = iconForBundleID(bundleID) {
            return icon
        }

        // 3. Launch Services lookup by display name (".app" on disk).
        if let icon = iconForAppNamed(appName) {
            return icon
        }

        return nil
    }

    private func iconForBundleID(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func iconForAppNamed(_ appName: String) -> NSImage? {
        // Probe the standard application directories for "<AppName>.app".
        let candidates = [
            "/Applications/\(appName).app",
            "/System/Applications/\(appName).app",
            NSHomeDirectory() + "/Applications/\(appName).app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
}
