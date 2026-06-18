import Foundation

/// An immutable description of a single conversion: where it reads from, the format and
/// quality it targets, and where it writes to. The runtime progress/state lives separately
/// in `ConversionTask` (an observable reference type) so the recipe stays a value.
struct ConversionJob: Identifiable, Equatable, Sendable {
    let id: UUID
    let source: URL
    let format: TargetFormat
    let quality: ConversionQuality
    /// Destination file, placed next to the source with a non-colliding name.
    let output: URL

    init(source: URL, format: TargetFormat, quality: ConversionQuality) {
        self.id = UUID()
        self.source = source
        self.format = format
        self.quality = quality
        self.output = Self.resolveOutput(source: source, format: format)
    }

    /// Display name for the produced file.
    var outputName: String { output.lastPathComponent }
    /// Display name for the source file.
    var sourceName: String { source.lastPathComponent }

    /// Picks an output URL next to the source: `<name>.<ext>`, suffixing `-1`, `-2`, … if a
    /// file already exists so we never clobber existing media.
    private static func resolveOutput(source: URL, format: TargetFormat) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = format.fileExtension
        let fm = FileManager.default

        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        // If converting to the same path as the source, or a collision exists, suffix it.
        var index = 1
        while candidate.path == source.path || fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// The full ffmpeg argument vector for this job, excluding the executable path itself.
    ///
    /// We always pass `-nostdin`, overwrite the (already-uniqued) output with `-y`, and
    /// emit machine-readable progress to a pipe via `-progress pipe:1 -nostats`.
    func arguments() -> [String] {
        var args: [String] = [
            "-nostdin",
            "-hide_banner",
            "-y",
            "-i", source.path
        ]

        args.append(contentsOf: codecArguments())

        // Machine-readable progress on stdout; suppress the noisy default stats on stderr.
        args.append(contentsOf: ["-progress", "pipe:1", "-nostats"])
        args.append(output.path)
        return args
    }

    /// The codec/quality-specific portion of the argument vector.
    private func codecArguments() -> [String] {
        switch format {
        // MARK: Audio
        case .mp3:
            // libmp3lame VBR: -q:a 0 (best) … higher = smaller.
            let q: String
            switch quality {
            case .high: q = "0"
            case .balanced: q = "4"
            case .small: q = "7"
            }
            return ["-vn", "-c:a", "libmp3lame", "-q:a", q]

        case .aac:
            let bitrate: String
            switch quality {
            case .high: bitrate = "256k"
            case .balanced: bitrate = "192k"
            case .small: bitrate = "128k"
            }
            return ["-vn", "-c:a", "aac", "-b:a", bitrate]

        case .wav:
            // Lossless PCM; quality tier selects sample depth.
            let codec: String
            switch quality {
            case .high: codec = "pcm_s24le"
            case .balanced: codec = "pcm_s16le"
            case .small: codec = "pcm_s16le"
            }
            return ["-vn", "-c:a", codec]

        case .flac:
            // FLAC compression level 0–12; higher = smaller/slower.
            let level: String
            switch quality {
            case .high: level = "5"
            case .balanced: level = "8"
            case .small: level = "12"
            }
            return ["-vn", "-c:a", "flac", "-compression_level", level]

        // MARK: Video
        case .mp4:
            let crf: String
            switch quality {
            case .high: crf = "18"
            case .balanced: crf = "23"
            case .small: crf = "28"
            }
            return [
                "-c:v", "libx264", "-preset", "medium", "-crf", crf,
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart"
            ]

        case .mov:
            let crf: String
            switch quality {
            case .high: crf = "18"
            case .balanced: crf = "23"
            case .small: crf = "28"
            }
            return [
                "-c:v", "libx264", "-preset", "medium", "-crf", crf,
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k"
            ]

        case .webm:
            // VP9 + Opus. CRF with unbounded bitrate (-b:v 0) is the recommended quality mode.
            let crf: String
            switch quality {
            case .high: crf = "24"
            case .balanced: crf = "31"
            case .small: crf = "37"
            }
            return [
                "-c:v", "libvpx-vp9", "-crf", crf, "-b:v", "0",
                "-row-mt", "1",
                "-c:a", "libopus", "-b:a", "128k"
            ]

        case .gif:
            // High-quality GIF via a generated palette in a single filtergraph; the fps and
            // width scale by quality to keep file size sane.
            let fps: String
            let width: String
            switch quality {
            case .high: fps = "20"; width = "640"
            case .balanced: fps = "15"; width = "480"
            case .small: fps = "10"; width = "360"
            }
            let filter =
                "fps=\(fps),scale=\(width):-1:flags=lanczos,split[s0][s1];" +
                "[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5"
            return ["-an", "-vf", filter, "-loop", "0"]
        }
    }
}
