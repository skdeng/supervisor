import Foundation

/// Delivers now-playing snapshots from one long-lived entitled helper.
///
/// `NowPlayingReader` pays a process spawn — perl, dyld, the adapter dylib — for every read, so
/// keeping the UI current costs a spawn every couple of seconds for as long as the app runs.
/// This spawns the same helper once and reads the JSON objects it prints, one per line, as the
/// now-playing state changes. The helper writes nothing while nothing changes.
///
/// The helper is expected to outlive individual reads but not the app: it exits when its stdin
/// reaches EOF, which happens when this object closes the pipe or the process dies. If it
/// terminates on its own it is respawned with a widening backoff, and if it cannot stay up at
/// all, `onUnavailable` fires exactly once so the caller can fall back to one-shot reads.
@MainActor
final class NowPlayingStream {

    /// A parsed snapshot, or `nil` when nothing is playing.
    var onSnapshot: ((NowPlaying?) -> Void)?
    /// The helper could not be started or could not stay up. Never called after `stop()`.
    var onUnavailable: (() -> Void)?

    /// Perl bootstrap that `DynaLoader`-loads the adapter dylib and enters its streaming entry
    /// point, which never returns. A non-zero exit means the dylib or symbol is missing, which
    /// the termination handler treats like any other failure.
    private static let perlScript = """
    use strict; use warnings; use DynaLoader;
    my $lib = $ARGV[0];
    my $ref = DynaLoader::dl_load_file($lib, 0);
    unless ($ref) { exit 1; }
    my $sym = DynaLoader::dl_find_symbol($ref, "run_mediaremote_adapter_stream");
    unless ($sym) { exit 1; }
    DynaLoader::dl_install_xsub("main::run_mediaremote_adapter_stream", $sym);
    run_mediaremote_adapter_stream();
    """

    /// More restarts than this inside `restartWindow` means the helper is not viable here.
    private static let maxRestarts = 4
    private static let restartWindow: TimeInterval = 60
    /// A line carries base64 artwork, normally a few hundred KB. Anything past this is a
    /// runaway or a corrupt stream, and the buffer is dropped rather than grown without bound.
    private static let maxBufferedBytes = 8 << 20

    private let dylibPath: String?
    private var process: Process?
    /// Held open only so that closing it signals EOF on the helper's stdin.
    private var helperInput: Pipe?
    private var buffer = Data()
    private var isRunning = false
    private var restartTimes: [Date] = []
    private var restartTask: Task<Void, Never>?

    init() {
        self.dylibPath = NowPlayingReader.resolveDylibPath()
    }

    func start() {
        guard !isRunning else { return }
        guard dylibPath != nil else {
            onUnavailable?()
            return
        }
        isRunning = true
        restartTimes.removeAll()
        spawn()
    }

    func stop() {
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        teardownProcess()
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Process lifetime

    private func spawn() {
        guard isRunning, let dylibPath else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlScript, dylibPath]

        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            onUnavailable?()
            return
        }

        self.process = process
        self.helperInput = input
        buffer.removeAll(keepingCapacity: true)
    }

    private func teardownProcess() {
        if let process {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            // EOF on the helper's stdin is its cue to exit; terminate() is the backstop.
            try? helperInput?.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        process = nil
        helperInput = nil
    }

    private func handleTermination() {
        teardownProcess()
        guard isRunning else { return }   // a deliberate stop(), not a crash

        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < Self.restartWindow }
        restartTimes.append(now)

        guard restartTimes.count <= Self.maxRestarts else {
            isRunning = false
            onUnavailable?()
            return
        }

        // 1s, 2s, 4s, 8s — enough to ride out a transient failure without spinning.
        let delay = min(pow(2, Double(restartTimes.count - 1)), 30)
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.spawn()
        }
    }

    // MARK: - Framing

    /// Split the byte stream on newlines and publish each complete JSON object. A chunk can
    /// carry part of a line, several lines, or a line split across reads.
    private func ingest(_ chunk: Data) {
        buffer.append(chunk)

        if buffer.count > Self.maxBufferedBytes {
            buffer.removeAll(keepingCapacity: false)
            return
        }

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }

            // The helper's payload is shaped by whatever app is publishing now-playing info,
            // so it is parsed defensively: a bad line is skipped, never fatal.
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let dict = object as? [String: Any]
            else { continue }

            onSnapshot?(NowPlaying(json: dict))
        }
    }
}
