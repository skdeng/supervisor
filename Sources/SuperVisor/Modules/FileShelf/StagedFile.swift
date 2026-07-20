import AppKit
import Foundation
import UniformTypeIdentifiers

enum ItemSource: Equatable, Sendable {
    case dropped
    case screenshot
    case generated
}

/// One item held on the file shelf. Identified by a stable UUID so SwiftUI can track it
/// across reorders and thumbnail updates, and keyed by its resolved file URL for the
/// drag-out, reveal, AirDrop, compress, and Quick Look operations.
@MainActor
final class StagedFile: ObservableObject, Identifiable {
    /// Stable identity for SwiftUI lists and selection.
    let id = UUID()
    /// The on-disk location of the staged file.
    let url: URL
    /// When the item entered the shelf (drives newest-first ordering).
    let addedAt: Date
    /// Origin of the staged item.
    let source: ItemSource

    /// Display name (the file's last path component).
    let displayName: String
    /// Uniform type of the file, resolved from the URL; used for the placeholder glyph.
    let contentType: UTType
    /// Whether the URL points at a directory (affects compress/Quick Look behavior).
    let isDirectory: Bool
    /// File size in bytes, or nil if it could not be determined.
    let byteSize: Int64?
    /// File-system identity captured when the item entered the shelf.
    let fileIdentity: FileSystemIdentity?
    /// Generated artifacts are deleted when they leave the in-memory shelf.
    let isAppOwnedGeneratedArtifact: Bool

    /// Live thumbnail image. Starts nil (a type glyph stands in) and is filled in
    /// asynchronously by the `ThumbnailService` once generated.
    @Published var thumbnail: NSImage?

    /// The agent task currently operating on this item.
    @Published var activeOperation: LiveOperation?

    init(
        url: URL,
        addedAt: Date = Date(),
        source: ItemSource,
        isAppOwnedGeneratedArtifact: Bool = false
    ) {
        let resolved = url.resolvingSymlinksInPath()
        self.url = resolved
        self.addedAt = addedAt
        self.source = source
        self.displayName = resolved.lastPathComponent
        self.isAppOwnedGeneratedArtifact = isAppOwnedGeneratedArtifact
        self.fileIdentity = FileSystemIdentity.regularFile(at: resolved)

        let values = try? resolved.resourceValues(forKeys: [
            .contentTypeKey, .isDirectoryKey, .fileSizeKey, .totalFileSizeKey,
        ])
        self.contentType = values?.contentType ?? .data
        self.isDirectory = values?.isDirectory ?? false
        if let size = values?.totalFileSize ?? values?.fileSize {
            self.byteSize = Int64(size)
        } else {
            self.byteSize = nil
        }
    }

    /// SF Symbol used as a placeholder before (or instead of) a generated thumbnail.
    var placeholderSymbol: String {
        if isDirectory { return "folder.fill" }
        if contentType.conforms(to: .image) { return "photo" }
        if contentType.conforms(to: .movie) || contentType.conforms(to: .audiovisualContent) {
            return "film"
        }
        if contentType.conforms(to: .audio) { return "waveform" }
        if contentType.conforms(to: .pdf) { return "doc.richtext" }
        if contentType.conforms(to: .archive) { return "doc.zipper" }
        if contentType.conforms(to: .sourceCode) { return "chevron.left.forwardslash.chevron.right" }
        if contentType.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// Human-readable size string, or nil when unknown.
    var formattedSize: String? {
        guard let byteSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}
