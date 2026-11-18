import AppKit
import SwiftUI
import WebKit

/// Opens the site window: the Add Site form for a new site, and the sign-in window
/// (`ProVisorSignInView`) for every granted site and for a site a ProVisor proposal asked for.
///
/// One window is reused. Asking for what it already shows brings it forward; asking for
/// anything else ends the enrollment it shows.
@MainActor
final class ProVisorSiteWindow {
    static let shared = ProVisorSiteWindow()

    private var window: SiteEnrollmentWindow?

    private init() {}

    func showAdding(center: SiteAccessCenter) {
        present(.form(.adding), center: center) { SiteFormModel() }
    }

    /// The sites window's Sign In Again for `record`.
    func showSignInAgain(_ record: SiteRecord, center: SiteAccessCenter) {
        center.refresh()
        open(Self.route(forSite: record, requestedBy: nil), center: center)
    }

    /// The review window's button for the site proposal `proposalID` asked for. Saving the site
    /// settles the request (`SignInDemand.effectOfSaving`); closing the window leaves the
    /// proposal as it is.
    func showRequested(
        host: String,
        proposalID: String,
        center: SiteAccessCenter = .shared,
        history: BrowsingHistory = BrowsingHistory()
    ) {
        center.refresh()
        open(
            Self.route(forRequestedHost: host, proposalID: proposalID, grantedSites: center.sites),
            center: center,
            history: history
        )
    }

    /// A sign-in prompt from the banner or the sheet.
    func showSignIn(
        _ item: SignInDemand.Item,
        center: SiteAccessCenter = .shared,
        history: BrowsingHistory = BrowsingHistory()
    ) {
        guard let route = Self.route(for: item) else {
            AppLog.error(.provisor, "sign-in prompt for \(item.host) has no request")
            return
        }
        center.refresh()
        open(route, center: center, history: history)
    }

    /// Which window a sign-in is expected to open, before the stored sign-in is read.
    enum SignInRoute: Equatable {
        /// The sign-in window, for a granted site or a host a proposal asked for.
        case signingIn(host: String, requestedBy: String?)
        /// The Sign In Again form, for a site that keeps a saved password.
        case signingInAgain(siteID: String, requestedBy: String?)

        var host: String {
            switch self {
            case let .signingIn(host, _): host
            case let .signingInAgain(siteID, _): siteID
            }
        }

        var requestedBy: String? {
            switch self {
            case let .signingIn(_, proposalID): proposalID
            case let .signingInAgain(_, proposalID): proposalID
            }
        }
    }

    /// The window for a sign-in prompt: the sign-in window, for a granted site however it is
    /// kept and for a requested host. Nil for a requested host with no proposal, which no
    /// demand produces.
    static func route(for item: SignInDemand.Item) -> SignInRoute? {
        switch item.kind {
        case .signedOut:
            return .signingIn(host: item.host, requestedBy: item.proposalID)
        case .requested:
            guard let proposalID = item.proposalID else { return nil }
            return .signingIn(host: item.host, requestedBy: proposalID)
        }
    }

    /// The window for signing in to a granted site again: the sign-in window, however the site
    /// is kept.
    static func route(forSite record: SiteRecord, requestedBy proposalID: String?) -> SignInRoute {
        .signingIn(host: record.id, requestedBy: proposalID)
    }

    /// The window for a host a proposal asked for: the sign-in window, for a granted site and
    /// for any other host.
    static func route(
        forRequestedHost host: String,
        proposalID: String,
        grantedSites: [SiteRecord]
    ) -> SignInRoute {
        guard let record = grantedSites.first(where: { $0.id == host }) else {
            return .signingIn(host: host, requestedBy: proposalID)
        }
        return route(forSite: record, requestedBy: proposalID)
    }

    /// What a route opens once the site's record and stored sign-in are read.
    enum Opening: Equatable {
        /// The Add Site form, empty.
        case addingSite
        /// The sign-in window.
        case signIn(host: String, requestedBy: String?)
        /// The Sign In Again form, for a grant that keeps a saved password.
        case signingInAgain(grant: SiteGrant, record: SiteRecord, requestedBy: String?)
        /// The Add Site form for a granted site whose stored sign-in cannot be read.
        case unreadable(record: SiteRecord, requestedBy: String?)
    }

    /// Settles `route` against the site's `record` and stored `grant`, which may have changed
    /// since the route was chosen. A granted site with a readable grant opens the sign-in
    /// window, which fills a saved password and never saves a session over it
    /// (`SiteSignInModel.Start.fillsSavedPassword`).
    ///
    /// A granted site whose grant cannot be read opens the Add Site form with its address
    /// empty, whichever route asked: the record comes from `sites.json`, which anything running
    /// as the user can edit, and only the Keychain grant vouches for an address. A site whose
    /// record is gone is added as new, through the sign-in window when a proposal asked for it,
    /// so its request is kept, and through the empty Add Site form otherwise.
    static func opening(for route: SignInRoute, record: SiteRecord?, grant: SiteGrant?) -> Opening {
        let (host, proposalID) = (route.host, route.requestedBy)
        guard let record else {
            return proposalID == nil ? .addingSite : .signIn(host: host, requestedBy: proposalID)
        }
        guard grant != nil else { return .unreadable(record: record, requestedBy: proposalID) }
        return .signIn(host: host, requestedBy: proposalID)
    }

    /// Opens what `route` leads to, from the center's site list as last refreshed.
    private func open(
        _ route: SignInRoute,
        center: SiteAccessCenter,
        history: BrowsingHistory = BrowsingHistory()
    ) {
        let record = center.sites.first { $0.id == route.host }
        let grant = record.flatMap { center.storedGrant(for: $0.id) }
        switch Self.opening(for: route, record: record, grant: grant) {
        case .addingSite:
            present(.form(.adding), center: center) { SiteFormModel() }
        case let .signIn(host, proposalID):
            presentSignIn(host: host, center: center) {
                SiteSignInModel(
                    host: host,
                    record: record,
                    // The history is read now, never taken from when the prompt was raised.
                    start: .decide(host: host, record: record, grant: grant, hasVisited: history.hasVisited),
                    proposalID: proposalID,
                    needsPerson: record.map { $0.needsPerson || center.awaitingSignIn.contains($0.id) } ?? false,
                    offersPasswords: center.offersPasswords,
                    followUps: ProVisorCenter.shared
                )
            }
        case let .signingInAgain(grant, record, proposalID):
            present(.form(.signingInAgain(siteID: record.id)), center: center, requestID: proposalID) {
                SiteFormModel(signingInAgain: grant, record: record, requestedBy: proposalID)
            }
        case let .unreadable(record, proposalID):
            present(.form(.adding), center: center, reusesShownForm: false, requestID: proposalID) {
                SiteFormModel(unreadableSite: record, requestedBy: proposalID)
            }
        }
    }

    private func present(
        _ content: SiteEnrollmentWindow.Content,
        center: SiteAccessCenter,
        reusesShownForm: Bool = true,
        requestID: String? = nil,
        makeModel: () -> SiteFormModel
    ) {
        let window = reusableWindow()
        if !Self.reusesShownForm(
            allowed: reusesShownForm,
            isVisible: window.isVisible,
            shown: window.content,
            shownRequestID: window.requestID,
            content: content,
            requestID: requestID
        ) {
            window.show(center: center, enrollment: center.makeEnrollment(), model: makeModel())
        }
        bringForward(window)
    }

    private func presentSignIn(host: String, center: SiteAccessCenter, makeModel: () -> SiteSignInModel) {
        let window = reusableWindow()
        if !Self.reusesShownForm(
            allowed: true,
            isVisible: window.isVisible,
            shown: window.content,
            shownRequestID: window.requestID,
            content: .signIn(host: host),
            requestID: nil
        ) {
            let model = makeModel()
            window.show(center: center, enrollment: Self.signInEnrollment(for: model, center: center), signIn: model)
        }
        bringForward(window)
    }

    /// The enrollment a sign-in window starts with: one that probes the page however the
    /// sign-in runs, and records what the person types only when the model may offer to keep a
    /// password (`SiteSignInModel.recordsCredentials`).
    static func signInEnrollment(for model: SiteSignInModel, center: SiteAccessCenter) -> SiteEnrollment {
        model.recordsCredentials ? center.makeRecordingEnrollment() : center.makeWatchingEnrollment()
    }

    private func reusableWindow() -> SiteEnrollmentWindow {
        if let window { return window }
        let window = SiteEnrollmentWindow()
        window.center()
        self.window = window
        return window
    }

    private func bringForward(_ window: SiteEnrollmentWindow) {
        window.makeKeyAndOrderFront(nil)
        // An accessory app is never frontmost by itself, and a window in a background app
        // takes no typing.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Whether the window on screen already shows what is asked for: a form in the same mode,
    /// opened for the same request or for none, or the sign-in window for the same site. A
    /// sign-in to a site is answered by saving that site whichever request asked for it, so
    /// the request it was opened for does not matter there.
    static func reusesShownForm(
        allowed: Bool,
        isVisible: Bool,
        shown: SiteEnrollmentWindow.Content?,
        shownRequestID: String?,
        content: SiteEnrollmentWindow.Content,
        requestID: String?
    ) -> Bool {
        guard allowed, isVisible, shown == content else { return false }
        if case .signIn = content { return true }
        return shownRequestID == requestID
    }
}

/// The window a site is added or signed in to in: the form or the sign-in pane on the left, the
/// live page on the right.
///
/// **The window's size is the user's.** The hosting controller carries no sizing options and
/// the content fills whatever frame the window has, so nothing either view shows or hides can
/// resize the window from inside a layout pass (the hazard `FittedWindow` describes).
///
/// Closing it by any route ends the enrollment it shows, which forgets the typed secrets and
/// closes the browser.
@MainActor
final class SiteEnrollmentWindow: NSWindow {
    /// What the window shows.
    enum Content: Equatable {
        /// The Add Site or Sign In Again form.
        case form(SiteFormModel.Mode)
        /// The sign-in window for a site.
        case signIn(host: String)
    }

    static let initialContentSize = NSSize(width: 1040, height: 700)
    static let minimumContentSize = NSSize(width: 900, height: 600)

    private let hosting: NSHostingController<AnyView>
    private(set) var enrollment: SiteEnrollment?
    private(set) var content: Content?
    /// The proposal what is shown was opened from.
    private(set) var requestID: String?

    init() {
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        collectionBehavior = [.moveToActiveSpace]
        contentViewController = hosting
        // Taking the controller sizes the window to the controller's view; the window's own
        // size is set after.
        setContentSize(Self.initialContentSize)
        contentMinSize = Self.minimumContentSize
    }

    /// Shows a fresh form for `enrollment`, ending any enrollment shown before.
    func show(center: SiteAccessCenter, enrollment: SiteEnrollment, model: SiteFormModel) {
        replace(with: enrollment, content: .form(model.mode), requestID: model.request?.proposalID)
        model.follow(enrollment, center: center)
        title = model.isSigningInAgain ? "Sign In Again" : "Add a Site"
        hosting.rootView = AnyView(
            ProVisorSiteView(
                center: center,
                enrollment: enrollment,
                model: model
            ) { [weak self, weak enrollment] in
                guard let enrollment else { return }
                self?.close(showing: enrollment)
            }
            .id(ObjectIdentifier(enrollment))
        )
    }

    /// Shows the sign-in window for `enrollment`, ending any enrollment shown before, and opens
    /// the page at once when the model's start is an address the app vouches for.
    func show(center: SiteAccessCenter, enrollment: SiteEnrollment, signIn model: SiteSignInModel) {
        replace(with: enrollment, content: .signIn(host: model.host), requestID: model.proposalID)
        // An enrollment that ends by itself, as an unanswered offer does, closes its window.
        enrollment.whenEnded { [weak self, weak enrollment] in
            guard let enrollment else { return }
            self?.close(showing: enrollment)
        }
        title = "Sign In"
        hosting.rootView = AnyView(
            ProVisorSignInView(
                center: center,
                enrollment: enrollment,
                model: model
            ) { [weak self, weak enrollment] in
                guard let enrollment else { return }
                self?.close(showing: enrollment)
            }
            .id(ObjectIdentifier(enrollment))
        )
        Task { await model.openStartPage(using: enrollment) }
    }

    private func replace(with enrollment: SiteEnrollment, content: Content, requestID: String?) {
        let previous = self.enrollment
        self.enrollment = enrollment
        self.content = content
        self.requestID = requestID
        previous?.cancel()
    }

    /// Closes the window if it still shows `enrollment`. A save or Cancel that finishes after
    /// the window moved on to another enrollment leaves that one alone.
    func close(showing enrollment: SiteEnrollment) {
        guard self.enrollment === enrollment else { return }
        close()
    }

    override func close() {
        let ending = enrollment
        enrollment = nil
        content = nil
        requestID = nil
        ending?.cancel()
        super.close()
        // A closed window keeps its root view alive; an empty one observes nothing.
        hosting.rootView = AnyView(EmptyView())
    }
}

// MARK: - Content

/// The form beside the live page. Everything it decides is in `SiteFormModel`.
@MainActor
struct ProVisorSiteView: View {
    @ObservedObject var center: SiteAccessCenter
    @ObservedObject var enrollment: SiteEnrollment
    @ObservedObject var model: SiteFormModel
    let onClose: () -> Void

    @FocusState private var focus: SiteFormModel.Field?
    /// What to tell the user once the site is saved, before the window closes.
    @State private var savedNotice: String?

    static let formWidth: CGFloat = 300

    var body: some View {
        HStack(spacing: 0) {
            formPane
                .frame(width: Self.formWidth)
                .frame(maxHeight: .infinity)

            Divider()

            SiteLivePagePane(enrollment: enrollment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(NotchTheme.brandColor)
        .onAppear { center.refresh() }
        // Full Disk Access is granted in System Settings, so the texts status is read again on
        // coming back to the window.
        .onWindowBecomesKey { center.refresh() }
        .alert(
            "Site saved",
            isPresented: Binding(get: { savedNotice != nil }, set: { if !$0 { savedNotice = nil } }),
            presenting: savedNotice
        ) { _ in
            Button("OK", action: onClose)
        } message: { notice in
            Text(notice)
        }
    }

    // MARK: Form

    private var formPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.isSigningInAgain ? "Sign in again" : "Add a site")
                        .font(.title3.weight(.semibold))

                    if let request = model.request {
                        requestLine(request)
                    }

                    if let notice = model.notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    methodChoice
                        .disabled(model.isWorking || model.isSaving)

                    fields
                        .disabled(model.isWorking || model.isSaving)

                    signInSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // No Return or Escape shortcuts: those keys belong to the page beside the form.
                Button("Cancel", action: onClose)
                    .controlSize(.large)
                    .help("Close without saving")
                Button("Save Site") { save() }
                    .buttonStyle(SiteProminentButtonStyle())
                    .disabled(!model.canSave)
                    .help("Save this sign-in so ProVisor can read the site signed in")
            }
            .padding(16)
        }
    }

    /// The line about the ProVisor proposal the form was opened from.
    private func requestLine(_ request: SiteFormModel.Request) -> some View {
        Label(request.message, systemImage: "checkmark.seal")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.disabled)
    }

    /// The two ways of keeping a site, each with what it means. A saved site keeps its own,
    /// which is stated rather than offered.
    @ViewBuilder
    private var methodChoice: some View {
        if model.canChooseMethod {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SiteFormModel.methods, id: \.self) { method in
                    SiteMethodRow(method: method, isSelected: model.method == method) {
                        model.method = method
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.method.title)
                    .font(.callout.weight(.medium))
                caption(model.method.explanation)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        labelled("Site address", problem: model.addressProblem, advice: model.addressAdvice) {
            TextField("my.example.com", text: Binding(get: { model.address }, set: { model.address = $0 }))
                .siteFieldChrome(isFocused: focus == .address)
                .focused($focus, equals: .address)
                .disabled(model.isSigningInAgain)
                .help(
                    model.isSigningInAgain
                        ? "A saved site keeps its address"
                        : "The address you normally type to reach the site; it leads to the sign-in page"
                )
        }

        labelled("Name") {
            TextField("Site name", text: Binding(get: { model.name }, set: { model.name = $0 }))
                .siteFieldChrome(isFocused: focus == .name)
                .focused($focus, equals: .name)
        }

        if model.method == .signsInForMe {
            credentialFields
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        labelled("User name") {
            TextField("", text: $model.username)
                .textContentType(.username)
                .siteFieldChrome(isFocused: focus == .username)
                .focused($focus, equals: .username)
        }

        labelled("Password") {
            SecureField(model.isSigningInAgain ? "Saved password" : "", text: $model.password)
                .textContentType(.password)
                .siteFieldChrome(isFocused: focus == .password)
                .focused($focus, equals: .password)
        }

        labelled("Sign-in code") {
            Picker("Sign-in code", selection: $model.codeKind) {
                ForEach(SiteFormModel.codeKinds, id: \.self) { kind in
                    Text(SiteFormModel.title(of: kind)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .help("How the site sends the extra code it asks for after the password")
        }

        codeDetails
    }

    @ViewBuilder
    private var codeDetails: some View {
        switch model.codeKind {
        case .none:
            EmptyView()
        case .authenticator:
            labelled("Setup key", problem: model.authenticatorKeyProblem) {
                SecureField(
                    model.hasSavedAuthenticatorKey ? "Saved key" : "Setup key or otpauth:// link",
                    text: $model.authenticatorKey
                )
                .siteFieldChrome(isFocused: focus == .authenticatorKey)
                .focused($focus, equals: .authenticatorKey)
            }
            if model.isAuthenticatorKeyAccepted {
                Label("Key accepted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                caption("The key or link the site showed when you set up an authenticator app for it.")
            }
        case .text:
            caption("SuperVisor learns which number the codes come from during this sign-in and shows it here.")
            textsWarning
        case .email:
            labelled("Sent from", problem: model.codeSenderProblem) {
                TextField("codes@example.com", text: $model.codeSender)
                    .siteFieldChrome(isFocused: focus == .codeSender)
                    .focused($focus, equals: .codeSender)
            }
            caption("The address the code emails come from.")
        }
    }

    private var textsWarning: some View {
        SiteTextsWarning(status: model.textsStatus, center: center)
    }

    // MARK: Signing in

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                switch model.method {
                case .keepsSession:
                    Button("Open Page", action: openPage)
                        .controlSize(.large)
                        .disabled(!model.canOpenPage)
                        .help("Open the sign-in page for you to sign in on")
                case .signsInForMe:
                    Button("Sign In", action: signIn)
                        .controlSize(.large)
                        .disabled(!model.canSignIn)
                        .help("Open the sign-in page and fill in what you typed")
                }
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let fill = enrollment.unvettedFill {
                Text(SiteFormModel.movedMessage(fill))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let note = enrollment.note {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let sender = enrollment.learnedCodeSender {
                Label("Codes come from \(sender)", systemImage: "message")
                    .font(.callout)
            }

            if let problem = model.problem {
                Text(problem.message)
                    .font(.callout)
                    .foregroundStyle(model.offersSaveAnyway ? .orange : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.offersSaveAnyway {
                Button("Save Anyway") { save(confirmingSignIn: true) }
                    .help("Save this page as signed in, on your own word that it shows your account")
            }

            if let blocker = model.saveBlocker {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            caption("You can type directly in the page to finish anything SuperVisor could not.")
        }
    }

    private func signIn() {
        focus = nil
        Task { await model.signIn(using: enrollment) }
    }

    private func openPage() {
        focus = nil
        Task { await model.openPage(using: enrollment) }
    }

    private func save(confirmingSignIn: Bool = false) {
        Task {
            switch await model.save(
                using: enrollment,
                into: center,
                confirmingSignIn: confirmingSignIn
            ) {
            case .notSaved:
                break
            case .saved:
                onClose()
            case let .savedWithNotice(notice):
                savedNotice = notice
            }
        }
    }

    // MARK: Pieces

    private func labelled<Content: View>(
        _ label: String,
        problem: String? = nil,
        advice: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let advice {
                Text(advice)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One way of keeping a site: a radio mark in the brand gradient, its name, and what it means.
private struct SiteMethodRow: View {
    let method: SiteFormModel.Method
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(NotchTheme.brandGradient) : AnyShapeStyle(.secondary)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(.callout.weight(.medium))
                    Text(method.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
