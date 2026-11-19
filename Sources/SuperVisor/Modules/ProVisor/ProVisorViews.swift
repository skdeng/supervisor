import SwiftUI

/// What a proposal's row is showing: the file's status, overlaid with what the app is doing
/// about it right now.
enum ProposalRowState: Equatable {
    case open
    case failed
    case queued
    case working
    case done

    static func of(
        _ proposal: Proposal,
        actingID: String?,
        queuedIDs: [String]
    ) -> ProposalRowState {
        if actingID == proposal.id { return .working }
        if queuedIDs.contains(proposal.id) { return .queued }
        switch proposal.status {
        case .done:
            return .done
        case .failed:
            return .failed
        case .proposed, .dismissed, .withdrawn:
            return .open
        }
    }
}

/// ProVisor's section: the sites waiting on the person's sign-in, then the proposals awaiting
/// a decision, then those just carried out.
///
/// A proposal whose request a sign-in row stands for (`SignInDemand.coveredProposalIDs`) is
/// folded into that row, which opens its review and carries its Dismiss, so one site never
/// asks twice.
@MainActor
struct ProVisorSectionView: View {
    @ObservedObject var center: ProVisorCenter
    /// Opens the review window on a proposal.
    let onReview: (String) -> Void
    /// Opens the window to sign in to a site.
    let onSignIn: (SignInDemand.Item) -> Void

    /// Whether the rows past the first few are showing. Resets with the sheet, which is built
    /// only while it is expanded or hovered, so each list opens folded every time.
    @State private var showsMoreSignIns = false
    @State private var showsMoreProposals = false

    var body: some View {
        // Expiry is wall-clock: a proposal can leave the queue without any file changing.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let prompts = center.signInPrompts
            let covered = SignInDemand.coveredProposalIDs(prompts)
            let visible = ProposalQueue.visible(center.proposals, now: context.date)
                .filter { !covered.contains($0.id) }

            VStack(alignment: .leading, spacing: 8) {
                FoldedList(items: prompts, showsMore: $showsMoreSignIns) { item in
                    signInRow(item)
                }
                FoldedList(items: visible, showsMore: $showsMoreProposals) { proposal in
                    row(proposal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func signInRow(_ item: SignInDemand.Item) -> some View {
        ProVisorSignInRow(
            item: item,
            onSignIn: { onSignIn(item) },
            onReview: item.proposalID.map { id in { onReview(id) } },
            onPostpone: {
                center.postponeSignIn(item)
            }
        )
    }

    private func row(_ proposal: Proposal) -> some View {
        ProVisorRow(
            proposal: proposal,
            state: ProposalRowState.of(
                proposal,
                actingID: center.actingID,
                queuedIDs: center.queuedIDs
            ),
            onOpen: {
                onReview(proposal.id)
            }
        )
    }
}

/// A list that shows its first `ProposalQueue.leadCount` rows and folds the rest behind a count.
@MainActor
private struct FoldedList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @Binding var showsMore: Bool
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ForEach(items.prefix(ProposalQueue.leadCount)) { item in
            row(item)
        }

        let rest = Array(items.dropFirst(ProposalQueue.leadCount))
        if !rest.isEmpty {
            foldToggle(count: rest.count)

            if showsMore {
                ForEach(rest) { item in
                    row(item)
                }
            }
        }
    }

    private func foldToggle(count: Int) -> some View {
        Button {
            showsMore.toggle()
        } label: {
            HStack(spacing: 5) {
                Text("\(count) more")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                Image(systemName: showsMore ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A site waiting on the person's sign-in. Its text opens the review of the proposal that asked
/// for it, when one did. A granted site can be put off; a requested one is declined in that
/// review, where the request can be read first.
@MainActor
private struct ProVisorSignInRow: View {
    let item: SignInDemand.Item
    let onSignIn: () -> Void
    let onReview: (() -> Void)?
    let onPostpone: () -> Void

    var body: some View {
        HStack(spacing: NotchTheme.rowMarkerGap) {
            ProVisorSignInMarker(size: NotchTheme.rowMarkerWidth)

            if let onReview {
                Button(action: onReview) {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .notchTooltip("Review")
                .help("Review")
            } else {
                label
            }

            ProVisorCapsuleButton(
                title: "Sign In",
                isProminent: true,
                tooltip: ProVisorSignInText.tooltip(item),
                action: onSignIn
            )

            if case .signedOut = item.kind {
                ProVisorTextButton(
                    title: "Not now",
                    tooltip: "Hide until ProVisor next needs this site",
                    action: onPostpone
                )
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: ProVisorSignInText.title(item))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(NotchTheme.primaryForeground)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(ProVisorSignInText.reason(item))
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The words a sign-in prompt is shown with. A site's name is the person's own or a validated
/// host, and is always set as verbatim text, never parsed as markdown.
enum ProVisorSignInText {
    static func title(_ item: SignInDemand.Item) -> String {
        "Sign in to \(item.displayName)"
    }

    /// Why the site waits. Only a kept session whose record is flagged is known to have signed
    /// the person out; a site can also wait because its start page moved or a run was turned
    /// away from it.
    static func reason(_ item: SignInDemand.Item) -> String {
        switch item.kind {
        case .signedOut(keepsSession: true):
            return item.needsPerson ? "It signed you out" : "It needs you to sign in again"
        case .signedOut(keepsSession: false):
            return "SuperVisor couldn't sign in by itself"
        case .requested:
            return "ProVisor asked for this site"
        }
    }

    static func more(_ count: Int) -> String? {
        count > 0 ? "and \(count) more" : nil
    }

    static func tooltip(_ item: SignInDemand.Item) -> String {
        "Open \(item.displayName) to sign in"
    }
}

/// The key a sign-in prompt leads with, in the brand.
@MainActor
private struct ProVisorSignInMarker: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "key.fill")
            .font(.system(size: size * 0.72, weight: .semibold))
            .foregroundStyle(NotchTheme.brandGradient)
            .frame(width: size, height: size)
    }
}

/// One proposal: what it would achieve and the evidence for it. A click on its text opens the
/// review window, and the row does nothing else: approving and dismissing both happen there,
/// where the proposal can be read first. Approval lives where the action is
/// spelled out in full, so what runs is always something the user had in front of them.
@MainActor
private struct ProVisorRow: View {
    let proposal: Proposal
    let state: ProposalRowState
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: NotchTheme.rowMarkerGap) {
            ProVisorMarker(state: state, size: NotchTheme.rowMarkerWidth)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(NotchTheme.primaryForeground)
                        .lineLimit(1)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .notchTooltip("Review")
            .help("Review")
        }
    }

    private var detail: String {
        switch state {
        case .open:
            return proposal.why ?? proposal.recommended.action
        case .queued:
            return "Queued"
        case .working:
            return "Working…"
        case .done:
            let label = proposal.isAutomatic ? "Done automatically" : "Done"
            return proposal.result.map { "\(label) · \($0)" } ?? label
        case .failed:
            return proposal.result.map { "Couldn't finish · \($0)" } ?? "Couldn't finish"
        }
    }
}

/// The row's leading mark. An idea wears the brand; a finished one is green and a failed one
/// red, matching how an agent session's outcome reads in the section beside it.
@MainActor
private struct ProVisorMarker: View {
    let state: ProposalRowState
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.72, weight: .semibold))
            .foregroundStyle(style)
            .symbolEffect(.pulse, isActive: state == .working)
            .frame(width: size, height: size)
    }

    private var symbol: String {
        switch state {
        case .open, .queued, .working:
            return "sparkles"
        case .done:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var style: AnyShapeStyle {
        switch state {
        case .open, .working:
            return AnyShapeStyle(NotchTheme.brandGradient)
        case .queued:
            return AnyShapeStyle(NotchTheme.secondaryForeground)
        case .done:
            return AnyShapeStyle(Color.green)
        case .failed:
            return AnyShapeStyle(Color.red)
        }
    }
}

/// ProVisor's banner: a site to sign in to, or the count of proposals a pass added.
@MainActor
struct ProVisorPeekBannerView: View {
    @ObservedObject var module: ProVisorModule

    var body: some View {
        switch module.announcement {
        case let .ideas(count):
            ProVisorIdeasBanner(count: count) {
                module.review()
            }
        case let .signIn(item, more, _):
            ProVisorSignInBanner(item: item, more: more) {
                module.signIn(item)
            }
        case nil:
            EmptyView()
        }
    }
}

/// The notice a pass raises when it adds proposals. It carries a count and nothing else: a
/// proposal's text is drawn from the user's mail, and the pill is on screen over every window,
/// so that text stays in the sheet the user chose to open.
@MainActor
private struct ProVisorIdeasBanner: View {
    let count: Int
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NotchTheme.brandGradient)
                .frame(
                    width: NotchTheme.compactContentHeight,
                    height: NotchTheme.compactContentHeight
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("ProVisor")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .lineLimit(1)

                Text(count == 1 ? "1 new idea" : "\(count) new ideas")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .lineLimit(1)
            }

            // The pill can be wider than the banner needs, so the action pins to the
            // trailing content edge.
            Spacer(minLength: 12)

            ProVisorIconButton(systemName: "chevron.down", tooltip: "Review", action: onReview)
        }
    }
}

/// The notice for a site waiting on the person's sign-in: the site's name, how many others are
/// waiting, and one button that opens it. The name is the person's own for a granted site, or a
/// host their own browsers have visited (`SignInDemand.Item.isAnnounceable`).
@MainActor
private struct ProVisorSignInBanner: View {
    let item: SignInDemand.Item
    let more: Int
    let onSignIn: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProVisorSignInMarker(size: NotchTheme.compactContentHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: ProVisorSignInText.title(item))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let more = ProVisorSignInText.more(more) {
                    Text(more)
                        .font(.caption)
                        .foregroundStyle(NotchTheme.secondaryForeground)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 280, alignment: .leading)

            // The pill can be wider than the banner needs, so the action pins to the trailing
            // content edge.
            Spacer(minLength: 12)

            ProVisorCapsuleButton(
                title: "Sign In",
                isProminent: true,
                tooltip: ProVisorSignInText.tooltip(item),
                action: onSignIn
            )
        }
    }
}

@MainActor
private struct ProVisorIconButton: View {
    let systemName: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: NotchTheme.rowActionSize, height: NotchTheme.rowActionSize)
                .foregroundStyle(NotchTheme.primaryForeground)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTooltip(tooltip)
        .help(tooltip)
    }
}

/// A small text control in the row's secondary color, for an action that sets something aside.
@MainActor
private struct ProVisorTextButton: View {
    let title: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .lineLimit(1)
                .fixedSize()
                .frame(height: NotchTheme.rowActionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchTooltip(tooltip)
        .help(tooltip)
    }
}

@MainActor
struct ProVisorCapsuleButton: View {
    let title: String
    var isProminent = false
    var isEnabled = true
    /// A hover label for the notch surface, which shows no native tooltip. Windows leave it
    /// nil and get the system's help tag with the title.
    var tooltip: String?
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            // One line whatever the title, so a button never grows its window taller.
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(fill))
                .foregroundStyle(.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)

        if let tooltip {
            button.notchTooltip(tooltip).help(tooltip)
        } else {
            button.help(title)
        }
    }

    private var fill: AnyShapeStyle {
        isProminent
            ? AnyShapeStyle(NotchTheme.brandGradient)
            : AnyShapeStyle(Color.white.opacity(0.10))
    }
}
