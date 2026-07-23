import Foundation

/// Reads the signed-in Codex account's rate limits through the documented app-server protocol.
///
/// The client launches the user's installed `codex app-server`, performs the required initialize
/// handshake, and requests `account/rateLimits/read`. Codex owns authentication and network I/O;
/// SuperVisor never opens `auth.json` or handles a token. The process is long-lived only while
/// `CodexQuotaMonitor` considers Codex active, which also lets repeated refreshes reuse it.
@MainActor
final class CodexRateLimitClient {
    var onSnapshot: (([UsageTickerWindow]) -> Void)?
    var onUnavailable: (() -> Void)?

    private static let initializeRequestID = 1
    private static let maxBufferedBytes = 1 << 20

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var initialized = false
    private var wantsProcess = false
    private var pendingRequest = false
    private var activeRateRequestID: Int?
    private var nextRequestID = 2

    func requestSnapshot() {
        wantsProcess = true
        pendingRequest = true

        if process == nil {
            launch()
        } else if initialized {
            sendRateRequestIfNeeded()
        }
    }

    func stop() {
        wantsProcess = false
        pendingRequest = false
        activeRateRequestID = nil
        teardownProcess()
        buffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Process lifetime

    private func launch() {
        guard wantsProcess, process == nil else { return }
        guard let executableURL = Self.resolveCodexExecutable() else {
            failCurrentAttempt()
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server"]

        // An NVM-installed `codex` is a Node script whose shebang uses `/usr/bin/env node`.
        // GUI apps have a sparse PATH, so prepend the resolved CLI's directory for its sibling
        // `node` binary without sourcing or executing the user's shell configuration.
        var environment = ProcessInfo.processInfo.environment
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = executableURL.deletingLastPathComponent().path + ":" + inheritedPath
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
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
            output.fileHandleForReading.readabilityHandler = nil
            failCurrentAttempt()
            return
        }

        self.process = process
        inputPipe = input
        outputPipe = output
        initialized = false
        buffer.removeAll(keepingCapacity: true)

        guard send([
            "method": "initialize",
            "id": Self.initializeRequestID,
            "params": [
                "clientInfo": [
                    "name": "supervisor",
                    "title": "SuperVisor",
                    "version": "1.0",
                ],
            ],
        ]) else {
            failCurrentAttempt()
            return
        }
    }

    private func teardownProcess() {
        if let process {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            try? inputPipe?.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        initialized = false
        activeRateRequestID = nil
    }

    private func handleTermination() {
        let shouldNotify = wantsProcess
        teardownProcess()
        wantsProcess = false
        pendingRequest = false
        if shouldNotify { onUnavailable?() }
    }

    private func failCurrentAttempt() {
        let shouldNotify = wantsProcess
        wantsProcess = false
        pendingRequest = false
        teardownProcess()
        if shouldNotify { onUnavailable?() }
    }

    // MARK: - Protocol

    private func sendRateRequestIfNeeded() {
        guard initialized, pendingRequest, activeRateRequestID == nil else { return }
        pendingRequest = false

        let requestID = nextRequestID
        nextRequestID &+= 1
        activeRateRequestID = requestID
        guard send(["method": "account/rateLimits/read", "id": requestID]) else {
            failCurrentAttempt()
            return
        }
    }

    private func send(_ object: [String: Any]) -> Bool {
        guard let handle = inputPipe?.fileHandleForWriting,
              JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object)
        else { return false }

        data.append(UInt8(ascii: "\n"))
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    /// Split app-server stdout into JSONL messages. No thread is started, so the only expected
    /// traffic is handshake/account data, but framing remains capped and defensive.
    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        guard buffer.count <= Self.maxBufferedBytes else {
            failCurrentAttempt()
            buffer.removeAll(keepingCapacity: false)
            return
        }

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line),
                  let message = object as? [String: Any]
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let requestID = (message["id"] as? NSNumber)?.intValue

        if requestID == Self.initializeRequestID {
            guard message["result"] is [String: Any], send([
                "method": "initialized",
                "params": [String: Any](),
            ]) else {
                failCurrentAttempt()
                return
            }
            initialized = true
            sendRateRequestIfNeeded()
            return
        }

        if requestID == activeRateRequestID {
            activeRateRequestID = nil
            if let result = message["result"] as? [String: Any],
               let snapshot = Self.codexSnapshot(from: result) {
                publish(snapshot)
            }
            sendRateRequestIfNeeded()
            return
        }

        if message["method"] as? String == "account/rateLimits/updated",
           let params = message["params"] as? [String: Any],
           let snapshot = params["rateLimits"] as? [String: Any] {
            publish(snapshot)
        }
    }

    private func publish(_ snapshot: [String: Any]) {
        let windows = Self.windows(from: snapshot)
        guard !windows.isEmpty else { return }
        onSnapshot?(windows)
    }

    private static func codexSnapshot(from result: [String: Any]) -> [String: Any]? {
        if let byID = result["rateLimitsByLimitId"] as? [String: Any],
           let codex = byID["codex"] as? [String: Any] {
            return codex
        }
        return result["rateLimits"] as? [String: Any]
    }

    private static func windows(from snapshot: [String: Any]) -> [UsageTickerWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let entry = snapshot[key] as? [String: Any],
                  let used = (entry["usedPercent"] as? NSNumber)?.doubleValue,
                  used.isFinite,
                  let minutes = (entry["windowDurationMins"] as? NSNumber)?.doubleValue,
                  minutes.isFinite, minutes > 0,
                  let resetsAt = (entry["resetsAt"] as? NSNumber)?.doubleValue,
                  resetsAt.isFinite, resetsAt > 0
            else { return nil }

            return UsageTickerWindow(
                label: durationLabel(minutes: minutes),
                usedPercentage: min(max(used, 0), 100),
                resetsAt: Date(timeIntervalSince1970: resetsAt)
            )
        }
    }

    /// Codex reports durations in minutes. Tolerate historical off-by-one values (299/10079)
    /// while producing the same compact labels as Claude Usage: `5h`, `7d`, and so on.
    private static func durationLabel(minutes: Double) -> String {
        let roundedHours = Int((minutes / 60).rounded())
        if roundedHours > 0, abs(minutes - Double(roundedHours * 60)) <= 1 {
            if roundedHours.isMultiple(of: 24) {
                return "\(roundedHours / 24)d"
            }
            return "\(roundedHours)h"
        }
        return "\(Int(minutes.rounded()))m"
    }

    // MARK: - CLI discovery

    /// Resolve common package-manager installs without invoking a login shell. The app-server
    /// protocol is unavailable when no Codex CLI is installed, in which case the module simply
    /// remains absent.
    private static func resolveCodexExecutable() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        if let override = environment["CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("codex"))
        }

        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".volta/bin/codex"),
            home.appendingPathComponent(".bun/bin/codex"),
            home.appendingPathComponent("Library/pnpm/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/MacOS/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ])

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions
                .sorted { $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: .numeric
                ) == .orderedDescending }
                .map { $0.appendingPathComponent("bin/codex") })
        }

        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted
                && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }
}
