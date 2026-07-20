import AppKit
import QuickLookThumbnailing

/// Generates Quick Look thumbnails for local files off the main actor and hands the result
/// back on the main actor. Shared by modules that surface file-backed previews.
enum ThumbnailService {
    /// Pixel size of the requested thumbnail; the request scales for the display.
    static let pointSize = CGSize(width: 80, height: 80)

    /// Generate a thumbnail for `url`. The heavy rendering happens inside Quick Look's own
    /// services; only the small completion is hopped back to the main actor, where the
    /// resulting `NSImage` (not `Sendable`) is safely materialized and returned.
    @MainActor
    static func thumbnail(for url: URL, scale: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: pointSize,
            scale: max(scale, 1),
            representationTypes: .all
        )

        // The CGImage is Sendable-safe to carry across the continuation; the NSImage wrapper
        // is built on the main actor after resuming.
        let cgImage: CGImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.cgImage)
            }
        }

        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: pointSize)
    }
}
