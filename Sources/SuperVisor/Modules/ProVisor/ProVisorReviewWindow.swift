import AppKit
import SwiftUI

/// Why a decision on a proposal was not taken.
enum DecisionRefusal: Equatable {
    /// The copy on file is no longer the one the review window displayed.
    case changed
    /// It can no longer be decided: settled, expired, already being carried out, or ProVisor
    /// is switched off.
    case unavailable
    /// The decision could not be written into the proposal's file.
    case notSaved
}

/// The review window's decisions that depend on no view.
enum ProposalReview {
    static let acceptedOffer = "accepted"
    static let declinedOffer = "declined"

    /// The instruction a run is given from what the user typed. Nil when nothing usable was
    /// typed or it runs past the limit: the text is never shortened.
    static func instruction(from typed: String) -> String? {
        Proposal.typedText(typed, limit: Proposal.actionLimit)
    }

    /// How many characters past the limit the typed text runs, or zero.
    static func overflow(of typed: String) -> Int {
        let length = Proposal.typedText(typed, limit: .max)?.count ?? 0
        return max(0, length - Proposal.actionLimit)
    }

    /// Why a decision on `displayed` cannot be taken now, or nil when it can.
    ///
    /// The review window stays open while scouting passes run, and the scout can rewrite a
    /// proposal's file. A decision therefore counts only for the exact copy that was on
    /// screen: one that no longer equals the copy on file would run text the user never saw.
    static func refusal(
        displayed: Proposal,
        onFile: Proposal?,
        isBusy: Bool,
        isActive: Bool,
        now: Date
    ) -> DecisionRefusal? {
        guard isActive, !isBusy, let onFile else { return .unavailable }
        guard onFile == displayed else { return .changed }
        guard onFile.isOpen, !isExpired(onFile, now: now) else { return .unavailable }
        return nil
    }

    static func isExpired(_ proposal: Proposal, now: Date) -> Bool {
        proposal.expires.map { $0 <= now } ?? false
    }

    /// The answer to record for a rule the proposal offered. An offer goes with the
    /// recommended option, so only a decision on that option answers it; any other choice
    /// leaves it unanswered.
    static func standingDecision(
        for proposal: Proposal,
        optionIndex: Int,
        always: Bool
    ) -> String? {
        guard optionIndex == 0, proposal.standingOffer != nil else { return nil }
        return always ? acceptedOffer : declinedOffer
    }

    /// Whether the offered rule can be accepted from the current selection.
    static func showsOffer(_ offer: StandingOffer?, optionIndex: Int, isCustom: Bool) -> Bool {
        offer != nil && optionIndex == 0 && !isCustom
    }

    /// Beside an offered rule the plain approval says what it is: this once, not from now on.
    static func approveTitle(isRetry: Bool, showsOffer: Bool) -> String {
        if isRetry { return "Try Again" }
        return showsOffer ? "Just Once" : "Do It"
    }

    /// What to say in place of the choices when a proposal is past deciding.
    static func closedReason(_ proposal: Proposal, now: Date) -> String? {
        switch proposal.status {
        case .dismissed:
            return "You dismissed this proposal."
        case .withdrawn:
            return "ProVisor withdrew this proposal because it stopped applying."
        case .proposed, .failed:
            return isExpired(proposal, now: now) ? "This proposal has expired." : nil
        case .done:
            return nil
        }
    }
}

/// The window a proposal is reviewed and decided in.
///
/// It is an ordinary window because deciding can involve typing, and the notch panel never
/// takes keyboard focus. One window is reused; each showing starts from a fresh view, so a
/// selection or half-typed instruction never carries over to another proposal.
@MainActor
final class ProVisorReviewWindow {
    static let shared = ProVisorReviewWindow()

    private var window: FittedWindow?

    private init() {}

    func show(_ id: String, center: ProVisorCenter) {
        let root = AnyView(
            ProVisorReviewView(center: center, id: id) { [weak self] in
                self?.close()
            }
            .id(UUID())
        )

        if let window {
            window.setContent(root)
        } else {
            let window = FittedWindow(width: ProVisorReviewView.width, content: root)
            window.title = "ProVisor"
            // The review is drawn in the sheet's palette, light text on a dark ground.
            window.appearance = NSAppearance(named: .darkAqua)
            window.collectionBehavior = [.moveToActiveSpace]
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        // An accessory app is never frontmost by itself, and a window in a background app
        // takes no typing.
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        // A closed window keeps its root view alive; an empty one observes nothing.
        window?.setContent(AnyView(EmptyView()))
    }
}

/// A fixed-width window whose height follows its SwiftUI content, and which closes on Escape.
///
/// **The window sizes itself; the hosting controller is given no sizing options.** With
/// `.standardBounds` the hosting view carries size constraints, and AppKit resizes the window
/// to satisfy them from inside its own layout pass
/// (`_changeWindowFrameFromConstraintsIfNecessary`). That resize makes the hosting view ask for
/// another constraints pass, AppKit allows only as many passes as the window has views, and
/// the excess is an uncaught `NSGenericException` from `_postWindowNeedsUpdateConstraints`
/// that takes the whole app down when the content changes height — in the review, on choosing
/// **Something else…**. So the content's height is measured in SwiftUI and applied on the next
/// turn of the run loop, outside any layout pass.
///
/// No test reproduces that exception: the same content under the same options resizes without
/// complaint in the test process, hand-pumped or inside `NSApplication.run()`. After changing
/// how this window is sized, open a proposal in the running app and switch between an option
/// and **Something else…** several times.
@MainActor
final class FittedWindow: NSWindow {
    private static let escapeKeyCode: UInt16 = 53

    private let hosting: NSHostingController<AnyView>
    private let contentWidth: CGFloat

    init(width: CGFloat, content: AnyView) {
        contentWidth = width
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        contentViewController = hosting
        setContent(content)
    }

    /// Replaces the content and sizes the window to it at once, so it never appears at the
    /// previous content's height.
    func setContent(_ content: AnyView) {
        hosting.rootView = AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { [weak self] height in
                    // The next turn of the run loop, once the layout pass reporting this
                    // height has finished.
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated {
                            self?.fit(contentHeight: height)
                        }
                    }
                }
                // Between a change in the content's height and the window catching up, the
                // content stays pinned to the top edge.
                .frame(maxHeight: .infinity, alignment: .top)
        )
        // Proposed no height, the top-pinning frame reports the content's own: it stretches
        // to whatever it is offered, so an unbounded offer would come back unbounded.
        let fitting = hosting.sizeThatFits(in: CGSize(width: contentWidth, height: 0))
        fit(contentHeight: fitting.height)
    }

    /// Resizes to hold content of this height, keeping the title bar where it is.
    func fit(contentHeight: CGFloat) {
        let height = contentHeight.rounded(.up)
        let current = contentRect(forFrameRect: frame)
        guard height.isFinite, height >= 1,
              abs(current.height - height) > 0.5 || current.width != contentWidth
        else { return }
        let fitted = NSRect(
            x: current.minX,
            y: current.maxY - height,
            width: contentWidth,
            height: height
        )
        setFrame(frameRect(forContentRect: fitted), display: true)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode {
            close()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Why a proposal was made, the ways to act on it, and the decision.
///
/// Whatever an approval runs is on screen in full when the button is tapped: the selected
/// option's action, or the user's own text in the box. A proposal whose action is too long to
/// show whole is rejected when its file is read. The same holds for a rule the agent offers to
/// make standing: **Always** appears only beside the rule's condition and action in full, with
/// the pattern in the user's own decisions it was drawn from.
///
/// **The text under review is pinned when the window opens.** The scout can rewrite the file
/// while the window is up, and a view that followed the file would swap the words under a
/// cursor already moving to **Do It**. A rewrite therefore shows as a notice, the approving
/// buttons go dead, and the new text appears only when the user asks for it.
///
/// Nothing read back from the file is ever offered for approval: a retry starts from the
/// recommended option and an empty box, because a box pre-filled from a file the scout can
/// rewrite would run the scout's words as the user's.
@MainActor
struct ProVisorReviewView: View {
    @ObservedObject var center: ProVisorCenter
    let id: String
    let onClose: () -> Void

    /// The text being reviewed, as it stood when the window opened or was last brought up to
    /// date by the user.
    @State private var pinned: ReviewedText?
    @State private var optionIndex = 0
    @State private var isCustom = false
    @State private var typed = ""
    /// Why the last tap ran nothing.
    @State private var notice: String?
    @FocusState private var isTyping: Bool

    static let width: CGFloat = 460

    init(center: ProVisorCenter, id: String, onClose: @escaping () -> Void) {
        self.center = center
        self.id = id
        self.onClose = onClose
        _pinned = State(
            initialValue: center.proposals.first { $0.id == id }.map(ReviewedText.init)
        )
    }

    var body: some View {
        Group {
            if let proposal = center.proposals.first(where: { $0.id == id }) {
                detail(proposal)
                    .onAppear {
                        if pinned == nil {
                            pinned = ReviewedText(proposal)
                        }
                    }
            } else {
                Text("This proposal is no longer on file.")
                    .font(.subheadline)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func detail(_ proposal: Proposal) -> some View {
        let state = ProposalRowState.of(
            proposal,
            actingID: center.actingID,
            queuedIDs: center.queuedIDs
        )
        let closedReason = ProposalReview.closedReason(proposal, now: Date())
        let isDecidable = (state == .open || state == .failed) && closedReason == nil
        let current = ReviewedText(proposal)
        // Only a pending decision needs the pinned text; anything else shows the file as it is.
        let text = isDecidable ? (pinned ?? current) : current
        let isStale = isDecidable && text != current

        return VStack(alignment: .leading, spacing: 14) {
            Text(text.title)
                .font(.headline)
                .foregroundStyle(NotchTheme.primaryForeground)
                .fixedSize(horizontal: false, vertical: true)

            if let why = text.why {
                block("Why", why)
            }

            if let closedReason {
                Text(closedReason)
                    .font(.subheadline)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            } else if isDecidable {
                if isStale {
                    staleNotice(current)
                }
                choices(text)
            } else {
                recorded(proposal, state: state)
            }

            if let rule = standingRule(for: proposal) {
                ruleBlock(
                    rule.isActive
                        ? "Done under your standing approval"
                        : "Done under a standing approval you have since taken back",
                    condition: rule.condition,
                    action: rule.action
                )
            }

            if let result = proposal.result, state == .done || state == .failed {
                block(state == .failed ? "Last attempt" : "Result", result)
            }

            if let notice, isDecidable {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer(
                proposal,
                text: text,
                state: state,
                isDecidable: isDecidable,
                isStale: isStale
            )
        }
    }

    // MARK: Choosing

    /// Says the file changed under the reader, and holds the new text back until asked for.
    private func staleNotice(_ current: ReviewedText) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("ProVisor updated this proposal while it was open. What you see is the earlier version.")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            ProVisorCapsuleButton(title: "Show the Update") {
                pinned = current
                optionIndex = 0
                notice = nil
            }
        }
    }

    @ViewBuilder
    private func choices(_ text: ReviewedText) -> some View {
        let index = min(optionIndex, text.options.count - 1)
        let option = text.options[index]

        ProVisorChipFlow(spacing: 6) {
            ForEach(Array(text.options.enumerated()), id: \.offset) { offset, option in
                ProVisorChip(title: option.label, isSelected: !isCustom && offset == index) {
                    optionIndex = offset
                    isCustom = false
                }
            }
            ProVisorChip(title: "Something else…", isSelected: isCustom) {
                isCustom = true
            }
        }

        if isCustom {
            instructionBox(suggested: option)
        } else {
            block("What approving does", option.action)
        }

        if ProposalReview.showsOffer(text.standingOffer, optionIndex: index, isCustom: isCustom),
           let offer = text.standingOffer {
            ruleBlock(
                "From now on, without asking",
                condition: offer.condition,
                action: offer.action,
                basis: offer.basis
            )
        }
    }

    /// The text box, beside the suggestion it replaces. That suggestion stays on screen because
    /// it is the background the run is given for what the instruction refers to.
    private func instructionBox(suggested: ProposalOption) -> some View {
        let overflow = ProposalReview.overflow(of: typed)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Suggested")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.secondaryForeground)

                Text(suggested.action)
                    .font(.subheadline)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Do this instead")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(NotchTheme.secondaryForeground)

                TextField("What should it do?", text: $typed, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(NotchTheme.primaryForeground)
                    .lineLimit(3...8)
                    .focused($isTyping)
                    // Focus is asked for once the field exists; asking in the tap that inserts
                    // it finds nothing to focus.
                    .onAppear { isTyping = true }
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(NotchTheme.brandGradient, lineWidth: isTyping ? 1 : 0)
                    )

                Text(
                    overflow > 0
                        ? "\(overflow) over the \(Proposal.actionLimit)-character limit"
                        : "Carried out as you write it, with the tools an approved action gets."
                )
                .font(.caption)
                .foregroundStyle(overflow > 0 ? Color.red : NotchTheme.secondaryForeground)
            }
        }
    }

    /// What a proposal past deciding is being, or was, carried out as. While it is queued or
    /// running that comes from the copy captured at the tap. Afterwards only the file's own
    /// record remains, which the scout can rewrite, so it is shown without calling it the
    /// user's.
    @ViewBuilder
    private func recorded(_ proposal: Proposal, state: ProposalRowState) -> some View {
        if let captured = center.capturedAction(for: proposal.id) {
            block(captured.isTyped ? "Your instruction" : "What is being done", captured.text)
        } else {
            block("What was done", proposal.recordedAction)
        }
    }

    // MARK: Text blocks

    private func block(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(NotchTheme.secondaryForeground)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(NotchTheme.primaryForeground)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// A rule set out as its parts: when it applies, what is done, and — on an offer — the
    /// pattern in the user's decisions that the agent drew the condition from.
    private func ruleBlock(
        _ label: String,
        condition: String,
        action: String,
        basis: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(NotchTheme.secondaryForeground)

            rulePart("When", condition)
            rulePart("Do", action)
            if let basis {
                rulePart("Why", basis, isQuiet: true)
            }
        }
    }

    private func rulePart(_ label: String, _ text: String, isQuiet: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(NotchTheme.secondaryForeground)
                .frame(width: 34, alignment: .leading)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(
                    isQuiet ? NotchTheme.secondaryForeground : NotchTheme.primaryForeground
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Deciding

    @ViewBuilder
    private func footer(
        _ proposal: Proposal,
        text: ReviewedText,
        state: ProposalRowState,
        isDecidable: Bool,
        isStale: Bool
    ) -> some View {
        if isDecidable {
            let index = min(optionIndex, text.options.count - 1)
            let showsOffer = ProposalReview.showsOffer(
                text.standingOffer,
                optionIndex: index,
                isCustom: isCustom
            )
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ProVisorCapsuleButton(title: "Dismiss") {
                    center.dismiss(proposal.id)
                    onClose()
                }
                if showsOffer {
                    ProVisorCapsuleButton(title: "Always", isEnabled: !isStale) {
                        decide(proposal, optionIndex: index, always: true)
                    }
                }
                ProVisorCapsuleButton(
                    title: ProposalReview.approveTitle(
                        isRetry: state == .failed,
                        showsOffer: showsOffer
                    ),
                    isProminent: true,
                    isEnabled: !isStale
                        && (!isCustom || ProposalReview.instruction(from: typed) != nil)
                ) {
                    decide(proposal, optionIndex: index, always: false)
                }
            }
        } else {
            switch state {
            case .queued, .working:
                Text(state == .working ? "Working on it…" : "Queued behind another action")
                    .font(.caption)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            case .done:
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if let rule = standingRule(for: proposal), rule.isActive {
                        ProVisorCapsuleButton(title: "Stop Doing This") {
                            center.revokeStanding(rule.id)
                        }
                    }
                    ProVisorCapsuleButton(title: "Clear") {
                        center.dismiss(proposal.id)
                        onClose()
                    }
                }
            case .open, .failed:
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    ProVisorCapsuleButton(title: "Close", action: onClose)
                }
            }
        }
    }

    /// Hands the decision to the center with the proposal on file. The buttons are live only
    /// while that copy's text equals the pinned text on screen, and the center refuses a copy
    /// that has changed again since this render.
    private func decide(_ proposal: Proposal, optionIndex index: Int, always: Bool) {
        let refusal = isCustom
            ? center.instruct(proposal, reference: index, text: typed)
            : center.approve(proposal, option: index, always: always)
        switch refusal {
        case nil:
            onClose()
        case .changed:
            notice = "This proposal changed as you decided. Nothing was run."
        case .unavailable:
            notice = "This proposal can no longer be acted on. Nothing was run."
        case .notSaved:
            notice = "The decision could not be saved, so nothing was run."
        }
    }

    /// The rule something was carried out under, in force or since revoked.
    private func standingRule(for proposal: Proposal) -> StandingRule? {
        guard proposal.isAutomatic, let under = proposal.under else { return nil }
        return center.standingRules.first { $0.id == under }
    }
}

/// The parts of a proposal a decision rests on.
struct ReviewedText: Equatable {
    let title: String
    let why: String?
    let options: [ProposalOption]
    let standingOffer: StandingOffer?

    init(_ proposal: Proposal) {
        title = proposal.title
        why = proposal.why
        options = proposal.options
        standingOffer = proposal.standingOffer
    }
}

@MainActor
private struct ProVisorChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(
                    isSelected ? NotchTheme.primaryForeground : NotchTheme.secondaryForeground
                )
                .background(Capsule().fill(Color.white.opacity(isSelected ? 0.14 : 0.07)))
                .overlay(
                    Capsule().strokeBorder(NotchTheme.brandGradient, lineWidth: isSelected ? 1.5 : 0)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lays chips out left to right and wraps to a new line when the next one does not fit: three
/// option names at their longest, plus the typed-instruction chip, are wider than the window.
private struct ProVisorChipFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extended = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, extended > width {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
