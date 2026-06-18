import Foundation

/// The kind of media a source file represents, derived from its extension. Drives which
/// target formats and quality presets are offered.
enum MediaKind: Equatable {
    case audio
    case video

    /// Best-effort classification of a file by extension. Unknown extensions are treated
    /// as video, which lets ffmpeg's broad demuxers still attempt a conversion.
    static func of(url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        // Default to video so container formats we don't enumerate still work.
        return .video
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "wav", "flac", "aiff", "aif", "ogg", "oga",
        "opus", "wma", "alac", "caf", "amr"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "webm", "mkv", "avi", "m4v", "flv", "wmv", "mpg",
        "mpeg", "3gp", "ts", "mts", "gif", "ogv"
    ]
}

/// A concrete output format the user can convert into. Carries the file extension and the
/// ffmpeg argument recipe (sans the variable bitrate/quality flags, which come from the
/// chosen `ConversionQuality`).
enum TargetFormat: String, CaseIterable, Identifiable, Hashable {
    // Audio
    case mp3
    case aac
    case wav
    case flac
    // Video
    case mp4
    case mov
    case webm
    case gif

    var id: String { rawValue }

    /// File extension for the produced file.
    var fileExtension: String { rawValue }

    /// Human label shown in the picker.
    var label: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .webm: return "WebM"
        case .gif: return "GIF"
        }
    }

    var kind: MediaKind {
        switch self {
        case .mp3, .aac, .wav, .flac: return .audio
        case .mp4, .mov, .webm, .gif: return .video
        }
    }

    /// The target formats valid for a given source media kind.
    static func formats(for kind: MediaKind) -> [TargetFormat] {
        allCases.filter { $0.kind == kind }
    }
}

/// A user-selectable quality tier. The concrete ffmpeg flags depend on the chosen
/// `TargetFormat`, so the mapping lives in `ConversionJob.arguments`.
enum ConversionQuality: String, CaseIterable, Identifiable, Hashable {
    case high
    case balanced
    case small

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .balanced: return "Balanced"
        case .small: return "Small"
        }
    }
}
