import SwiftUI

/// The FileShelf as a detached card beside the expanded sheet: a header, a vertical rail of
/// staged tiles, and actions operating on the current selection (or all items when nothing is
/// selected). File drops are received by the window's drag destination; this view reflects its
/// targeting state.
struct FileShelfSideCardView: View {
    @ObservedObject var store: FileShelfStore
    /// True while a file is being dragged onto the notch (engine-driven highlight).
    let dropTargeting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if store.isEmpty {
                emptyDropZone
            } else {
                tileRail
                actionGrid
            }
            OperationTickerRow(center: store.operations)

            if let feedback = store.feedback {
                Label(
                    feedback.message,
                    systemImage: feedback.isError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                    .font(.caption2)
                    .foregroundStyle(feedback.isError ? Color.orange : Color.green)
                    .lineLimit(2)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .opacity(dropTargeting ? 0.72 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay { targetingOverlay }
        .animation(.snappy(duration: 0.15), value: dropTargeting)
        .animation(.snappy(duration: 0.18), value: store.feedback)
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("Shelf")
                .font(.system(size: 13, weight: .semibold))
            if store.count > 0 {
                Text("\(store.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }

            Spacer()

            if !store.selection.isEmpty {
                Button {
                    store.clearSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .help("Deselect")
                .notchTooltip("Deselect")
            }
        }
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    // MARK: Drop targeting

    @ViewBuilder
    private var targetingOverlay: some View {
        if dropTargeting {
            ZStack {
                RoundedRectangle(cornerRadius: NotchTheme.panelCornerRadius, style: .continuous)
                    .fill(NotchTheme.brandGradient.opacity(0.10))

                RoundedRectangle(cornerRadius: NotchTheme.panelCornerRadius, style: .continuous)
                    .strokeBorder(NotchTheme.brandGradient, lineWidth: 1.5)

                if !store.isEmpty {
                    Text("Release to add")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(NotchTheme.primaryForeground)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: Drop zone

    private var emptyDropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundStyle(
                    dropTargeting
                        ? AnyShapeStyle(NotchTheme.brandGradient)
                        : AnyShapeStyle(Color.white.opacity(0.25))
                )
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            dropTargeting
                                ? AnyShapeStyle(NotchTheme.brandGradient.opacity(0.12))
                                : AnyShapeStyle(Color.white.opacity(0.03))
                        )
                )

            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 22, weight: .regular))
                Text("Drop files here")
                    .font(.system(size: 12, weight: .medium))
                Text("Copy, AirDrop, or drag out")
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(NotchTheme.primaryForeground)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 18)
        }
        .frame(maxHeight: .infinity)
        .animation(.snappy(duration: 0.15), value: dropTargeting)
    }

    // MARK: Tile rail

    /// Staged tiles stacked vertically. The scroll view is flexible, so the rail absorbs
    /// whatever height the card's fixed frame leaves between header and actions.
    private var tileRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(store.files) { file in
                    FileTileView(store: store, file: file)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Action grid

    private var actionGrid: some View {
        let targets = store.actionFiles()
        let targetIDs = Set(targets.map(\.id))
        let supportsTextRecognition = !targets.isEmpty && targets.allSatisfy {
            $0.contentType.conforms(to: .image) || $0.contentType.conforms(to: .pdf)
        }
        let textTargetID = targets.count == 1 ? targets.first?.id : nil

        // Each row splits the card's full width among its buttons, so the panel stays flush
        // whether Copy Text is offered or not. Quick Look, Reveal, Zip, and the agent verbs
        // live on each tile's context menu (and Quick Look on double-click) instead.
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                ShelfActionButton(title: "Copy", systemImage: "doc.on.doc") {
                    store.copyToPasteboard(ids: targetIDs)
                }
                if supportsTextRecognition {
                    ShelfActionButton(
                        title: textTargetID == nil ? "Copy Text (needs one item)" : "Copy Text",
                        systemImage: "text.viewfinder",
                        busy: store.recognizingID != nil,
                        disabled: textTargetID == nil || store.recognizingID != nil
                    ) {
                        if let textTargetID {
                            store.copyRecognizedText(id: textTargetID)
                        }
                    }
                }
                ShelfActionButton(title: "AirDrop", systemImage: "dot.radiowaves.right") {
                    store.airDrop(ids: targetIDs)
                }
            }

            Rectangle()
                .fill(NotchTheme.separator)
                .frame(height: 1)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)

            HStack(spacing: 2) {
                ShelfActionButton(title: "Remove from shelf", systemImage: "xmark.bin") {
                    store.remove(ids: targetIDs)
                }
                ShelfActionButton(
                    title: "Move to Trash",
                    systemImage: "trash.fill",
                    destructive: true
                ) {
                    store.moveToTrash(ids: targetIDs)
                }
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }
}

private struct OperationTickerRow: View {
    @ObservedObject var center: OperationCenter

    var body: some View {
        Group {
            if !center.operations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(center.operations) { operation in
                        OperationTickerEntry(operation: operation)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(
            .snappy(duration: 0.15),
            value: center.operations.map(\.id)
        )
    }
}

/// One live operation as two stacked lines sized for the card's narrow content column: the
/// title, then the state with its controls. The cancel button rides the state line, always in
/// view — cancelling billable agent work is the one control here that must never scroll away.
private struct OperationTickerEntry: View {
    @ObservedObject var operation: LiveOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(operation.title)
                .foregroundStyle(NotchTheme.primaryForeground)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 4) {
                stateView
            }
            .lineLimit(1)
        }
        .font(.caption2)
        .animation(.snappy(duration: 0.15), value: operation.state)
    }

    @ViewBuilder
    private var stateView: some View {
        switch operation.state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.45)
                .frame(width: 8, height: 8)
                .tint(NotchTheme.secondaryForeground)
            Text(
                timerInterval: operation.startedAt...Date.distantFuture,
                countsDown: false,
                showsHours: false
            )
            .monospacedDigit()
            .foregroundStyle(NotchTheme.secondaryForeground)
            Button {
                operation.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(NotchTheme.secondaryForeground)
            .help("Cancel \(operation.title)")
            .notchTooltip("Cancel \(operation.title)")

        case .cancelling:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.45)
                .frame(width: 8, height: 8)
                .tint(NotchTheme.secondaryForeground)
            Text("Cancelling…")
                .foregroundStyle(NotchTheme.secondaryForeground)

        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if let costUSD = operation.costUSD {
                Text(
                    costUSD,
                    format: .currency(code: "USD").precision(.fractionLength(2))
                )
                .monospacedDigit()
                .foregroundStyle(NotchTheme.secondaryForeground)
            }

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .truncationMode(.tail)
                .help(message)
                .notchTooltip(message)

        case .cancelled:
            Image(systemName: "slash.circle")
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
    }
}

private struct ShelfActionButton: View {
    let title: String
    let systemImage: String
    var destructive = false
    var busy = false
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red.opacity(0.9) : NotchTheme.primaryForeground)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(title)
        .notchTooltip(title)
    }
}
