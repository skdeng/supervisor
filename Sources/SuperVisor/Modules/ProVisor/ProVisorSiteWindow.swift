import AppKit
import SwiftUI
import WebKit

/// Opens the Add Site window, for a new site or to sign in to a saved one again.
///
/// One window is reused. Asking for the sign-in it already shows brings it forward; asking for
/// another ends the one it shows.
@MainActor
final class ProVisorSiteWindow {
    static let shared = ProVisorSiteWindow()

    private var window: SiteEnrollmentWindow?

    private init() {}

    func showAdding(center: SiteAccessCenter) {
        present(.adding, center: center) { SiteFormModel() }
    }

    /// Opens the window on a saved site. A site whose grant cannot be read opens as a new one,
    /// saying so.
    func showSigningInAgain(_ siteID: String, center: SiteAccessCenter) {
        guard let record = center.sites.first(where: { $0.id == siteID }) else {
            showAdding(center: center)
            return
        }
        guard let grant = center.storedGrant(for: siteID) else {
            present(.adding, center: center, reusesShownForm: false) {
                SiteFormModel(unreadableSite: record)
            }
            return
        }
        present(.signingInAgain(siteID: siteID), center: center) {
            SiteFormModel(signingInAgain: grant, record: record)
        }
    }

    private func present(
        _ mode: SiteFormModel.Mode,
        center: SiteAccessCenter,
        reusesShownForm: Bool = true,
        makeModel: () -> SiteFormModel
    ) {
        let window = self.window ?? SiteEnrollmentWindow()
        if self.window == nil {
            window.center()
            self.window = window
        }
        if !reusesShownForm || !window.isVisible || window.mode != mode {
            window.show(center: center, enrollment: center.makeEnrollment(), model: makeModel())
        }
        window.makeKeyAndOrderFront(nil)
        // An accessory app is never frontmost by itself, and a window in a background app
        // takes no typing.
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The window a site is added in: the form on the left, the live page on the right.
///
/// **The window's size is the user's.** The hosting controller carries no sizing options and
/// the content fills whatever frame the window has, so nothing the form shows or hides can
/// resize the window from inside a layout pass (the hazard `FittedWindow` describes).
///
/// Closing it by any route ends the enrollment it shows, which forgets the typed secrets and
/// closes the browser.
@MainActor
final class SiteEnrollmentWindow: NSWindow {
    static let initialContentSize = NSSize(width: 1040, height: 700)
    static let minimumContentSize = NSSize(width: 900, height: 600)

    private let hosting: NSHostingController<AnyView>
    private(set) var enrollment: SiteEnrollment?
    private(set) var mode: SiteFormModel.Mode?

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
        let previous = self.enrollment
        self.enrollment = enrollment
        mode = model.mode
        previous?.cancel()
        model.follow(enrollment, center: center)
        title = model.isSigningInAgain ? "Sign In Again" : "Add a Site"
        hosting.rootView = AnyView(
            ProVisorSiteView(center: center, enrollment: enrollment, model: model) { [weak self, weak enrollment] in
                guard let enrollment else { return }
                self?.close(showing: enrollment)
            }
            .id(ObjectIdentifier(enrollment))
        )
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
        mode = nil
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

                    if let notice = model.notice {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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
                Button("Save Site", action: save)
                    .buttonStyle(SiteProminentButtonStyle())
                    .disabled(!model.canSave)
                    .help("Save this sign-in so ProVisor can read the site signed in")
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var fields: some View {
        labelled("Sign-in page address", problem: model.addressProblem) {
            TextField("my.example.com/login", text: Binding(get: { model.address }, set: { model.address = $0 }))
                .siteFieldChrome(isFocused: focus == .address)
                .focused($focus, equals: .address)
                .disabled(model.isSigningInAgain)
                .help(model.isSigningInAgain ? "A saved site keeps its address" : "The address of the page you sign in on")
        }

        labelled("Name") {
            TextField("Site name", text: Binding(get: { model.name }, set: { model.name = $0 }))
                .siteFieldChrome(isFocused: focus == .name)
                .focused($focus, equals: .name)
        }

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

    @ViewBuilder
    private var textsWarning: some View {
        switch model.textsStatus {
        case .on:
            EmptyView()
        case .off:
            warning("Texts are off, so SuperVisor can't read the code.") {
                Button("Turn On Texts") { center.setTextsEnabled(true) }
                    .help("Let SuperVisor read your texts")
            }
        case .accessDenied:
            warning("Full Disk Access is off, so texts can't be read.") {
                Button("Open System Settings") { SiteAccessCenter.openFullDiskAccessSettings() }
                    .help("Open Privacy & Security › Full Disk Access")
            }
        }
    }

    // MARK: Signing in

    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Sign In", action: signIn)
                    .controlSize(.large)
                    .disabled(!model.canSignIn)
                    .help("Open the sign-in page and fill in what you typed")
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
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func save() {
        Task {
            switch await model.save(using: enrollment, into: center) {
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
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            action()
                .controlSize(.small)
        }
    }
}

/// Where the page is: its host behind a padlock, or a red warning when the page is not fully
/// secure. It is always on screen, so the user can see they are on the real site before a
/// password goes into it.
private struct SiteLocationBar: View {
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
private struct SiteWebViewHost: NSViewRepresentable {
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
private struct SiteProminentButtonStyle: ButtonStyle {
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

private extension View {
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
