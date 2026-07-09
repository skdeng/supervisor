import Foundation

/// Reads the system-wide now-playing session — metadata *and* artwork — through an entitled
/// system interpreter.
///
/// Since macOS 15.4, `mediaremoted` gates the now-playing *info* read
/// (`MRMediaRemoteGetNowPlayingInfo`) to callers whose host process is code-signed as an
/// Apple identity (`com.apple.*`). An ad-hoc-signed app gets a `nil` info dict. Transport
/// *commands* still work (see `MediaRemoteBridge`).
///
/// The workaround: `/usr/bin/perl` is an Apple-signed host (`com.apple.perl`) that the gate
/// admits. We have perl `DynaLoader`-load a small precompiled adapter dylib
/// (`mediaremote_adapter.dylib`, built by `make-app.sh` into the app's Resources) and call
/// its entry point. The adapter calls the MediaRemote C function from inside the entitled
/// host and prints a JSON object — including the artwork bytes as base64 — which we parse.
///
/// The C-function info dict inlines `kMRMediaRemoteNowPlayingInfoArtworkData`; the alternate
/// `MRNowPlayingRequest.localNowPlayingItem.nowPlayingInfo` path omits the artwork bytes,
/// which is why the adapter uses the C function. It is source-agnostic (Music, Spotify,
/// browser video), the same channel Control Center uses.
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
    /// `@ARGV[0]` is the dylib path. Failures print `{}` so the caller parses cleanly.
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
    /// `nil` when nothing is playing or the helper fails.
    func read() -> NowPlaying? {
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
        return NowPlaying(json: dict)
    }
}
