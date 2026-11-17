import AppKit
import SwiftUI
import WebKit

/// The live page of a site window: where the page is, above the page itself.
struct SiteLivePagePane: View {
    @ObservedObject var enrollment: SiteEnrollment

    var body: some View {
        VStack(spacing: 0) {
            SiteLocationBar(
                host: enrollment.currentHost,
                isSecure: enrollment.currentIsSecure,
                isWorking: enrollment.isWorking
            )
            Divider()
            SiteWebViewHost(browser: enrollment.browser)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the page is: its host behind a padlock, or a red warning when the page is not fully
/// secure. It is always on screen, so the user can see they are on the real site before a
/// password goes into it.
struct SiteLocationBar: View {
    let host: String?
    let isSecure: Bool
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let host {
                if isSecure {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help("The page and everything on it came over an encrypted connection")
                    Text(host)
                        .fontWeight(.medium)
                } else {
                    Image(systemName: "lock.open.fill")
                        .foregroundStyle(.red)
                        .help("Part of this page did not come over an encrypted connection")
                    Text("Not secure")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    Text(host)
                        .foregroundStyle(.red)
                }
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                Text("No page yet")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// Hosts the enrollment browser's web view, moved out of the browser's hidden window.
struct SiteWebViewHost: NSViewRepresentable {
    let browser: SiteBrowser

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        browser.present(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if browser.webView.superview !== container {
            browser.present(in: container)
        }
    }
}

/// The window's primary action, in the brand gradient.
struct SiteProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(NotchTheme.brandGradient))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

extension View {
    /// A text field drawn in the system's colours, outlined in the brand gradient while focused.
    func siteFieldChrome(isFocused: Bool) -> some View {
        textFieldStyle(.plain)
            .focusEffectDisabled()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isFocused
                            ? AnyShapeStyle(NotchTheme.brandGradient)
                            : AnyShapeStyle(Color(nsColor: .separatorColor)),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }
}
