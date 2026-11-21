import AppKit
import SwiftUI
import WebKit

/// The person's sign-in to a direct-message source, on the source's own page in a browser they
/// watch.
///
/// The browser reports nothing of what is typed (`SiteBrowser.Observation.none`) and the app
/// fills nothing in, so the app never holds the password: what it keeps is the session the
/// page leaves in the source's data store. Done is checked by a sync, which loads the inbox in
/// a second, hidden browser on that store.
@MainActor
final class DirectMessageSignInModel: ObservableObject {
    enum Phase: Equatable {
        case signingIn
        case checking
        /// Done was pressed and the source did not read as signed in; the sentence says why.
        case notConfirmed(String)
        case finished
    }

    static let instruction = "Sign in on the page, then press Done. SuperVisor keeps the session "
        + "the page leaves and never sees your password."

    let browser: SiteBrowser
    let sourceName: String

    @Published private(set) var host: String?
    @Published private(set) var isSecure = false
    @Published private(set) var phase: Phase = .signingIn
    /// The page did not load, which Try Again answers.
    @Published private(set) var loadFailed = false

    /// Called once when the sign-in closes, by whatever route.
    var onClosed: (@MainActor () -> Void)?

    private let center: DirectMessageCenter
    private(set) var isClosed = false

    init(center: DirectMessageCenter, pages: SiteBrowser.SimulatedPages? = nil, settling: SiteBrowser.Settling = .standard) {
        self.center = center
        sourceName = center.source.name
        browser = SiteBrowser(
            policy: .anyHTTPSHost,
            dataStore: center.dataStore,
            simulatedPages: pages,
            settling: settling
        )
        browser.locationObserver = { [weak self] in
            self?.refreshLocation()
        }
        center.signInBegan(self)
    }

    var title: String { "Sign In to \(sourceName)" }

    /// Loads the source's sign-in page.
    func openStartPage() async {
        loadFailed = false
        await center.sessionSettled()
        guard !isClosed else { return }
        do {
            _ = try await browser.open(center.source.signInURL)
        } catch SiteBrowser.Failure.closed {
            return
        } catch {
            // The person may have moved the page on by the time a slow load is given up on.
            loadFailed = browser.committedURL == nil
        }
    }

    /// Checks the sign-in. True when the source reads as signed in, which is when the window
    /// closes.
    func done() async -> Bool {
        guard phase != .checking, phase != .finished else { return false }
        phase = .checking
        let outcome = await center.confirmSignIn()
        guard !isClosed else { return false }
        if let sentence = Self.refusal(for: outcome, sourceName: sourceName) {
            phase = .notConfirmed(sentence)
            return false
        }
        phase = .finished
        return true
    }

    /// Why Done did not finish, or nil when the source reads as signed in. A source whose
    /// inbox loaded signed in counts even when no chat could be read from it: that is the
    /// sync's problem, shown in Settings, and signing in again would not mend it.
    static func refusal(for outcome: DirectMessageSync.Outcome?, sourceName: String) -> String? {
        switch outcome {
        case .synced?, .nothingCaptured?:
            nil
        case .needsSignIn?:
            "\(sourceName) still asks for a sign-in. Finish signing in on the page, then press Done."
        case .pageUnavailable?, nil:
            "SuperVisor couldn't check the sign-in. Press Done to try again."
        }
    }

    /// Ends the sign-in: the browser is closed and syncs may run again.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        browser.close()
        center.signInEnded(self)
        onClosed?()
        onClosed = nil
    }

    private func refreshLocation() {
        let url = browser.committedURL
        let currentHost = url?.host(percentEncoded: false)?.lowercased()
        let secure = url?.scheme?.lowercased() == "https" && browser.webView.hasOnlySecureContent
        if currentHost != host { host = currentHost }
        if secure != isSecure { isSecure = secure }
    }
}

/// The window a person signs in to a direct-message source in.
///
/// **The window's size is the user's.** Its hosting controller carries no sizing options (the
/// hazard `FittedWindow` describes). Closing it by any route ends the sign-in it shows.
@MainActor
final class DirectMessageSignInWindow: NSWindow {
    static let shared = DirectMessageSignInWindow()

    private let hosting: NSHostingController<AnyView>
    private(set) var model: DirectMessageSignInModel?

    init() {
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        super.init(
            contentRect: NSRect(origin: .zero, size: SiteEnrollmentWindow.initialContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        contentViewController = hosting
        // Taking the controller sizes the window to the controller's view; the window's own
        // size is set after.
        setContentSize(SiteEnrollmentWindow.initialContentSize)
        contentMinSize = SiteEnrollmentWindow.minimumContentSize
    }

    /// Shows a fresh sign-in for `center`'s source, ending any shown before.
    func show(center: DirectMessageCenter) {
        let previous = model
        let model = DirectMessageSignInModel(center: center)
        self.model = model
        previous?.close()
        // A sign-in the center ends, as it does when the source is switched off, takes its
        // window with it.
        model.onClosed = { [weak self, weak model] in
            guard let self, let model, self.model === model else { return }
            self.close()
        }
        title = model.title
        hosting.rootView = AnyView(
            DirectMessageSignInView(model: model) { [weak self, weak model] in
                guard let self, let model, self.model === model else { return }
                self.close()
            }
            .id(ObjectIdentifier(model))
        )
        if !isVisible { self.center() }
        makeKeyAndOrderFront(nil)
        // An accessory app is never frontmost by itself.
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.openStartPage() }
    }

    override func close() {
        let ending = model
        model = nil
        ending?.close()
        super.close()
        // A closed window keeps its root view alive; an empty one observes nothing.
        hosting.rootView = AnyView(EmptyView())
    }
}

/// The sign-in window's content: why the person is asked and what is kept, beside the live
/// page, with Done and Cancel.
struct DirectMessageSignInView: View {
    @ObservedObject var model: DirectMessageSignInModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            pane
                .frame(width: ProVisorSiteView.formWidth)
                .frame(maxHeight: .infinity)

            Divider()

            VStack(spacing: 0) {
                SiteLocationBar(host: model.host, isSecure: model.isSecure, isWorking: model.phase == .checking)
                Divider()
                SiteWebViewHost(browser: model.browser)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(NotchTheme.brandColor)
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(DirectMessageSignInModel.instruction)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                status
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // No Return or Escape shortcuts and no default button: those keys belong to the
                // page beside the pane.
                Button("Cancel", action: onClose)
                    .controlSize(.large)
                Button("Done") {
                    Task {
                        if await model.done() { onClose() }
                    }
                }
                .buttonStyle(SiteProminentButtonStyle())
                .disabled(model.phase == .checking)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .signingIn, .finished:
            if model.loadFailed {
                VStack(alignment: .leading, spacing: 6) {
                    Label("The page didn't load.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Try Again") {
                        Task { await model.openStartPage() }
                    }
                    .controlSize(.small)
                }
            }
        case .checking:
            Label("Checking the sign-in…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .notConfirmed(sentence):
            Label(sentence, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
