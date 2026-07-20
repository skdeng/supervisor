import SwiftUI
import UniformTypeIdentifiers

/// One staged file rendered as a selectable, draggable tile with per-file actions and live
/// operation status.
struct FileTileView: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var file: StagedFile

    @State private var hovering = false

    private var isSelected: Bool { store.selection.contains(file.id) }
    private var supportsTextRecognition: Bool {
        file.contentType.conforms(to: .image) || file.contentType.conforms(to: .pdf)
    }
    private let tileSide: CGFloat = 76

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
            Text(file.displayName)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .frame(width: tileSide)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.quickLookSingle(file.id)
        }
        .onTapGesture {
            store.toggleSelection(file.id)
        }
        // Drag the real file URL out to Finder, Mail, chat, etc.
        .onDrag {
            NSItemProvider(contentsOf: file.url) ?? NSItemProvider()
        }
        .onHover { hovering = $0 }
        .contextMenu { contextMenu }
        .help(tooltip)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))

            if let image = file.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Image(systemName: file.placeholderSymbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(NotchTheme.primaryForeground.opacity(0.85))
            }
        }
        .frame(width: tileSide, height: tileSide)
        .overlay {
            if let operation = file.activeOperation {
                RunningTileOverlay(operation: operation)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? AnyShapeStyle(NotchTheme.brandGradient)
                        : AnyShapeStyle(Color.white.opacity(0.12)),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            if hovering || isSelected {
                tileActionButton
            }
        }
        .overlay(alignment: .topLeading) {
            sourceBadge
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(NotchTheme.brandGradient)
                    .background(Circle().fill(.black).padding(1))
                    .padding(3)
            }
        }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.15), value: isSelected)
        .animation(.snappy(duration: 0.15), value: file.activeOperation?.id)
    }

    @ViewBuilder
    private var tileActionButton: some View {
        if let operation = file.activeOperation {
            ActiveOperationTileButton(operation: operation) {
                store.remove(file.id)
            }
        } else {
            removeButton
        }
    }

    private var removeButton: some View {
        Button {
            store.remove(file.id)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .padding(3)
        .help("Remove from FileShelf")
    }

    private var sourceBadge: some View {
        Image(systemName: sourceSymbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotchTheme.secondaryForeground)
            .frame(width: 18, height: 17)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(0.68))
            )
            .padding(3)
            .help(sourceDescription)
    }

    private var sourceSymbol: String {
        switch file.source {
        case .screenshot:
            return "camera.fill"
        case .dropped:
            return "arrow.down.circle.fill"
        case .generated:
            return "sparkles"
        }
    }

    private var sourceDescription: String {
        switch file.source {
        case .screenshot:
            return "Screenshot"
        case .dropped:
            return "Dropped file"
        case .generated:
            return "Generated result"
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Quick Look") { store.quickLookSingle(file.id) }
        Button("Copy") { store.copyToPasteboard(ids: [file.id]) }
        if supportsTextRecognition {
            Button("Copy Text") { store.copyRecognizedText(id: file.id) }
                .disabled(store.recognizingID != nil)
        }
        Button("AirDrop") { store.airDrop(ids: [file.id]) }
        Button("Reveal in Finder") { store.revealInFinder(ids: [file.id]) }
        Button("Compress to .zip") { store.compress(ids: [file.id]) }
        FileContextAgentItems(store: store, file: file)
        Divider()
        Button("Remove from FileShelf") { store.remove(file.id) }
        Button("Move to Trash", role: .destructive) {
            store.moveToTrash(ids: [file.id])
        }
    }

    private var tooltip: String {
        if let size = file.formattedSize {
            return "\(file.displayName) — \(size)"
        }
        return file.displayName
    }
}

private struct RunningTileOverlay: View {
    @ObservedObject var operation: LiveOperation

    var body: some View {
        Group {
            if operation.isActive {
                ZStack {
                    Color.black.opacity(0.45)

                    VStack(spacing: 1) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            .tint(.white)
                        if operation.state == .running {
                            Text(
                                timerInterval: operation.startedAt...Date.distantFuture,
                                countsDown: false,
                                showsHours: false
                            )
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        } else {
                            Text("Cancelling")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.15), value: operation.state)
    }
}

private struct ActiveOperationTileButton: View {
    @ObservedObject var operation: LiveOperation
    let remove: () -> Void

    var body: some View {
        Group {
            if operation.state == .running {
                Button {
                    operation.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Cancel \(operation.title)")
            } else if operation.state == .cancelling {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                    .padding(3)
            } else {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
        .animation(.snappy(duration: 0.15), value: operation.state)
    }
}

private struct FileContextAgentItems: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var file: StagedFile

    @ViewBuilder
    var body: some View {
        if let operation = file.activeOperation {
            FileContextOperationItems(operation: operation)
        } else {
            FileShelfAgentVerbMenuItems(
                store: store,
                file: file,
                includesDivider: false,
                showsUnavailableMessage: false
            )
        }
    }
}

private struct FileContextOperationItems: View {
    @ObservedObject var operation: LiveOperation

    @ViewBuilder
    var body: some View {
        if operation.state == .running {
            Divider()
            Button("Cancel \(operation.title)") {
                operation.cancel()
            }
        } else if operation.state == .cancelling {
            Divider()
            Button("Cancelling…") {}
                .disabled(true)
        }
    }
}
