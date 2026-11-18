import AppKit
import SwiftUI

/// The window where the granted sites are managed: each with what it needs, a way to sign in
/// again, and a way to remove it, plus the way to add one. Settings opens it and shows a count.
///
/// **The window's size is the user's.** Its hosting controller carries no sizing options (the
/// hazard `FittedWindow` describes): the list grows and shrinks, and a controller that sized
/// the window to it would resize the window from inside a layout pass.
@MainActor
final class ProVisorSitesWindow {
    static let shared = ProVisorSitesWindow()

    static let initialContentSize = NSSize(width: 520, height: 380)
    static let minimumContentSize = NSSize(width: 440, height: 240)

    private(set) var window: NSWindow?

    private init() {}

    func show(center: SiteAccessCenter = .shared) {
        center.refresh()
        let window = reusableWindow(center: center)
        window.makeKeyAndOrderFront(nil)
        // An accessory app is never frontmost by itself.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reusableWindow(center: SiteAccessCenter) -> NSWindow {
        if let window {
            (window.contentViewController as? NSHostingController<ProVisorSitesView>)?.rootView =
                ProVisorSitesView(sites: center)
            return window
        }
        let window = Self.makeWindow(center: center)
        window.center()
        self.window = window
        return window
    }

    static func makeWindow(center: SiteAccessCenter) -> NSWindow {
        let hosting = NSHostingController(rootView: ProVisorSitesView(sites: center))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "ProVisor Sites"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentViewController = hosting
        // Taking the controller sizes the window to the controller's view; the window's own
        // size is set after.
        window.setContentSize(initialContentSize)
        window.contentMinSize = minimumContentSize
        return window
    }
}

/// The granted sites and what can be done with each.
struct ProVisorSitesView: View {
    @ObservedObject var sites: SiteAccessCenter

    @State private var removing: SiteRecord?
    /// Sites whose last removal failed.
    @State private var removalFailures: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ProVisor can read pages on these sites signed in, and only read. A site kept signed in holds no password and asks you to sign in again when it signs you out; for a site SuperVisor signs in to, the password stays in your Keychain and SuperVisor fills it in itself.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)

            Divider()

            if sites.sites.isEmpty {
                Text("No sites yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sites.sites) { site in
                            siteRow(site)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Add Site…") { ProVisorSiteWindow.shared.showAdding(center: sites) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onWindowBecomesKey { sites.refresh() }
        .confirmationDialog(
            removing.map { "Remove \($0.name)?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { site in
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await sites.remove(site.id)
                        removalFailures.remove(site.id)
                    } catch {
                        removalFailures.insert(site.id)
                    }
                }
            }
        } message: { _ in
            Text("Its saved sign-in and the site's cookies are deleted.")
        }
    }

    private func siteRow(_ site: SiteRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.name)
                    HStack(spacing: 4) {
                        Text(site.id)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.secondary)
                        siteStatus(site)
                    }
                    .font(.callout)
                }
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button("Sign In Again") {
                    ProVisorSiteWindow.shared.showSignInAgain(site, center: sites)
                }
                Button("Remove") { removing = site }
            }
            .controlSize(.small)

            if removalFailures.contains(site.id) {
                Text(Self.removalFailureMessage(
                    siteName: site.name,
                    appIsIntact: PeerIdentity.runningCodeIsIntact()
                ))
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What a failed removal says. An app whose bundle was replaced under it is refused by the
    /// Keychain until it relaunches, and it relaunches only once its windows are closed, so the
    /// sentence says to close this one.
    static func removalFailureMessage(siteName: String, appIsIntact: Bool) -> String {
        appIsIntact
            ? "Couldn't remove \(siteName). Try again."
            : "Couldn't remove \(siteName): SuperVisor was updated and has to reopen first. Close this window, wait a few seconds, and try again."
    }

    @ViewBuilder
    private func siteStatus(_ site: SiteRecord) -> some View {
        switch SiteAccessCenter.SiteStatus(site, awaiting: sites.awaitingSignIn) {
        case .needsYou:
            Text("Needs you")
                .foregroundStyle(.orange)
        case let .signedIn(date):
            Text("Signed in \(date.formatted(.relative(presentation: .named)))")
                .foregroundStyle(.secondary)
        case let .signedInKeepingSession(date):
            Text("Signed in \(date.formatted(.relative(presentation: .named))) · asks you when it signs you out")
                .foregroundStyle(.secondary)
        case .notSignedInYet:
            Text("Not signed in yet")
                .foregroundStyle(.secondary)
        }
    }
}
