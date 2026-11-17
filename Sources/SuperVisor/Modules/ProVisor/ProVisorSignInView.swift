import SwiftUI

/// The sign-in window's content: a title, why the person is asked, and the live page, with
/// Done and Cancel. Everything it decides is in `SiteSignInModel`.
///
/// Only Done succeeding, Cancel, or the window's close button closes it; a page that looks
/// signed in (`SiteEnrollment.appearsSignedIn`) only makes Done prominent, since a sign-in can
/// pass through pages that look finished.
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

                    if model.asksForAddress {
                        addressField
                    }

                    status

                    Text(SiteSignInModel.instruction)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                // No Return or Escape shortcuts: those keys belong to the page beside the pane.
                Button("Cancel", action: onClose)
                    .controlSize(.large)
                    .help("Close without saving")
                doneButton
            }
            .padding(16)
        }
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
        // The enrollment's own "sign in on the page" note names a Save button this window
        // does not have; the caption below says the same for Done.
        if let note = enrollment.note, note != SiteEnrollment.Notes.signInYourself {
            Text(note)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
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
