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

/// ProVisor's section: the proposals awaiting a decision, then those just carried out.
@MainActor
struct ProVisorSectionView: View {
    @ObservedObject var center: ProVisorCenter
    /// Opens the review window on a proposal.
    let onReview: (String) -> Void

    /// Whether the proposals past the first few are showing. Resets with the sheet, which is
    /// built only while it is expanded or hovered, so the queue opens folded every time.
    @State private var showsMore = false

    var body: some View {
        // Expiry is wall-clock: a proposal can leave the queue without any file changing.
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let visible = ProposalQueue.visible(center.proposals, now: context.date)
            let lead = Array(visible.prefix(ProposalQueue.leadCount))
            let rest = Array(visible.dropFirst(ProposalQueue.leadCount))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(lead) { proposal in
                    row(proposal)
                }

                if !rest.isEmpty {
                    foldToggle(count: rest.count)

                    if showsMore {
                        ForEach(rest) { proposal in
                            row(proposal)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            },
            onDismiss: {
                center.dismiss(proposal.id)
            }
        )
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

/// One proposal: what it would achieve and the evidence for it. The row opens the review
/// window and can dismiss; it deliberately cannot approve. Approval lives where the action is
/// spelled out in full, so what runs is always something the user had in front of them.
@MainActor
private struct ProVisorRow: View {
    let proposal: Proposal
    let state: ProposalRowState
    let onOpen: () -> Void
    let onDismiss: () -> Void

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
            .help("Review")

            // A proposal being carried out can be neither reviewed into a second approval nor
            // dismissed out from under its run.
            if state != .working, state != .queued {
                ProVisorIconButton(systemName: "chevron.right", tooltip: "Review", action: onOpen)
                ProVisorIconButton(
                    systemName: "xmark",
                    tooltip: state == .done ? "Clear" : "Dismiss",
                    action: onDismiss
                )
            }
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

/// The notice a scouting pass raises when it adds proposals. It carries a count and nothing
/// else: a proposal's text is drawn from the user's mail, and the pill is on screen over every
/// window, so that text stays in the sheet the user chose to open.
@MainActor
struct ProVisorPeekBannerView: View {
    @ObservedObject var module: ProVisorModule

    var body: some View {
        if let count = module.announcedCount {
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

                ProVisorIconButton(systemName: "chevron.down", tooltip: "Review") {
                    module.review()
                }
            }
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

@MainActor
struct ProVisorCapsuleButton: View {
    let title: String
    var isProminent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(fill))
                .foregroundStyle(.white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(title)
    }

    private var fill: AnyShapeStyle {
        isProminent
            ? AnyShapeStyle(NotchTheme.brandGradient)
            : AnyShapeStyle(Color.white.opacity(0.10))
    }
}
