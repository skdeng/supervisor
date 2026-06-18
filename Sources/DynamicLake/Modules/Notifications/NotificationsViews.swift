import AppKit
import SwiftUI

// MARK: - Compact leading: sender chip

/// A tiny chip shown to the left of the notch while a banner is active: the originating
/// app's icon (or a bell glyph) plus the sender's name. Updates live via `@ObservedObject`.
struct NotificationSenderChip: View {
    @ObservedObject var module: NotificationsModule

    var body: some View {
        if let banner = module.activeBanner {
            HStack(spacing: 5) {
                NotificationIconView(icon: banner.icon, size: 14)
                Text(banner.senderLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(NotchTheme.primaryForeground)
            }
            .fixedSize()
            .transition(.opacity.combined(with: .scale(scale: 0.85)))
            .animation(.easeInOut(duration: 0.2), value: banner.id)
        }
    }
}

// MARK: - Compact trailing: preview banner

/// The richer compact contribution shown to the right of the notch while a banner is active:
/// app icon + sender + one-line preview.
struct NotificationCompactBanner: View {
    @ObservedObject var module: NotificationsModule

    var body: some View {
        if let banner = module.activeBanner {
            HStack(spacing: 6) {
                NotificationIconView(icon: banner.icon, size: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(banner.senderLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(NotchTheme.primaryForeground)
                    if let preview = banner.preview {
                        Text(preview)
                            .font(.system(size: 9, weight: .regular))
                            .lineLimit(1)
                            .foregroundStyle(NotchTheme.secondaryForeground)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 180, alignment: .leading)
            }
            .fixedSize()
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.easeInOut(duration: 0.2), value: banner.id)
        }
    }
}

// MARK: - Expanded section

/// The expanded-panel section: either the Accessibility permission prompt (when access is
/// missing) or a short scrollable feed of recent notifications.
struct NotificationsExpandedSection: View {
    @ObservedObject var module: NotificationsModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            switch module.observerState {
            case .authorizationDenied:
                permissionPrompt
            case .unavailable:
                unavailableNotice
            case .stopped, .running:
                feedContent
            }
        }
        .padding(NotchTheme.panelPadding - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
    }

    private var header: some View {
        HStack {
            Label("Notifications", systemImage: "bell.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchTheme.primaryForeground)
            Spacer()
            if !module.feed.isEmpty, module.observerState != .authorizationDenied {
                Button(action: module.clearFeed) {
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
    }

    @ViewBuilder
    private var feedContent: some View {
        if module.feed.isEmpty {
            Text("No recent notifications")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.secondaryForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(module.feed) { item in
                        NotificationFeedRow(item: item)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private var permissionPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
                Text("Accessibility access is required to mirror notifications.")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: module.requestAccessibilityAccess) {
                Text("Open Accessibility Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .liquidGlass(cornerRadius: 8, interactive: true)
            .foregroundStyle(NotchTheme.primaryForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unavailableNotice: some View {
        Text("Waiting for Notification Center…")
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.secondaryForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }
}

/// One row in the recent-notifications feed: icon, sender, preview, relative time.
private struct NotificationFeedRow: View {
    let item: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            NotificationIconView(icon: item.icon, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(item.senderLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(item.date, style: .relative)
                        .font(.system(size: 9))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.primaryForeground.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(NotchTheme.primaryForeground)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Shared icon view

/// Renders an app icon when available, falling back to a bell glyph so the layout never
/// collapses on apps whose icon could not be resolved.
struct NotificationIconView: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: size * 0.72))
                    .foregroundStyle(NotchTheme.primaryForeground)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
