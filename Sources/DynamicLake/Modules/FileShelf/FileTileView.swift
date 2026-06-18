import SwiftUI
import UniformTypeIdentifiers

/// One staged file rendered as a thumbnail tile. Supports:
/// - drag OUT to other apps (`onDrag` providing the file URL),
/// - click to toggle multi-select, double-click for Quick Look,
/// - a per-file context menu (Quick Look, AirDrop, Reveal, Compress, Remove),
/// - a hover-revealed remove button.
struct FileTileView: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var file: StagedFile

    @State private var hovering = false

    private var isSelected: Bool { store.selection.contains(file.id) }
    private let tileSide: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            thumbnail
            Text(file.displayName)
                .font(.system(size: 9))
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
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.white.opacity(0.12),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            if hovering || isSelected {
                removeButton
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                    .background(Circle().fill(.black).padding(1))
                    .padding(3)
            }
        }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.15), value: isSelected)
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
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Quick Look") { store.quickLookSingle(file.id) }
        Button("AirDrop") { store.airDrop(ids: [file.id]) }
        Button("Reveal in Finder") { store.revealInFinder(ids: [file.id]) }
        Button("Compress to .zip") { store.compress(ids: [file.id]) }
        Divider()
        Button("Remove", role: .destructive) { store.remove(file.id) }
    }

    private var tooltip: String {
        if let size = file.formattedSize {
            return "\(file.displayName) — \(size)"
        }
        return file.displayName
    }
}
