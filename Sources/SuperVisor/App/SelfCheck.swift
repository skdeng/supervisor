import AppKit
import Security
import SQLite3
import WebKit

/// Checks of operating-system behaviour the app depends on and no test can reach, run in a
/// fresh instance of the bundle:
///
///     open -n build/SuperVisor.app --args --self-check <name> --report <file>
///
/// **It has to be started through `open`.** Privacy grants and Keychain access are decided for
/// the app that is responsible for a process; a binary started from a shell answers for the
/// terminal, and the result says nothing about SuperVisor.
///
/// Each check writes one JSON object to the report file and exits. Nothing here reads or
/// reports message text, page content, or a secret: only counts, statuses, and timings.
@MainActor
enum SelfCheck {
    static let flag = "--self-check"

    /// The check named on the command line, when this launch is a self-check.
    static func requested(in arguments: [String]) -> (name: String, report: URL)? {
        guard let flagIndex = arguments.firstIndex(of: flag),
              arguments.indices.contains(flagIndex + 1),
              let reportIndex = arguments.firstIndex(of: "--report"),
              arguments.indices.contains(reportIndex + 1)
        else { return nil }
        return (arguments[flagIndex + 1], URL(fileURLWithPath: arguments[reportIndex + 1]))
    }

    static func run(name: String, report: URL) -> Never {
        switch name {
        case "keychain":
            finish(keychain(), report: report)
        case "messages":
            finish(messages(), report: report)
        case "history":
            finish(history(), report: report)
        case "disclaimed-exec":
            finish(disclaimedExec(), report: report)
        case "webkit":
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let check = WebKitCheck()
            check.start { result in
                finish(result, report: report)
            }
            application.run()
            exit(0)
        case "site-read":
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let check = SiteReadCheck()
            check.start { result in
                finish(result, report: report)
            }
            application.run()
            exit(0)
        case "agent":
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let check = AgentCheck()
            check.start { result in
                finish(result, report: report)
            }
            application.run()
            exit(0)
        case "bridge":
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let check = BridgeCheck()
            check.start { result in
                finish(result, report: report)
            }
            application.run()
            exit(0)
        case "tools":
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let check = ToolsCheck()
            check.start { result in
                finish(result, report: report)
            }
            application.run()
            exit(0)
        case "connectors":
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            let check = ConnectorsCheck()
            check.start { result in
                finish(result, report: report)
            }
            application.run()
            exit(0)
        default:
            finish(["error": "unknown check"], report: report)
        }
    }

    private static func finish(_ result: [String: Any], report: URL) -> Never {
        var result = result
        result["bundle"] = Bundle.main.bundlePath
        result["version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let data = (try? JSONSerialization.data(
            withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
        try? data.write(to: report, options: .atomic)
        exit(0)
    }

    // MARK: Keychain

    /// Reads the item an earlier run wrote, then writes it again. Run from one build, rebuild,
    /// and run again: the second read succeeding quickly means an item the app wrote stays
    /// readable across builds with no prompt.
    private static func keychain() -> [String: Any] {
        let service = "com.supervisor.SuperVisor.self-check"
        let account = "probe"
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        var read = identity
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let started = Date()
        let readStatus = SecItemCopyMatching(read as CFDictionary, &item)
        let readSeconds = Date().timeIntervalSince(started)
        let earlier = (item as? Data).flatMap { String(data: $0, encoding: .utf8) }

        SecItemDelete(identity as CFDictionary)
        var add = identity
        add[kSecValueData as String] = Data("written \(Date().formatted(.iso8601))".utf8)
        let addStatus = SecItemAdd(add as CFDictionary, nil)

        return [
            "check": "keychain",
            "readStatus": Int(readStatus),
            "readSeconds": readSeconds,
            "foundEarlierItem": earlier != nil,
            "earlierItem": earlier ?? "",
            "addStatus": Int(addStatus),
        ]
    }

    // MARK: Browsing history

    /// Whether the browsing-history check can open the user's history files and finds the
    /// tables and columns it reads. It reports counts and flags only: no address, title, or
    /// date is read into the report.
    private static func history() -> [String: Any] {
        let report = BrowsingHistory().schemaReport()
        return [
            "check": "history",
            "chromiumProfilesRead": report.chromiumProfilesRead,
            "chromiumSchemaOK": report.chromiumSchemaOK,
            "safariReadable": report.safariReadable,
            "safariSchemaOK": report.safariSchemaOK,
            "canReadProtectedData": report.canReadProtectedData,
        ]
    }

    // MARK: Messages and child processes

    /// Whether this app can read the Messages database, and whether a child it starts can —
    /// once started the ordinary way, and once with responsibility disclaimed.
    private static func messages() -> [String: Any] {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        var result: [String: Any] = [
            "check": "messages",
            "disclaimAvailable": ProcessResponsibility.isAvailable,
        ]

        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        result["appOpenStatus"] = Int(openStatus)
        if openStatus == SQLITE_OK {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM message",
                -1,
                &statement,
                nil
            )
            result["appQueryStatus"] = Int(prepared)
            if prepared == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW {
                result["appCanRead"] = true
                result["messageCount"] = Int(sqlite3_column_int64(statement, 0))
            } else {
                result["appCanRead"] = false
            }
            sqlite3_finalize(statement)
        } else {
            result["appCanRead"] = false
        }
        sqlite3_close(database)

        result["childInheritingCanRead"] = childCanRead(path, disclaiming: false)
        result["childDisclaimedCanRead"] = childCanRead(path, disclaiming: true)
        return result
    }

    /// Whether a program started through this executable's disclaimed launcher can read the
    /// Messages database: this process starts itself in `--exec-disclaimed` mode, which replaces
    /// itself with `/bin/cat` on the file.
    private static func disclaimedExec() -> [String: Any] {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        var result: [String: Any] = ["check": "disclaimed-exec"]
        guard let launcher = Bundle.main.executableURL else {
            result["childCanRead"] = false
            result["failure"] = "launcher not found"
            return result
        }

        let process = Process()
        process.executableURL = launcher
        process.arguments = [DisclaimedExec.flag, "/bin/cat", path]
        process.environment = ChildEnvironment.minimal()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            result["childCanRead"] = process.terminationReason == .exit
                && process.terminationStatus == 0
        } catch {
            result["childCanRead"] = false
            result["failure"] = "launch failed"
        }
        return result
    }

    /// Runs `/bin/cat` on the file with its output discarded and reports whether it succeeded.
    /// Returns nil when the child could not be started as asked.
    private static func childCanRead(_ path: String, disclaiming: Bool) -> Bool? {
        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&fileActions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&fileActions)
        }
        // Only the three standard streams reach the child. The disclaim goes after the flags.
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else {
            return nil
        }
        if disclaiming, !ProcessResponsibility.disclaim(&attributes) {
            return nil
        }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(
                &fileActions,
                descriptor,
                "/dev/null",
                descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY,
                0
            )
        }

        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/cat"), strdup(path), nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        var child: pid_t = 0
        guard posix_spawn(&child, "/bin/cat", &fileActions, &attributes, arguments, nil) == 0 else {
            return nil
        }
        var status: Int32 = 0
        guard waitpid(child, &status, 0) == child else { return nil }
        // Exited normally with status zero: the low seven bits clear means no signal.
        return (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0
    }
}

/// Whether a web view that is never shown loads a page, and whether its own data store keeps a
/// cookie from one launch to the next.
@MainActor
private final class WebKitCheck: NSObject, WKNavigationDelegate {
    /// A data store used by this check alone.
    fileprivate static let storeIdentifier = UUID(uuidString: "5B0B1F2E-6C1D-4E57-9A53-3B1D6B7A0C11")!
    private static let cookieName = "supervisor-self-check"

    private var window: NSWindow?
    private var webView: WKWebView?
    private var result: [String: Any] = ["check": "webkit"]
    private var completion: (([String: Any]) -> Void)?
    private var started = Date()

    func start(completion: @escaping ([String: Any]) -> Void) {
        self.completion = completion
        started = Date()

        let store = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store

        let frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        // Held in a window that is never ordered on screen.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        self.webView = webView

        store.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            self.result["cookieFromEarlierLaunch"] = cookies.contains {
                $0.name == Self.cookieName
            }
            let cookie = HTTPCookie(properties: [
                .name: Self.cookieName,
                .value: "1",
                .domain: "example.com",
                .path: "/",
                .secure: true,
                .expires: Date().addingTimeInterval(7 * 24 * 3600),
            ])
            guard let cookie else {
                self.finish(error: "cookie not constructed")
                return
            }
            store.httpCookieStore.setCookie(cookie) {
                webView.load(URLRequest(url: URL(string: "https://example.com/")!))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.finish(error: "timed out")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.title") { [weak self] title, _ in
            guard let self else { return }
            self.result["loaded"] = true
            self.result["titleLength"] = (title as? String)?.count ?? 0
            self.result["windowVisible"] = self.window?.isVisible ?? false
            self.finish(error: nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(error: (error as NSError).domain + " \((error as NSError).code)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(error: (error as NSError).domain + " \((error as NSError).code)")
    }

    private func finish(error: String?) {
        guard let completion else { return }
        self.completion = nil
        if let error {
            result["loaded"] = false
            result["error"] = error
        }
        result["seconds"] = Date().timeIntervalSince(started)
        completion(result)
    }
}

/// Whether a site browser reads a real page: it opens `https://example.com/` with a policy that
/// admits only that site's hosts, and reports what it read as counts. The page's text and links
/// are never reported. Run it with a network connection; it uses the `webkit` check's data store,
/// so it leaves the feature's own sessions alone.
@MainActor
private final class SiteReadCheck {
    func start(completion: @escaping ([String: Any]) -> Void) {
        let started = Date()
        let browser = SiteBrowser(
            policy: SiteNavigationPolicy(browseHosts: ["example.com", "www.example.com"]),
            dataStore: WKWebsiteDataStore(forIdentifier: WebKitCheck.storeIdentifier)
        )

        Task { @MainActor in
            var result: [String: Any] = ["check": "site-read"]
            do {
                let page = try await browser.open(URL(string: "https://example.com/")!)
                result["loaded"] = true
                result["titleLength"] = page.title.count
                result["textLength"] = page.text.count
                result["offeredLinks"] = page.links.count
            } catch {
                result["loaded"] = false
                result["titleLength"] = 0
                result["textLength"] = 0
                result["offeredLinks"] = 0
                result["failure"] = (error as? SiteBrowser.Failure)?.caseName ?? "unexpected"
            }
            result["seconds"] = Date().timeIntervalSince(started)
            browser.close()
            completion(result)
        }
    }
}

/// Whether the agent CLI starts, runs a one-turn prompt, and returns a result when started the
/// way every agent run is: through `AgentTaskService`, with responsibility disclaimed. A failure
/// is reported by the error's case name alone.
@MainActor
private final class AgentCheck {
    private static let arguments = [
        "-p", "Reply with the single word: ok",
        "--output-format", "stream-json",
        "--verbose",
        "--restricted",
        "--permission-prompts", "none",
        "--no-session-persistence",
        "--tools", "",
        "--model", "haiku",
        "--max-turns", "1",
        "--max-budget-usd", "0.05",
        "--strict-mcp-config",
    ]

    func start(completion: @escaping ([String: Any]) -> Void) {
        let started = Date()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-check-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        Task { @MainActor in
            var result: [String: Any] = [
                "check": "agent",
                "disclaimAvailable": ProcessResponsibility.isAvailable,
            ]
            do {
                _ = try await AgentTaskService().run(
                    arguments: Self.arguments,
                    workingDirectory: folder,
                    timeout: .seconds(90)
                )
                result["succeeded"] = true
            } catch {
                result["succeeded"] = false
                result["failure"] = (error as? AgentTaskError)?.caseName ?? "unexpected"
            }
            result["seconds"] = Date().timeIntervalSince(started)
            try? FileManager.default.removeItem(at: folder)
            completion(result)
        }
    }
}

/// Whether a real agent run can reach a tool this app serves: the agent CLI starts the bridge
/// helper, the helper's connection passes the signature and ancestry checks, and the tool's
/// answer comes back in the run's result.
@MainActor
private final class BridgeCheck {
    private nonisolated static let reply = "pong 7391"

    func start(completion: @escaping ([String: Any]) -> Void) {
        let started = Date()
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-check-\(suffix)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A socket of this check's own, so it never meets the one a running app is serving.
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("svb-\(suffix).sock").path

        let token = AgentBridgeServer.makeToken()
        let calls = CallCounter()
        let server = AgentBridgeServer(
            path: socketPath,
            version: AgentBridgeHelper.bundleVersion
        ) { _, _, _ in
            calls.increment()
            return BridgeReply(text: Self.reply)
        }
        server.register(BridgeRun(
            token: token,
            rootProcess: nil,
            tools: [BridgeTool(
                name: "echo",
                description: "Returns a fixed reply.",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            )]
        ))

        var result: [String: Any] = ["check": "bridge"]
        let configuration: [String: Any] = ["mcpServers": ["supervisor": [
            "type": "stdio",
            "command": Bundle.main.executablePath ?? "",
            "args": [AgentBridgeHelper.flag],
            "env": [
                AgentBridgeHelper.tokenVariable: token,
                AgentBridgeHelper.socketVariable: socketPath,
            ],
            "alwaysLoad": true,
        ]]]
        let configurationURL = folder.appendingPathComponent("mcp.json")
        do {
            try server.start()
            let data = try JSONSerialization.data(withJSONObject: configuration)
            FileManager.default.createFile(
                atPath: configurationURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        } catch {
            result["succeeded"] = false
            result["failure"] = "setup"
            completion(result)
            return
        }

        let arguments = [
            "-p", "Call the echo tool once, then reply with exactly the text it returned.",
            "--output-format", "stream-json",
            "--verbose",
            "--restricted",
            "--permission-prompts", "none",
            "--no-session-persistence",
            "--tools", "",
            "--model", "haiku",
            "--max-turns", "4",
            "--max-budget-usd", "0.10",
            "--strict-mcp-config",
            "--mcp-config", configurationURL.path,
            "--allowedTools", "mcp__supervisor__echo",
        ]

        Task { @MainActor in
            do {
                let outcome = try await AgentTaskService().run(
                    arguments: arguments,
                    workingDirectory: folder,
                    timeout: .seconds(120),
                    environment: [AgentBridgeHelper.socketVariable: socketPath],
                    onLaunch: { pid in
                        server.setRootProcess(pid, for: token)
                    }
                )
                result["succeeded"] = true
                result["replyReachedTheRun"] = outcome.text.contains("7391")
            } catch {
                result["succeeded"] = false
                result["failure"] = (error as? AgentTaskError)?.caseName ?? "unexpected"
            }
            result["toolCalls"] = calls.value
            // How many parents separate the connecting helper from the agent CLI the run started;
            // the server admits `AgentBridgeServer.maximumPeerDepth`.
            result["helperDepth"] = server.lastPeerDepth ?? NSNull()
            result["admittedDepth"] = AgentBridgeServer.maximumPeerDepth
            result["seconds"] = Date().timeIntervalSince(started)
            server.stop()
            try? FileManager.default.removeItem(at: folder)
            completion(result)
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }
}

/// Whether a real agent run can call the site tools the app serves to a scouting pass: the
/// tools are the ones `ProVisorTools` offers, answered by its own handler over a `SiteAccess`
/// that holds no grant. The run asks for a site nobody granted, so the answer is the
/// unknown-site sentence, which proves the call reached the handler and its reply came back.
///
/// Nothing here reads the user's registry, Keychain, or Messages database.
@MainActor
private final class ToolsCheck {
    private final class MemorySecretStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        func read(account: String) throws -> Data? {
            lock.withLock { items[account] }
        }

        func write(_ data: Data, account: String) throws {
            lock.withLock { items[account] = data }
        }

        func delete(account: String) throws {
            lock.withLock { _ = items.removeValue(forKey: account) }
        }
    }

    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    func start(completion: @escaping ([String: Any]) -> Void) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-check-\(suffix)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A socket of this check's own, so it never meets the one a running app is serving.
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("svt-\(suffix).sock").path

        let access = SiteAccess(
            vault: SiteVault(store: MemorySecretStore()),
            registryURL: folder.appendingPathComponent("sites.json"),
            codes: SignInCodes(
                authenticator: { _ in nil },
                texted: { _, _ in nil },
                emailed: { _, _ in nil },
                messageBaseline: { nil },
                firstTextedCode: { _ in nil }
            ),
            dataStore: .nonPersistent()
        )
        let tools = ProVisorTools(
            access: access,
            messages: MessagesStore(path: folder.appendingPathComponent("none.db").path),
            textsAreOn: { false }
        )
        // A record is what makes the site tools appear; no grant stands behind it.
        let offered = ProVisorTools.descriptors(
            sites: [SiteRecord(id: "nowhere.example", name: "Nowhere", added: Date())],
            awaiting: [],
            textsAreOn: false
        )

        let token = AgentBridgeServer.makeToken()
        let calls = CallCounter()
        let server = AgentBridgeServer(
            path: socketPath,
            version: AgentBridgeHelper.bundleVersion
        ) { token, tool, arguments in
            calls.increment()
            return await tools.handle(visit: token, tool: tool, arguments: arguments)
        }
        server.register(BridgeRun(token: token, rootProcess: nil, tools: offered))

        var result: [String: Any] = ["check": "tools"]
        let configurationURL = folder.appendingPathComponent("mcp.json")
        do {
            try server.start()
            let data = try JSONSerialization.data(withJSONObject: ["mcpServers": [ProVisorTools.server: [
                "type": "stdio",
                "command": Bundle.main.executablePath ?? "",
                "args": [AgentBridgeHelper.flag],
                "env": [
                    AgentBridgeHelper.tokenVariable: token,
                    AgentBridgeHelper.socketVariable: socketPath,
                ],
                "alwaysLoad": true,
            ] as [String: Any]]])
            FileManager.default.createFile(
                atPath: configurationURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        } catch {
            server.stop()
            try? FileManager.default.removeItem(at: folder)
            result["succeeded"] = false
            result["toolCalls"] = 0
            result["sawRefusal"] = false
            result["failure"] = "setup"
            completion(result)
            return
        }

        let arguments = [
            "-p", "Call open_site with the site 'nowhere.example' and reply with exactly what the tool returns.",
            "--output-format", "stream-json",
            "--verbose",
            "--restricted",
            "--permission-prompts", "none",
            "--no-session-persistence",
            "--tools", "",
            "--model", ProVisorCommand.utilityModel,
            "--max-turns", "4",
            "--max-budget-usd", "0.10",
            "--strict-mcp-config",
            "--mcp-config", configurationURL.path,
            "--allowedTools",
        ] + ProVisorTools.allowedToolRules(for: offered)

        Task { @MainActor in
            do {
                let outcome = try await AgentTaskService().run(
                    arguments: arguments,
                    workingDirectory: folder,
                    timeout: .seconds(120),
                    environment: [AgentBridgeHelper.socketVariable: socketPath],
                    onLaunch: { pid in
                        server.setRootProcess(pid, for: token)
                    }
                )
                result["succeeded"] = true
                result["sawRefusal"] = outcome.text.contains("No granted site matches")
            } catch {
                result["succeeded"] = false
                result["sawRefusal"] = false
                result["failure"] = (error as? AgentTaskError)?.caseName ?? "unexpected"
            }
            result["toolCalls"] = calls.value
            access.end(visit: token)
            server.stop()
            try? FileManager.default.removeItem(at: folder)
            completion(result)
        }
    }
}

/// Whether the account's connectors are up by the first turn of a run that carries the hold
/// configuration: three runs in a row each look up a Gmail tool with `ToolSearch`, and the report
/// counts the answers that name one. Each run starts in an empty folder of its own, and a
/// failed run counts as no tool found. The answers are never reported, only counts and times.
@MainActor
private final class ConnectorsCheck {
    private static let runs = 3

    func start(completion: @escaping ([String: Any]) -> Void) {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("connectors-check-\(suffix)", isDirectory: true)
        let configurations = root.appendingPathComponent("configuration", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        var result: [String: Any] = ["check": "connectors", "runs": Self.runs]

        let hold: URL
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            hold = try ProVisorBridge.writeHoldConfiguration(
                executablePath: Bundle.main.executablePath ?? "",
                into: configurations
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            result["foundTool"] = 0
            result["seconds"] = [Double]()
            result["failure"] = "setup"
            completion(result)
            return
        }

        let arguments = [
            "-p", "Use the ToolSearch tool to look for a tool that searches Gmail threads. Reply with its exact tool name, or the single word NONE.",
            "--output-format", "stream-json",
            "--verbose",
            "--restricted",
            "--permission-prompts", "none",
            "--no-session-persistence",
            "--tools", "ToolSearch",
            "--model", ProVisorCommand.utilityModel,
            "--max-turns", "4",
            "--max-budget-usd", "0.10",
            "--mcp-config", hold.path,
            "--allowedTools", "mcp__claude_ai_Gmail__search_*",
        ]

        Task { @MainActor in
            var found = 0
            var seconds: [Double] = []
            for _ in 0..<Self.runs {
                let started = Date()
                if let outcome = try? await AgentTaskService().run(
                    arguments: arguments,
                    workingDirectory: workspace,
                    timeout: .seconds(90)
                ), outcome.text.contains("mcp__claude_ai_Gmail__") {
                    found += 1
                }
                seconds.append(Date().timeIntervalSince(started))
            }
            result["foundTool"] = found
            result["seconds"] = seconds
            try? FileManager.default.removeItem(at: root)
            completion(result)
        }
    }
}
