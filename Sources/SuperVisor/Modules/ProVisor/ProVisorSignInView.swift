import SwiftUI

/// The sign-in window's content: a title, why the person is asked, and the live page, with
/// Done and Cancel. Everything it decides is in `SiteSignInModel`.
///
/// Only Done succeeding with nothing more to ask, Cancel, or the window's close button closes
/// it; a page that looks signed in (`SiteEnrollment.appearsSignedIn`) only makes Done
/// prominent, since a sign-in can pass through pages that look finished. Once Done has
/// something to ask or say, a panel (`SiteSignInModel.panel`) takes the place of the status
/// and the buttons, and the window closes only on the person's answer.
@MainActor
struct ProVisorSignInView: View {
    @ObservedObject var center: SiteAccessCenter
    @ObservedObject var enrollment: SiteEnrollment
    @ObservedObject var model: SiteSignInModel
    let onClose: () -> Void

    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            pane
                .frame(width: ProVisorSiteView.formWidth)
                .frame(maxHeight: .infinity)

            Divider()

            SiteLivePagePane(enrollment: enrollment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(NotchTheme.brandColor)
        // Full Disk Access is granted in System Settings, so the texts status is read again on
        // coming back to the window.
        .onWindowBecomesKey { center.refresh() }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(model.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let sentence = model.sentence {
                        sentenceLine(sentence)
                    }

                    if let panel = model.panel {
                        panelContent(panel)
                    } else {
                        if model.asksForAddress {
                            addressField
                        }

                        status

                        Text(SiteSignInModel.instruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if model.recordsCredentials {
                            Text(SiteSignInModel.recordingCaption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // No Return or Escape shortcuts and no default button: those keys belong to the
                // page beside the pane, and no answer about a password is given by a keystroke.
                if let panel = model.panel {
                    panelButtons(panel)
                } else {
                    Button("Cancel", action: onClose)
                        .controlSize(.large)
                        .help("Close without saving")
                    doneButton
                }
            }
            .padding(16)
        }
    }

    // MARK: The password panel

    @ViewBuilder
    private func panelContent(_ panel: SiteSignInModel.Panel) -> some View {
        switch panel {
        case let .offer(siteName, username, host):
            VStack(alignment: .leading, spacing: 12) {
                Text(SiteSignInModel.offerQuestion(siteName: siteName))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                typedPasswordDetails(username: username, host: host)
            }
        case let .refused(refusal):
            if let sentence = refusal.sentence {
                refusalLine(sentence)
            }
        case let .replacement(_, username, host):
            VStack(alignment: .leading, spacing: 12) {
                Text(SiteSignInModel.replacementQuestion)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                typedPasswordDetails(username: username, host: host)
            }
        case let .savedPasswordKept(refusal):
            signedInLines(refusal: refusal, message: SiteSignInModel.savedPasswordKeptMessage)
        case let .savedPasswordTurnedAway(refusal):
            signedInLines(refusal: refusal, message: SiteSignInModel.savedPasswordTurnedAwayMessage)
        }
    }

    /// Why a typed password was not kept, when one was, above what became of the sign-in.
    private func signedInLines(refusal: OfferRefusal?, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sentence = refusal?.sentenceBesideSavedPassword {
                refusalLine(sentence)
            }
            Label(message, systemImage: "checkmark.circle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refusalLine(_ sentence: String) -> some View {
        Label(sentence, systemImage: "key.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The user name as typed and the host the password was typed on, with the problem a failed
    /// keep left.
    @ViewBuilder
    private func typedPasswordDetails(username: String?, host: String) -> some View {
        offerDetail("User name") {
            Text(username ?? SiteSignInModel.noUsernameTyped)
                .foregroundStyle(username == nil ? .secondary : .primary)
        }
        offerDetail("Typed on") {
            // The host as the location bar shows it: plain text that cannot be selected.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text(host)
                    .fontWeight(.medium)
            }
        }
        if let problem = model.problem {
            Text(problem.signInWindowMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func offerDetail<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.disabled)
        }
    }

    @ViewBuilder
    private func panelButtons(_ panel: SiteSignInModel.Panel) -> some View {
        switch panel {
        case .offer:
            Button("Session Only", action: onClose)
                .controlSize(.large)
                .help("Keep the session only; SuperVisor forgets the password")
            Button("Keep Password", action: keepPassword)
                .controlSize(.large)
                .help("Keep the password in your Keychain so SuperVisor can sign in by itself")
        case .refused:
            Button("Close", action: onClose)
                .controlSize(.large)
                .help("Close; the session is saved")
        case .replacement:
            Button("Leave As Is", action: leaveAsIs)
                .controlSize(.large)
                .disabled(model.isWorking)
                .help("Keep the saved password as it is; SuperVisor forgets the one you typed")
            Button("Keep Typed Password", action: keepTypedPassword)
                .controlSize(.large)
                .disabled(model.isWorking)
                .help("Keep the password you typed in your Keychain in place of the saved one")
        case .savedPasswordKept, .savedPasswordTurnedAway:
            Button("Close", action: onClose)
                .controlSize(.large)
                .help("Close; the saved password is kept")
        }
    }

    private func keepPassword() {
        if model.keepPassword(using: enrollment, into: center) == .kept {
            onClose()
        }
    }

    private func keepTypedPassword() {
        if model.keepTypedPassword(using: enrollment, into: center) == .kept {
            onClose()
        }
    }

    private func leaveAsIs() {
        Task { _ = await model.leaveAsIs(using: enrollment, into: center) }
    }

    /// Why the person is asked. A host in it is plain text that cannot be selected, so it is
    /// never a link and never copied into the address.
    private func sentenceLine(_ sentence: String) -> some View {
        Label(
            sentence,
            systemImage: model.sentenceIsCaution ? "exclamationmark.triangle.fill" : "person.crop.circle"
        )
        .font(.callout)
        .foregroundStyle(model.sentenceIsCaution ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.disabled)
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Site address")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("my.example.com", text: $model.address)
                .siteFieldChrome(isFocused: addressFocused)
                .focused($addressFocused)
                .disabled(model.isWorking)
                .help("The address you normally type to reach the site; it leads to the sign-in page")
            if let problem = model.addressProblem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Page", action: openTypedAddress)
                .controlSize(.large)
                .disabled(!model.canOpenTypedAddress)
                .help("Open the sign-in page for you to sign in on")
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let fill = enrollment.unvettedFill {
            Text(SiteSignInModel.movedMessage(fill))
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let note = SiteSignInModel.windowNote(enrollment.note) {
            Text(note)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let sender = enrollment.learnedCodeSender {
            Label("Codes come from \(sender)", systemImage: "message")
                .font(.callout)
        }

        if model.readsTextedCodes {
            SiteTextsWarning(status: center.textsStatus, center: center)
        }

        if let problem = model.problem {
            VStack(alignment: .leading, spacing: 6) {
                Text(problem.signInWindowMessage)
                    .font(.callout)
                    .foregroundStyle(model.offersSaveAnyway ? .orange : .red)
                    .fixedSize(horizontal: false, vertical: true)
                if model.offersSaveAnyway {
                    Button("Save Anyway") { done(confirmingSignIn: true) }
                        .help("Save this page as signed in, on your own word that it shows your account")
                }
                if model.offersRetry {
                    Button("Try Again") { Task { await model.retry(using: enrollment) } }
                        .help("Open the sign-in page again")
                }
            }
        }
    }

    @ViewBuilder
    private var doneButton: some View {
        if enrollment.appearsSignedIn {
            Button("Done") { done() }
                .buttonStyle(SiteProminentButtonStyle())
                .disabled(!model.canPressDone)
                .help("Save this sign-in so ProVisor can read the site signed in")
        } else {
            Button("Done") { done() }
                .controlSize(.large)
                .disabled(!model.canPressDone)
                .help("Save this sign-in so ProVisor can read the site signed in")
        }
    }

    private func openTypedAddress() {
        addressFocused = false
        Task { await model.openTypedAddress(using: enrollment) }
    }

    private func done(confirmingSignIn: Bool = false) {
        Task {
            if await model.done(using: enrollment, into: center, confirmingSignIn: confirmingSignIn) == .saved {
                onClose()
            }
        }
    }
}
