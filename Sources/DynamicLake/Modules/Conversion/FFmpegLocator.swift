import Foundation

/// Locates a user-installed `ffmpeg` (and matching `ffprobe`) binary on the host.
///
/// FFmpeg is LGPL/GPL; we comply by invoking the binary the user installed rather than
/// bundling it. We probe the common Homebrew locations first, then fall back to a `which`
/// lookup that honors the user's login shell `PATH`.
enum FFmpegLocator {
    /// The result of a location attempt.
    struct Tools {
        /// Absolute path to the `ffmpeg` executable.
        let ffmpeg: URL
        /// Absolute path to `ffprobe`, if found next to ffmpeg or on PATH. Optional —
        /// conversion works without it; it only enriches duration/progress estimates.
        let ffprobe: URL?
    }

    /// Well-known install prefixes, checked before falling back to a shell PATH lookup.
    private static let knownFFmpegPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    /// Synchronously resolves the ffmpeg tools, or `nil` if no binary is installed.
    /// Safe to call off the main actor; performs filesystem and (at most one) subprocess
    /// access.
    static func locate() -> Tools? {
        let fm = FileManager.default

        // 1. Direct hits at known prefixes.
        for path in knownFFmpegPaths where fm.isExecutableFile(atPath: path) {
            let ffmpeg = URL(fileURLWithPath: path)
            return Tools(ffmpeg: ffmpeg, ffprobe: ffprobeNextTo(ffmpeg))
        }

        // 2. PATH lookup via the login shell, so we honor user-customized PATHs.
        if let resolved = whichFromLoginShell("ffmpeg"),
           fm.isExecutableFile(atPath: resolved.path) {
            return Tools(ffmpeg: resolved, ffprobe: ffprobeNextTo(resolved))
        }

        return nil
    }

    /// Looks for an `ffprobe` sibling next to the given ffmpeg path, then on PATH.
    private static func ffprobeNextTo(_ ffmpeg: URL) -> URL? {
        let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let resolved = whichFromLoginShell("ffprobe"),
           FileManager.default.isExecutableFile(atPath: resolved.path) {
            return resolved
        }
        return nil
    }

    /// Resolves a command through the user's login shell so the lookup sees the same
    /// `PATH` the user would in a terminal (Homebrew shellenv, asdf, etc.).
    private static func whichFromLoginShell(_ command: String) -> URL? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // `-l` login + `-i`-free: source profile so PATH is populated, then `command -v`.
        process.arguments = ["-l", "-c", "command -v \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed)
    }
}
