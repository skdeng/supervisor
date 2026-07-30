import Combine
import Darwin
import Foundation

enum FleetSessionStatus: String, Sendable {
    case busy
    case idle
    case waiting
}

struct FleetSession: Identifiable, Equatable, Sendable {
    let pid: Int32
    let sessionID: String
    let name: String
    let cwd: String
    let status: FleetSessionStatus
    let statusUpdatedAt: Date
    let kind: String

    var id: Int32 { pid }
}

/// Publishes the live interactive sessions recorded by Claude Code's session registry.
@MainActor
final class ClaudeSessionMonitor: ObservableObject {
    @Published private(set) var sessions: [FleetSession] = []

    static let defaultRegistryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    nonisolated private static let maximumFileSize = 64 * 1024

    private let registryURL: URL
    private let processQueue = DispatchQueue(label: "com.supervisor.claude-session-processes")
    private var watcher: DirectoryTreeWatcher?
    private var processSources: [Int32: DispatchSourceProcess] = [:]
    private var reloadTask: Task<Void, Never>?
    private var isRunning = false

    init(registryURL: URL = ClaudeSessionMonitor.defaultRegistryURL) {
        self.registryURL = registryURL
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AppLog.debug(.swarm, "session monitor started")

        let watcher = DirectoryTreeWatcher(url: registryURL) { [weak self] in
            Task { @MainActor in
                self?.refreshSoon()
            }
        }
        self.watcher = watcher
        watcher.start()

        reload(after: nil)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        AppLog.debug(.swarm, "session monitor stopped")
        watcher?.stop()
        watcher = nil
        for source in processSources.values {
            source.cancel()
        }
        processSources = [:]
        reloadTask?.cancel()
        reloadTask = nil
        sessions = []
    }

    /// Coalesces hook-triggered reads with any FSEvents notification caused by the same update.
    func refreshSoon() {
        guard isRunning else { return }
        reload(after: .milliseconds(120))
    }

    private func reload(after delay: Duration?) {
        reloadTask?.cancel()
        let registryURL = registryURL
        reloadTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }

            let loaded = await Task.detached(priority: .utility) {
                Self.loadSessions(from: registryURL)
            }.value

            guard let self, !Task.isCancelled, self.isRunning else { return }
            self.reconcileProcessSources(with: loaded)
            self.sessions = loaded
        }
    }

    private func reconcileProcessSources(with sessions: [FleetSession]) {
        let livePIDs = Set(sessions.map(\.pid))
        let stalePIDs = processSources.keys.filter { !livePIDs.contains($0) }
        for pid in stalePIDs {
            processSources.removeValue(forKey: pid)?.cancel()
        }

        for pid in livePIDs where processSources[pid] == nil {
            let source = DispatchSource.makeProcessSource(
                identifier: pid,
                eventMask: .exit,
                queue: processQueue
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.refreshSoon()
                }
            }
            processSources[pid] = source
            source.resume()
        }
    }

    nonisolated private static func loadSessions(from registryURL: URL) -> [FleetSession] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: registryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var sessionsByPID: [Int32: FleetSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  size <= maximumFileSize,
                  let data = readCapped(file)
            else { continue }
            guard let record = try? JSONDecoder().decode(RegistryRecord.self, from: data) else {
                AppLog.debug(.swarm, "registry decode failed \(file.lastPathComponent)")
                continue
            }
            guard
                  let session = record.session,
                  processIsAlive(session.pid)
            else { continue }

            if let current = sessionsByPID[session.pid],
               current.statusUpdatedAt > session.statusUpdatedAt {
                continue
            }
            sessionsByPID[session.pid] = session
        }

        return sessionsByPID.values.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.pid < $1.pid : nameOrder == .orderedAscending
        }
    }

    nonisolated private static func readCapped(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileSize + 1),
              !data.isEmpty,
              data.count <= maximumFileSize
        else { return nil }
        return data
    }

    nonisolated private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

private struct RegistryRecord: Decodable {
    let pid: Int64
    let sessionID: String
    let cwd: String
    let kind: String
    let name: String
    let status: String
    let statusUpdatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case pid
        // The registry spells the key "sessionId" (lower-case d), not "sessionID".
        case sessionID = "sessionId"
        case cwd
        case kind
        case name
        case status
        case statusUpdatedAt
    }

    var session: FleetSession? {
        guard pid > 0,
              pid <= Int64(Int32.max),
              !sessionID.isEmpty,
              sessionID.count <= 256,
              !name.isEmpty,
              name.count <= 256,
              cwd.count <= 4096,
              kind == "interactive",
              let fleetStatus = FleetSessionStatus(rawValue: status)
        else { return nil }

        return FleetSession(
            pid: Int32(pid),
            sessionID: sessionID,
            name: name,
            cwd: cwd,
            status: fleetStatus,
            statusUpdatedAt: Date(
                timeIntervalSince1970: TimeInterval(statusUpdatedAt) / 1_000
            ),
            kind: kind
        )
    }
}
