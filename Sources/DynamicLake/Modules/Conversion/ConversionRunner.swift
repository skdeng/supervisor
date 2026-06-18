import Foundation

/// Spawns and supervises the `ffmpeg` subprocess for a single `ConversionTask`, parsing the
/// `-progress pipe:1` key/value stream into live fractional progress.
///
/// All process/IO work happens off the main actor; UI state on the `ConversionTask` is
/// mutated by hopping back to the main actor. One runner drives one task to completion.
final class ConversionRunner: @unchecked Sendable {
    private let tools: FFmpegLocator.Tools
    private let task: ConversionTask
    private let job: ConversionJob

    /// The live process, retained so `cancel()` can terminate it. Guarded by `lock`.
    private var process: Process?
    private var cancelled = false
    private let lock = NSLock()

    /// Runs `body` while holding `lock`. A synchronous helper so it's callable from
    /// async contexts without tripping the "lock() unavailable from async" diagnostic.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Total source duration in seconds, probed up front so `-progress out_time_us` can be
    /// turned into a 0…1 fraction. nil → indeterminate progress.
    private var totalDurationSeconds: Double?

    init(tools: FFmpegLocator.Tools, task: ConversionTask, job: ConversionJob) {
        self.tools = tools
        self.task = task
        self.job = job
    }

    /// Runs the conversion to completion. Resolves UI state on the main actor as it goes.
    /// Designed to be called from a detached, non-main-actor context.
    func run() async {
        // Probe duration first so we can compute a percentage.
        totalDurationSeconds = probeDurationSeconds()

        await MainActor.run { task.markRunning(fraction: totalDurationSeconds == nil ? nil : 0) }

        let process = Process()
        process.executableURL = tools.ffmpeg
        process.arguments = job.arguments()

        let progressPipe = Pipe()   // stdout: -progress key=value stream
        let errorPipe = Pipe()      // stderr: human-readable error text on failure
        process.standardOutput = progressPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        // Register the process so cancel() can reach it; bail if already cancelled.
        let bailEarly = withLock { () -> Bool in
            if cancelled { return true }
            self.process = process
            return false
        }
        if bailEarly {
            await MainActor.run { task.markCancelled() }
            return
        }

        // Collect stderr concurrently so a full pipe never deadlocks the child.
        let errorHandle = errorPipe.fileHandleForReading
        let stderrTask = Task.detached { () -> String in
            let data = errorHandle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }

        do {
            try process.run()
        } catch {
            await MainActor.run {
                task.markFailed("Couldn't start ffmpeg: \(error.localizedDescription)")
            }
            return
        }

        // Stream and parse the -progress output as ffmpeg emits it.
        await parseProgress(from: progressPipe.fileHandleForReading)

        process.waitUntilExit()
        let stderrText = await stderrTask.value

        let wasCancelled = withLock { () -> Bool in
            let was = cancelled
            self.process = nil
            return was
        }

        if wasCancelled {
            // Remove any partial output we may have produced.
            try? FileManager.default.removeItem(at: job.output)
            await MainActor.run { task.markCancelled() }
            return
        }

        if process.terminationStatus == 0 {
            await MainActor.run { task.markFinished() }
        } else {
            try? FileManager.default.removeItem(at: job.output)
            let reason = Self.summarizeFailure(stderr: stderrText, code: process.terminationStatus)
            await MainActor.run { task.markFailed(reason) }
        }
    }

    /// Terminates the running ffmpeg process, if any. Idempotent.
    func cancel() {
        lock.lock()
        cancelled = true
        let proc = process
        lock.unlock()
        proc?.terminate()
    }

    // MARK: - Progress parsing

    /// Reads the `-progress` stream line-by-line. ffmpeg writes blocks of `key=value`
    /// lines terminated by `progress=continue` (or `progress=end`). We extract
    /// `out_time_us`/`out_time_ms` and divide by the probed total duration.
    private func parseProgress(from handle: FileHandle) async {
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)

            // Process complete lines.
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                await handleProgressLine(line)
            }
        }
    }

    private func handleProgressLine(_ line: String) async {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)

        guard let total = totalDurationSeconds, total > 0 else { return }

        let outSeconds: Double?
        switch key {
        case "out_time_us":
            outSeconds = Double(value).map { $0 / 1_000_000.0 }
        case "out_time_ms":
            // ffmpeg historically (mis)labels microseconds as out_time_ms in -progress.
            outSeconds = Double(value).map { $0 / 1_000_000.0 }
        default:
            outSeconds = nil
        }

        guard let seconds = outSeconds, seconds.isFinite, seconds >= 0 else { return }
        let fraction = min(max(seconds / total, 0), 1)
        await MainActor.run { task.markRunning(fraction: fraction) }
    }

    // MARK: - Duration probing

    /// Uses ffprobe (when available) to read the source duration in seconds. Returns nil if
    /// ffprobe is absent or the duration can't be parsed, which yields indeterminate progress.
    private func probeDurationSeconds() -> Double? {
        guard let ffprobe = tools.ffprobe else { return nil }

        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            job.source.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed), seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    // MARK: - Failure summary

    /// Distills ffmpeg stderr into a short, user-facing reason — the last non-empty,
    /// meaningful line, trimmed to a sensible length.
    private static func summarizeFailure(stderr: String, code: Int32) -> String {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let last = lines.last(where: { !$0.hasPrefix("frame=") && !$0.hasPrefix("size=") }) {
            let capped = last.count > 140 ? String(last.prefix(140)) + "…" : last
            return capped
        }
        return "ffmpeg exited with code \(code)"
    }
}
