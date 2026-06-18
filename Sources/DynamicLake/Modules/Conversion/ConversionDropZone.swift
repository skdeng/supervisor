import SwiftUI
import UniformTypeIdentifiers

/// A drag-and-drop target that accepts file URLs and hands them to the module. Highlights
/// while a valid drag hovers, and reports the hovered file's media kind so the format picker
/// can re-scope before the drop completes.
struct ConversionDropZone: View {
    @ObservedObject var module: ConversionModule
    @State private var isTargeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: NotchTheme.surfaceCornerRadius, style: .continuous)
            .fill(Color.white.opacity(isTargeted ? 0.12 : 0.04))
            .overlay(
                RoundedRectangle(cornerRadius: NotchTheme.surfaceCornerRadius, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
                    .foregroundStyle(
                        isTargeted ? NotchTheme.primaryForeground : NotchTheme.separator
                    )
            )
            .overlay(content)
            .frame(height: 76)
            .animation(.easeInOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    private var content: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 20, weight: .regular))
            Text(isTargeted ? "Drop to convert" : "Drop audio or video")
                .font(.callout.weight(.medium))
            Text("Output is saved next to the original")
                .font(.caption2)
                .foregroundStyle(NotchTheme.secondaryForeground)
        }
        .foregroundStyle(NotchTheme.primaryForeground)
        .allowsHitTesting(false)
    }

    /// Resolves dropped item providers into file URLs, updates the picker scope from the
    /// first file, and enqueues the batch.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let accumulator = DroppedURLAccumulator()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    accumulator.append(url)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let urls = accumulator.snapshot()
                guard let first = urls.first else { return }
                module.updatePickerKind(for: first)
                module.enqueue(urls: urls)
            }
        }
        return true
    }
}

/// Thread-safe accumulator for file URLs resolved by concurrent `NSItemProvider`
/// completion callbacks during a drop.
private final class DroppedURLAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
