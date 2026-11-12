import Foundation

/// Reads every app's now-playing session — metadata, playback state, and artwork — through an
/// entitled system interpreter, one process spawn per read.
///
/// Since macOS 15.4, `mediaremoted` gates now-playing *info* reads to callers whose host process
/// is code-signed as an Apple identity (`com.apple.*`). Transport *commands* are admitted from
/// this app (see `MediaRemoteBridge`).
///
/// The workaround: `/usr/bin/perl` is an Apple-signed host (`com.apple.perl`) that the gate
/// admits. We have perl `DynaLoader`-load a small precompiled adapter dylib
/// (`mediaremote_adapter.dylib`, built by `make-app.sh` into the app's Resources) and call
/// its entry point. The adapter reads MediaRemote from inside the admitted host and prints a
/// JSON object — one entry per session, artwork as base64 — which we parse. The adapter's own
/// header documents what it reads and why.
///
/// `@unchecked Sendable`: holds only an immutable resolved dylib path, so it is safe to read
/// from any queue.
final class NowPlayingReader: @unchecked Sendable {

    /// Absolute path to the adapter dylib shipped in the app bundle's Resources. Resolved
    /// once: from `Bundle.main` when running as a proper `.app`, otherwise derived from the
    /// running executable's location (covers the bare `swift run` layout during development).
    private let dylibPath: String?

    init() {
        self.dylibPath = Self.resolveDylibPath()
    }

    /// Locate `mediaremote_adapter.dylib`. Prefers the bundle's `Resources`; falls back to a
    /// `Resources` dir alongside `Contents/MacOS/<exe>`.
    static func resolveDylibPath() -> String? {
        let name = "mediaremote_adapter"
        if let url = Bundle.main.url(forResource: name, withExtension: "dylib") {
            return url.path
        }
        // Fallback: <bundle>/Contents/MacOS/<exe> -> <bundle>/Contents/Resources/<name>.dylib
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidate = exe
            .deletingLastPathComponent()      // .../Contents/MacOS
            .deletingLastPathComponent()      // .../Contents
            .appendingPathComponent("Resources")
            .appendingPathComponent("\(name).dylib")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    /// Perl bootstrap that `DynaLoader`-loads the adapter dylib and invokes its entry point.
    /// `@ARGV[0]` is the dylib path. Failures print `{}`, which parses as a read with no answer.
    private static let perlScript = """
    use strict; use warnings; use DynaLoader;
    my $lib = $ARGV[0];
    my $ref = DynaLoader::dl_load_file($lib, 0);
    unless ($ref) { print "{}"; exit 0; }
    my $sym = DynaLoader::dl_find_symbol($ref, "run_mediaremote_adapter");
    unless ($sym) { print "{}"; exit 0; }
    DynaLoader::dl_install_xsub("main::run_mediaremote_adapter", $sym);
    run_mediaremote_adapter();
    """

    /// Run the helper synchronously (call off the main actor) and parse the result. Returns
    /// `nil` when the helper fails or could not complete its read; a capture with no sessions
    /// means no app has one.
    func read() -> NowPlayingCapture? {
        guard let dylibPath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlScript, dylibPath]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            return nil
        }
        return NowPlayingCapture(json: dict)
    }
}
