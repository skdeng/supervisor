import Darwin
import Foundation
import Testing

@testable import SuperVisor

/// A short-named folder under the temporary directory, removed by `remove()`. A Unix socket path
/// holds 104 bytes and the temporary directory already takes about 50 of them, so names here stay
/// short and each test puts its sockets directly inside.
struct ScratchFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(UUID().uuidString.prefix(8)), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A path inside the folder.
    func path(_ name: String) -> String {
        url.appendingPathComponent(name).path
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Counts calls and tracks how many are in flight at once, from any thread.
final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var inFlight = 0
    private var peak = 0

    var startedCount: Int { lock.withLock { started } }
    var peakConcurrency: Int { lock.withLock { peak } }

    func enter() {
        lock.withLock {
            started += 1
            inFlight += 1
            peak = max(peak, inFlight)
        }
    }

    func leave() {
        lock.withLock { inFlight -= 1 }
    }
}

/// Collects values appended from any thread.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    var all: [Value] { lock.withLock { values } }

    func record(_ value: Value) {
        lock.withLock { values.append(value) }
    }
}

enum BridgeTestClient {
    /// Sends `request` over a fresh connection and reads the one-line reply, on a dispatch
    /// thread so the blocking calls never occupy the cooperative pool.
    static func exchange(
        _ request: BridgeRequest,
        at path: String,
        timeout: TimeInterval = 15
    ) async -> BridgeReply? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: exchangeBlocking(request, at: path, timeout: timeout))
            }
        }
    }

    static func exchangeBlocking(
        _ request: BridgeRequest,
        at path: String,
        timeout: TimeInterval = 15
    ) -> BridgeReply? {
        guard let line = try? JSONEncoder().encode(request) else { return nil }
        return exchangeRaw(line, at: path, timeout: timeout)
    }

    /// Sends `bytes` followed by a newline, tolerating a server that answers and closes before
    /// everything is written.
    static func exchangeRaw(
        _ bytes: Data,
        at path: String,
        timeout: TimeInterval = 15
    ) -> BridgeReply? {
        guard let descriptor = UnixSocket.connect(to: path) else { return nil }
        defer { close(descriptor) }
        _ = BridgeWire.writeLine(bytes, to: descriptor)
        guard case let .line(reply) = BridgeWire.readLine(
            from: descriptor,
            limit: BridgeWire.maximumReplyLine,
            timeout: timeout
        ) else { return nil }
        return try? JSONDecoder().decode(BridgeReply.self, from: reply)
    }
}

/// A connected pair of stream sockets in one process.
struct SocketPair {
    let first: Int32
    let second: Int32

    init?() {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }
        first = descriptors[0]
        second = descriptors[1]
        UnixSocket.prepare(first)
        UnixSocket.prepare(second)
    }

    func close() {
        Darwin.close(first)
        Darwin.close(second)
    }
}

extension Process {
    /// Waits up to `timeout` seconds for the process to exit; true when it has.
    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline { usleep(5_000) }
        return !isRunning
    }

    /// Ends the process if it is running and waits, with a bound, for it to be gone.
    func stopAndReap() {
        guard isRunning else { return }
        terminate()
        if !waitForExit(timeout: 3) {
            kill(processIdentifier, SIGKILL)
            _ = waitForExit(timeout: 3)
        }
    }
}

/// The built `SuperVisor` executable, for tests that run it as a child process.
enum BuiltExecutable {
    private final class BundleToken {}

    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let skipReason: Comment =
        "No SuperVisor executable newer than every source file sits beside the test bundle. A build relinks it after a source's content changes; after a change in modification time alone, delete .build/debug/SuperVisor and run `swift build`."

    /// The executable next to the test bundle, when it is newer than every source file.
    ///
    /// An executable that predates a launch mode starts the whole app when given that mode's
    /// flag, so a stale or missing binary disables the tests that need it rather than running
    /// them. The build system relinks the executable only when a source's content changed:
    /// sources whose modification time moved without a content change (a checkout, a restore)
    /// leave it older than they are.
    static let url: URL? = {
        let directory = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
        let candidate = directory.appendingPathComponent("SuperVisor")
        guard FileManager.default.isExecutableFile(atPath: candidate.path),
              FileManager.default.fileExists(
                  atPath: directory.appendingPathComponent("Sparkle.framework").path
              ),
              let built = modificationDate(candidate)
        else { return nil }

        let sources = packageRoot.appendingPathComponent("Sources/SuperVisor")
        guard let files = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        for case let file as URL in files where file.pathExtension == "swift" {
            if let edited = modificationDate(file), edited > built { return nil }
        }
        return candidate
    }()

    /// The variables that let the built executable find `Sparkle.framework`, which sits beside
    /// it. The executable carries no run-path for it; only the app bundle's embedded copy
    /// resolves without help.
    static var frameworkEnvironment: [String: String] {
        guard let url else { return [:] }
        return ["DYLD_FRAMEWORK_PATH": url.deletingLastPathComponent().path]
    }

    /// The version the executable reports: its embedded Info.plist's `CFBundleVersion`.
    static var version: String {
        let plist = packageRoot.appendingPathComponent("Info.plist")
        let values = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return values?["CFBundleVersion"] as? String ?? "0"
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
