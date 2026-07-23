import SwiftUI

/// The FileShelf section in the expanded panel: a header, a horizontal shelf of staged tiles,
/// and actions operating on the current selection (or all items when nothing is selected).
/// File drops are received by the window's drag destination; this view reflects its targeting
/// state.
struct FileShelfExpandedView: View {
    @ObservedObject var store: FileShelfStore
    /// True while a file is being dragged onto the notch (engine-driven highlight).
    let dropTargeting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if store.isEmpty {
                emptyDropZone
            } else {
                filmstrip
                actionToolbar
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
        .opacity(dropTargeting ? 0.72 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { targetingOverlay }
        .animation(.snappy(duration: 0.15), value: dropTargeting)
        .animation(.snappy(duration: 0.18), value: store.feedback)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("FileShelf")
                .font(.system(size: 13, weight: .semibold))
            if store.count > 0 {
                Text("\(store.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }

            Spacer()

            if !store.selection.isEmpty {
                Button("Deselect") { store.clearSelection() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    // MARK: Drop targeting

    @ViewBuilder
    private var targetingOverlay: some View {
        if dropTargeting {
            ZStack {
                RoundedRectangle(cornerRadius: NotchTheme.surfaceCornerRadius, style: .continuous)
                    .fill(NotchTheme.brandGradient.opacity(0.10))

                RoundedRectangle(cornerRadius: NotchTheme.surfaceCornerRadius, style: .continuous)
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
                Text("Stage files to AirDrop, compress, or drag out")
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
            .foregroundStyle(NotchTheme.primaryForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .animation(.snappy(duration: 0.15), value: dropTargeting)
    }

    // MARK: Filmstrip

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(store.files) { file in
                    FileTileView(store: store, file: file)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(height: 96)
    }

    // MARK: Action toolbar

    private var actionToolbar: some View {
        let targets = store.actionFiles()
        let targetIDs = Set(targets.map(\.id))
        let supportsTextRecognition = !targets.isEmpty && targets.allSatisfy {
            $0.contentType.conforms(to: .image) || $0.contentType.conforms(to: .pdf)
        }
        let textTargetID = targets.count == 1 ? targets.first?.id : nil
        let agentTargetID: UUID?
        if store.selection.count == 1 {
            agentTargetID = store.selection.first
        } else if store.count == 1 {
            agentTargetID = store.files.first?.id
        } else {
            agentTargetID = nil
        }

        return HStack(spacing: 2) {
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
            ShelfActionButton(title: "Quick Look", systemImage: "eye") {
                store.quickLook(ids: targetIDs)
            }
            ShelfActionButton(title: "AirDrop", systemImage: "dot.radiowaves.right") {
                store.airDrop(ids: targetIDs)
            }
            ShelfActionButton(title: "Reveal in Finder", systemImage: "folder") {
                store.revealInFinder(ids: targetIDs)
            }
            ShelfActionButton(title: "Compress to Zip", systemImage: "doc.zipper") {
                store.compress(ids: targetIDs)
            }
            ShelfAgentMenu(store: store, targetID: agentTargetID)

            Rectangle()
                .fill(NotchTheme.separator)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 2)

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
        .padding(3)
        .frame(maxWidth: .infinity)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

private struct ShelfAgentMenu: View {
    @ObservedObject var store: FileShelfStore
    let targetID: UUID?

    @State private var hovering = false

    private var target: StagedFile? {
        guard let targetID else { return nil }
        return store.files.first { $0.id == targetID }
    }

    var body: some View {
        Menu {
            if let target {
                ShelfAgentMenuItems(store: store, file: target)
            } else {
                Button("Select one file for agent actions") {}
                    .disabled(true)
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.white.opacity(0.10) : .clear)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(NotchTheme.primaryForeground)
        .disabled(target == nil)
        .opacity(target == nil ? 0.45 : 1)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(target == nil ? "Select one file for agent actions" : "Agent actions")
        .notchTooltip("Agent actions")
    }
}

private struct ShelfAgentMenuItems: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var file: StagedFile

    @ViewBuilder
    var body: some View {
        if let operation = file.activeOperation {
            ShelfAgentOperationMenuItems(store: store, file: file, operation: operation)
        } else {
            FileShelfAgentVerbMenuItems(store: store, file: file)
        }
    }
}

private struct ShelfAgentOperationMenuItems: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var file: StagedFile
    @ObservedObject var operation: LiveOperation

    @ViewBuilder
    var body: some View {
        switch operation.state {
        case .running:
            Button("Cancel \(operation.title)") {
                operation.cancel()
            }
        case .cancelling:
            Button("Cancelling…") {}
                .disabled(true)
        case .succeeded, .failed, .cancelled:
            FileShelfAgentVerbMenuItems(store: store, file: file)
        }
    }
}

private struct OperationTickerRow: View {
    @ObservedObject var center: OperationCenter

    var body: some View {
        Group {
            if !center.operations.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(center.operations) { operation in
                            OperationTickerEntry(operation: operation)
                        }
                    }
                }
                .frame(height: 18)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(
            .snappy(duration: 0.15),
            value: center.operations.map(\.id)
        )
    }
}

private struct OperationTickerEntry: View {
    @ObservedObject var operation: LiveOperation

    var body: some View {
        HStack(spacing: 4) {
            Text(operation.title)
                .foregroundStyle(NotchTheme.primaryForeground)
            if let detail = operation.detail {
                Text("· \(detail)")
                    .foregroundStyle(NotchTheme.secondaryForeground)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
            }

            stateView
        }
        .font(.caption2)
        .lineLimit(1)
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
                .frame(maxWidth: 160, alignment: .leading)
                .help(message)

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
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(title)
        .notchTooltip(title)
    }
}
