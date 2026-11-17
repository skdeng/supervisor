import Darwin
import Foundation

/// Decides whether a pass may carry the bridge's site, text, and photo-place tools, and prepares
/// them.
///
/// A pass gets the tools only when something is granted to read, the scout's access list is
/// sealed (`ProVisorAccess.scoutIsSealed`: every rule on it reads and nothing else, so no
/// connector tool can carry what a page or a text says, or where a photo was taken, out of the
/// Mac), responsibility for the agent process can be disclaimed (so the app's Full Disk Access
/// and its access to Photos never reach it), and the
/// installed agent CLI is the signed build the server will accept as a run's root. Otherwise the
/// pass runs without them, and `lastUnavailable` says why.
///
/// Preparing a run registers its token with the bridge server and writes the MCP configuration
/// the agent CLI starts the helper from. That file holds the token, so it lives in a private
/// folder beside `access.json`, outside the agent's working directory, and is deleted when the
/// run ends.
///
/// Every other run starts the same helper from a shared configuration that holds no token
/// (`holdConfigurationPath()`): the helper offers no tools and only holds the run's first turn
/// back until the account's connectors are up.
@MainActor
final class ProVisorBridge {
    enum Unavailable: String, Error, Equatable, Sendable {
        /// No site is granted, and texts and photo places are off.
        case nothingGranted
        /// The scout's access list holds a rule that is not known to be read-only.
        case accessNotSealed
        /// The agent CLI on this Mac is not the signed build.
        case cliNotTrusted
        /// The system cannot start the agent process responsible for itself.
        case disclaimUnavailable
        /// The tool channel or the run's configuration could not be set up.
        case serverFailed
    }

    /// A run's credential and configuration, from `prepare` until `finished`.
    struct PreparedRun: Equatable, Sendable {
        let token: String
        let bridge: RunBridge
        let configurationURL: URL
    }

    /// How long the helper holds a run's first turn back. A headless run waits for every
    /// configured stdio server to connect before its first turn and does not wait for the
    /// account's connectors (Gmail, Calendar). The first turn had no Gmail tool in 4 of 4 runs
    /// with no server configured and in 2 of 3 with a server that answered `initialize` at
    /// once, and had it in 3 of 3 with a server that answered after 4 seconds.
    nonisolated static let connectorSettle: Duration = .seconds(6)

    /// `connectorSettle` in the whole milliseconds the helper's environment carries.
    nonisolated static var connectorSettleMilliseconds: Int {
        let parts = connectorSettle.components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    /// The file name of the shared configuration that holds a run's first turn back.
    nonisolated static let holdConfigurationName = "connector-hold.json"

    /// A function that makes the server a bridge serves its runs on, given the handler that
    /// answers their calls.
    typealias ServerFactory = (@escaping AgentBridgeServer.Handler) -> AgentBridgeServer

    /// The server on the app's own socket.
    static let productionServer: ServerFactory = { handler in
        AgentBridgeServer(
            path: AgentBridgeHelper.defaultSocketPath,
            version: AgentBridgeHelper.bundleVersion,
            handler: handler
        )
    }

    /// Answers a call that arrives after its run has ended.
    nonisolated static let endedRunSentence = "This run has ended."

    /// Why the most recent `prepare` or `evaluate` found the tools unavailable; nil when they
    /// were available, or before either. A failed tool channel stays until a `prepare`
    /// succeeds, since only a `prepare` tries one.
    private(set) var lastUnavailable: Unavailable?

    private let sites: SiteAccessCenter
    private var server: AgentBridgeServer?
    private let makeServer: ServerFactory
    private let configurationFolder: URL
    private let executablePath: String
    private let cliIsTrusted: @MainActor () -> Bool
    private let disclaimIsAvailable: () -> Bool
    private var liveRuns: [String: PreparedRun] = [:]
    private var holdURL: URL?

    /// `server` is built on first use, by `makeServer`, when nil. The remaining seams are the
    /// trust check on the installed CLI, whether responsibility can be disclaimed, where
    /// configurations are written, and the executable the CLI starts as the helper.
    init(
        sites: SiteAccessCenter,
        server: AgentBridgeServer? = nil,
        makeServer: @escaping ServerFactory = ProVisorBridge.productionServer,
        configurationFolder: URL = ProVisorHome.runsURL,
        executablePath: String = Bundle.main.executablePath ?? "",
        cliIsTrusted: @escaping @MainActor () -> Bool = InstalledCLITrust().isTrusted,
        disclaimIsAvailable: @escaping () -> Bool = { ProcessResponsibility.isAvailable }
    ) {
        self.sites = sites
        self.server = server
        self.makeServer = makeServer
        self.configurationFolder = configurationFolder
        self.executablePath = executablePath
        self.cliIsTrusted = cliIsTrusted
        self.disclaimIsAvailable = disclaimIsAvailable
    }

    // MARK: Whether a pass may carry the tools

    /// What a pass could read and why not, decided from the granted sites, the texts and photo
    /// places settings, the access list, the system, and the installed CLI.
    private struct Eligibility {
        let sites: [SiteRecord]
        let awaiting: Set<String>
        let textsAreOn: Bool
        let photoPlacesAreOn: Bool
    }

    private func eligibility(for access: ProVisorAccess) -> Result<Eligibility, Unavailable> {
        let granted = sites.access.sites()
        let textsAreOn = sites.textsEnabled
        let photoPlacesAreOn = sites.photoPlacesEnabled
        guard !granted.isEmpty || textsAreOn || photoPlacesAreOn else {
            return .failure(.nothingGranted)
        }
        guard access.scoutIsSealed else { return .failure(.accessNotSealed) }
        guard disclaimIsAvailable() else { return .failure(.disclaimUnavailable) }
        guard cliIsTrusted() else { return .failure(.cliNotTrusted) }
        return .success(Eligibility(
            sites: granted,
            awaiting: sites.awaitingSignIn,
            textsAreOn: textsAreOn,
            photoPlacesAreOn: photoPlacesAreOn
        ))
    }

    /// The names of the granted sites a pass could read now, in the order they are listed; empty
    /// when it could read none. It makes no run and leaves `lastUnavailable` as it was.
    func availableSiteNames(access: ProVisorAccess) -> [String] {
        guard case let .success(eligible) = eligibility(for: access) else { return [] }
        return eligible.sites.map { ProVisorTools.siteLabel($0, awaiting: eligible.awaiting) }
    }

    /// Checks the conditions for the tools without making a run, and returns why they are not
    /// met; nil when they are. The answer is also `lastUnavailable`, except that a failed tool
    /// channel stays until a `prepare` succeeds.
    @discardableResult
    func evaluate(access: ProVisorAccess) -> Unavailable? {
        switch eligibility(for: access) {
        case let .failure(reason):
            lastUnavailable = reason
        case .success:
            if lastUnavailable != .serverFailed { lastUnavailable = nil }
        }
        return lastUnavailable
    }

    // MARK: Preparing a run

    /// Registers a run with the bridge and writes its configuration.
    func prepare(access: ProVisorAccess) -> Result<PreparedRun, Unavailable> {
        let eligible: Eligibility
        switch eligibility(for: access) {
        case let .success(value):
            eligible = value
        case let .failure(reason):
            return note(.failure(reason))
        }

        let server = self.server ?? makeProductionServer()
        self.server = server
        do {
            try server.start()
        } catch {
            AppLog.error(.provisor, "tool channel did not start")
            return note(.failure(.serverFailed))
        }

        let tools = ProVisorTools.descriptors(
            sites: eligible.sites,
            awaiting: eligible.awaiting,
            textsAreOn: eligible.textsAreOn,
            photoPlacesAreOn: eligible.photoPlacesAreOn
        )
        let token = AgentBridgeServer.makeToken()
        let configurationURL: URL
        do {
            configurationURL = try writeRunConfiguration(token: token)
        } catch {
            AppLog.error(.provisor, "tool channel configuration not written")
            return note(.failure(.serverFailed))
        }
        server.register(BridgeRun(token: token, rootProcess: nil, tools: tools))

        let run = PreparedRun(
            token: token,
            bridge: RunBridge(
                configurationPath: configurationURL.path,
                toolRules: ProVisorTools.allowedToolRules(for: tools),
                siteNames: eligible.sites.map { ProVisorTools.siteLabel($0, awaiting: eligible.awaiting) },
                textsAreOn: eligible.textsAreOn,
                photoPlacesAreOn: eligible.photoPlacesAreOn
            ),
            configurationURL: configurationURL
        )
        liveRuns[token] = run
        return note(.success(run))
    }

    /// Tells the bridge which process the app started for the run. Only a process that is the
    /// signed agent CLI is accepted as the root a caller must descend from.
    func launched(_ run: PreparedRun, pid: pid_t) {
        server?.setRootProcess(pid, for: run.token)
    }

    /// Ends the run's access: its token stops working, its configuration is deleted, and the
    /// browser it opened is closed. Safe to call again.
    func finished(_ run: PreparedRun) {
        liveRuns.removeValue(forKey: run.token)
        server?.retire(token: run.token)
        try? FileManager.default.removeItem(at: run.configurationURL)
        sites.access.end(visit: run.token)
    }

    /// Ends every live run, closes the tool channel, and deletes the shared hold configuration.
    func stop() {
        for run in Array(liveRuns.values) {
            finished(run)
        }
        server?.stop()
        if let holdURL { try? FileManager.default.removeItem(at: holdURL) }
        holdURL = nil
    }

    /// Answers one tool call for the run `token` names. A call whose run has ended is refused
    /// before it touches a site, and a run that ends while its call is under way has its visit
    /// closed once the call returns.
    func serve(token: String, tool: String, arguments: JSONValue) async -> BridgeReply {
        guard liveRuns[token] != nil else { return .failure(Self.endedRunSentence) }
        let reply = await sites.makeTools().handle(visit: token, tool: tool, arguments: arguments)
        if liveRuns[token] == nil {
            sites.access.end(visit: token)
        }
        return reply
    }

    /// Deletes configuration files left by runs that did not finish, such as after a crash.
    func removeStaleConfigurations() {
        let live = Set(liveRuns.values.map { $0.configurationURL.lastPathComponent })
            .union(holdURL.map { [$0.lastPathComponent] } ?? [])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: configurationFolder.path)) ?? []
        for name in names where Self.isConfigurationName(name) && !live.contains(name) {
            try? FileManager.default.removeItem(at: configurationFolder.appendingPathComponent(name))
        }
    }

    // MARK: The shared hold configuration

    /// The path of a configuration that starts this app's helper with no token and the settle
    /// time in its environment, for a run that carries no tools. It is written on the first call
    /// after the bridge starts, and again when the file has gone. Nil when the app's executable
    /// cannot be resolved or the file cannot be written.
    func holdConfigurationPath() -> String? {
        if let holdURL, FileManager.default.fileExists(atPath: holdURL.path) {
            return holdURL.path
        }
        holdURL = nil
        guard !executablePath.isEmpty else { return nil }
        do {
            let url = try Self.writeHoldConfiguration(
                executablePath: executablePath,
                into: configurationFolder
            )
            holdURL = url
            return url.path
        } catch {
            AppLog.error(.provisor, "connector hold configuration not written")
            return nil
        }
    }

    /// Writes the shared hold configuration into `folder` and returns its URL.
    nonisolated static func writeHoldConfiguration(
        executablePath: String,
        into folder: URL
    ) throws -> URL {
        let data = try configurationData(executablePath: executablePath, token: nil)
        try prepareFolder(folder)
        let url = folder.appendingPathComponent(holdConfigurationName, isDirectory: false)
        let temporary = folder.appendingPathComponent(
            ".connector-hold-\(randomName()).tmp",
            isDirectory: false
        )
        try createFile(data, at: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(temporary.path)
            throw failure
        }
        return url
    }

    // MARK: Pieces

    private func note(_ result: Result<PreparedRun, Unavailable>) -> Result<PreparedRun, Unavailable> {
        switch result {
        case .success:
            lastUnavailable = nil
        case let .failure(reason):
            lastUnavailable = reason
            AppLog.notice(.provisor, "bridge tools off: \(reason.rawValue)")
        }
        return result
    }

    private func makeProductionServer() -> AgentBridgeServer {
        makeServer { [weak self] token, tool, arguments in
            guard let self else { return .failure(Self.endedRunSentence) }
            return await self.serve(token: token, tool: tool, arguments: arguments)
        }
    }

    /// A configuration file name this bridge writes: 8 hex characters and `.json`, the shared
    /// hold configuration, or the temporary file that becomes it.
    private static func isConfigurationName(_ name: String) -> Bool {
        name == holdConfigurationName
            || name.range(
                of: #"\A([0-9a-f]{8}\.json|\.connector-hold-[0-9a-f]{8}\.tmp)\z"#,
                options: .regularExpression
            ) != nil
    }

    nonisolated private static func randomName() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// The MCP configuration that starts this app's executable as the helper, with `token` in
    /// its environment when the run has tools, and always with the settle time.
    nonisolated private static func configurationData(
        executablePath: String,
        token: String?
    ) throws -> Data {
        guard !executablePath.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var environment = [AgentBridgeHelper.settleVariable: String(connectorSettleMilliseconds)]
        if let token {
            environment[AgentBridgeHelper.tokenVariable] = token
        }
        let entry: [String: Any] = [
            "type": "stdio",
            "command": executablePath,
            "args": [AgentBridgeHelper.flag],
            "env": environment,
            "alwaysLoad": true,
        ]
        return try JSONSerialization.data(
            withJSONObject: ["mcpServers": [ProVisorTools.server: entry]],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Creates `folder` mode 0700. A folder that already exists keeps the mode it has, so the
    /// mode is set again.
    nonisolated private static func prepareFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        chmod(folder.path, 0o700)
    }

    /// Creates the file at `url`, mode 0600, and fails when one is already there.
    nonisolated private static func createFile(_ data: Data, at url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            unlink(url.path)
            throw error
        }
    }

    /// Writes a run's configuration under a name of 8 random hex characters, mode 0600 in a
    /// folder of mode 0700, and returns its URL.
    private func writeRunConfiguration(token: String) throws -> URL {
        let data = try Self.configurationData(executablePath: executablePath, token: token)
        try Self.prepareFolder(configurationFolder)
        for _ in 0..<8 {
            let url = configurationFolder.appendingPathComponent(
                Self.randomName() + ".json",
                isDirectory: false
            )
            do {
                try Self.createFile(data, at: url)
                return url
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }
}

/// Whether the agent CLI installed on this Mac is the signed build, remembered while the file
/// stays as it was.
///
/// Checking a signature reads the whole executable, which takes long enough to notice when it
/// runs on the main actor each time a run starts. The answer is kept for as long as the file
/// at the resolved path keeps the same size, inode, modification time, and status-change time,
/// and is judged again when any of them differs.
@MainActor
final class InstalledCLITrust {
    private struct Fingerprint: Equatable {
        let path: String
        let size: Int
        let inode: UInt64
        let modified: timespec
        let changed: timespec

        static func == (lhs: Fingerprint, rhs: Fingerprint) -> Bool {
            lhs.path == rhs.path && lhs.size == rhs.size && lhs.inode == rhs.inode
                && lhs.modified.tv_sec == rhs.modified.tv_sec
                && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec
                && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }

    private let resolve: () -> URL?
    private let check: (URL) -> Bool
    private var remembered: (fingerprint: Fingerprint, trusted: Bool)?

    init(
        resolve: @escaping () -> URL? = { AgentTaskService.resolveExecutable() },
        check: @escaping (URL) -> Bool = { AgentExecutableTrust.isTrusted(executable: $0) }
    ) {
        self.resolve = resolve
        self.check = check
    }

    func isTrusted() -> Bool {
        guard let url = resolve() else { return false }
        let resolved = url.resolvingSymlinksInPath()
        guard let fingerprint = Self.fingerprint(of: resolved) else { return false }
        if let remembered, remembered.fingerprint == fingerprint {
            return remembered.trusted
        }
        let trusted = check(url)
        remembered = (fingerprint, trusted)
        return trusted
    }

    private static func fingerprint(of url: URL) -> Fingerprint? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Fingerprint(
            path: url.path,
            size: Int(info.st_size),
            inode: UInt64(info.st_ino),
            modified: info.st_mtimespec,
            changed: info.st_ctimespec
        )
    }
}
