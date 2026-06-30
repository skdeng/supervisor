import SwiftUI

/// The ClipVisor section in the expanded panel: a header with a clear/select control, a
/// drop zone, a scrollable grid of staged tiles, and an action toolbar (AirDrop, Quick Look,
/// Reveal, Compress, Remove) operating on the current selection (or all items when nothing is
/// selected). File drops are received by the window's drag destination (so a file dragged
/// onto the notch opens the sheet); this view just reflects the drag-targeting state.
struct FileShelfExpandedView: View {
    @ObservedObject var store: FileShelfStore
    /// True while a file is being dragged onto the notch (engine-driven highlight).
    let dropTargeting: Bool

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 88), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if store.isEmpty {
                dropZone(prompt: true)
            } else {
                dropZone(prompt: false)
                    .frame(height: 28)
                grid
                actionToolbar
            }

            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .liquidGlass(cornerRadius: NotchTheme.surfaceCornerRadius)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("ClipVisor")
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
            if !store.isEmpty {
                Button {
                    store.clearAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(NotchTheme.secondaryForeground)
                .help("Clear shelf")
            }
        }
        .foregroundStyle(NotchTheme.primaryForeground)
    }

    // MARK: Drop zone

    private func dropZone(prompt: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .foregroundStyle(dropTargeting ? Color.accentColor : Color.white.opacity(0.25))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(dropTargeting ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.03))
                )

            if prompt {
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
            } else {
                Text(dropTargeting ? "Release to add" : "Drop more files")
                    .font(.caption2)
                    .foregroundStyle(NotchTheme.secondaryForeground)
            }
        }
        .animation(.snappy(duration: 0.15), value: dropTargeting)
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(store.files) { file in
                    FileTileView(store: store, file: file)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 180)
    }

    // MARK: Action toolbar

    private var actionToolbar: some View {
        let targetCount = store.selection.isEmpty ? store.count : store.selection.count
        let suffix = store.selection.isEmpty ? "all" : "\(targetCount)"

        return HStack(spacing: 8) {
            actionButton(title: "AirDrop", systemImage: "dot.radiowaves.right") {
                store.airDrop()
            }
            actionButton(title: "Quick Look", systemImage: "eye") {
                store.quickLook()
            }
            actionButton(title: "Reveal", systemImage: "folder") {
                store.revealInFinder()
            }
            actionButton(title: "Zip", systemImage: "doc.zipper") {
                store.compress()
            }
            actionButton(title: "Remove", systemImage: "trash", destructive: true) {
                if store.selection.isEmpty {
                    store.clearAll()
                } else {
                    store.removeSelected()
                }
            }

            Spacer(minLength: 0)

            Text("Acting on \(suffix)")
                .font(.caption2)
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 8))
            }
            .frame(width: 44, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red.opacity(0.9) : NotchTheme.primaryForeground)
        .help(title)
    }
}
