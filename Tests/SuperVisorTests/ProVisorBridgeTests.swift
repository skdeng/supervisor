import Darwin
import Foundation
import Testing
import WebKit

@testable import SuperVisor

private let sealed = ProVisorAccess(
    scout: ["mcp__claude_ai_Gmail__search_*", "mcp__claude_ai_Gmail__get_*"],
    act: ["mcp__claude_ai_Gmail__create_draft"],
    auto: []
)
private let unsealed = ProVisorAccess(
    scout: ["mcp__claude_ai_Gmail__search_*", "mcp__claude_ai_Gmail__send_message"],
    act: [],
    auto: []
)

private func grant(_ host: String = "example.com") -> SiteGrant {
    SiteGrant(
        username: "alice@example.com",
        password: "pw-\(UUID().uuidString)",
        authenticatorKey: nil,
        signInURL: URL(string: "https://\(host)/login")!,
        startURL: URL(string: "https://\(host)/account")!,
        fillHosts: [host],
        browseHosts: [host],
        codeKind: .none,
        codeSender: nil
    )
}

private func record(_ host: String = "example.com", name: String = "Bank") -> SiteRecord {
    SiteRecord(id: host, name: name, added: Date(timeIntervalSince1970: 1_700_000_000))
}

/// What the injected checks answer, changed by a test between calls.
@MainActor
private final class Conditions {
    var cliIsTrusted = true
    var disclaimIsAvailable = true
    var appIsIntact = true
}

/// A bridge over a site center on simulated pages, a server on a socket in a scratch folder, and
/// injected checks. Nothing here touches the user's registry, Keychain, Messages database, or
/// the app's real socket.
@MainActor
private final class BridgeFixture {
    static let version = "1.0-test"
    static let executable = "/Applications/SuperVisor.app/Contents/MacOS/SuperVisor"

    let site = TestSite()
    let sites: SiteCenterFixture
    let center: SiteAccessCenter
    let scratch = ScratchFolder()
    let conditions = Conditions()
    let handled = Recorder<String>()
    let runs: URL
    let bridge: ProVisorBridge
    var socketPath: String { scratch.path("b.sock") }

    /// With `realHandler`, the bridge makes its own server, on a socket here, and calls reach the
    /// tools it serves. Otherwise the server answers every call with a fixed reply.
    init(
        serverPath: String? = nil,
        runs: URL? = nil,
        executablePath: String = BridgeFixture.executable,
        realHandler: Bool = false
    ) throws {
        sites = try SiteCenterFixture()
        center = sites.center(simulatedPages: site.answer, settling: .fast)
        site.route("/account", page: TestPages.page("Account", "<p>Card on file: Amex ending 1001</p>"))

        let handled = self.handled
        let path = serverPath ?? scratch.path("b.sock")
        let version = Self.version
        let injected = realHandler ? nil : AgentBridgeServer(
            path: path,
            version: version,
            peerIsTrusted: { _ in true },
            rootIsTrusted: { _ in true }
        ) { token, tool, _ in
            handled.record("\(tool)|\(token)")
            return BridgeReply(text: "ran \(tool)")
        }
        let conditions = self.conditions
        self.runs = runs ?? scratch.url.appendingPathComponent("runs", isDirectory: true)
        bridge = ProVisorBridge(
            sites: center,
            server: injected,
            makeServer: { handler in
                AgentBridgeServer(
                    path: path,
                    version: version,
                    peerIsTrusted: { _ in true },
                    rootIsTrusted: { _ in true },
                    handler: handler
                )
            },
            configurationFolder: self.runs,
            executablePath: executablePath,
            cliIsTrusted: { conditions.cliIsTrusted },
            disclaimIsAvailable: { conditions.disclaimIsAvailable },
            appIsIntact: { conditions.appIsIntact }
        )
    }

    func tearDown() {
        bridge.stop()
        scratch.remove()
    }

    func grantSite(_ host: String = "example.com", name: String = "Bank") throws {
        try center.save(grant: grant(host), record: record(host, name: name))
    }

    func prepared(access: ProVisorAccess = sealed) throws -> ProVisorBridge.PreparedRun {
        switch bridge.prepare(access: access) {
        case let .success(run): return run
        case let .failure(reason): throw PreparationFailure(reason: reason)
        }
    }

    struct PreparationFailure: Error { let reason: ProVisorBridge.Unavailable }

    func request(
        _ run: ProVisorBridge.PreparedRun,
        kind: BridgeRequest.Kind = .call,
        tool: String? = "read_texts",
        arguments: JSONValue = .object([:])
    ) -> BridgeRequest {
        BridgeRequest(
            token: run.token,
            version: Self.version,
            kind: kind,
            tool: kind == .list ? nil : tool,
            arguments: kind == .list ? nil : arguments
        )
    }

    var configurationFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: runs.path)) ?? []).sorted()
    }
}

@Suite("ProVisor bridge", .serialized)
@MainActor
struct ProVisorBridgeTests {
    // MARK: Whether a pass may carry the bridge

    @Test("With nothing granted and texts off there is nothing to offer, and no run is made")
    func nothingGranted() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }

        let result = fixture.bridge.prepare(access: sealed)

        #expect(result == .failure(.nothingGranted))
        #expect(fixture.bridge.lastUnavailable == .nothingGranted)
        #expect(fixture.configurationFiles.isEmpty)
        #expect(fixture.bridge.availableSiteNames(access: sealed).isEmpty)
    }

    @Test("A scout list with a rule that is not known to be read-only keeps the bridge off")
    func accessNotSealed() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()

        #expect(fixture.bridge.prepare(access: unsealed) == .failure(.accessNotSealed))
        #expect(fixture.bridge.lastUnavailable == .accessNotSealed)
        #expect(fixture.configurationFiles.isEmpty)
        #expect(fixture.bridge.availableSiteNames(access: unsealed).isEmpty)
    }

    @Test("A system that cannot start the agent responsible for itself keeps the bridge off")
    func disclaimUnavailable() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()
        fixture.conditions.disclaimIsAvailable = false

        #expect(fixture.bridge.prepare(access: sealed) == .failure(.disclaimUnavailable))
        #expect(fixture.bridge.lastUnavailable == .disclaimUnavailable)
        #expect(fixture.configurationFiles.isEmpty)
    }

    @Test("An agent CLI that is not the signed build keeps the bridge off")
    func cliNotTrusted() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()
        fixture.conditions.cliIsTrusted = false

        #expect(fixture.bridge.prepare(access: sealed) == .failure(.cliNotTrusted))
        #expect(fixture.bridge.lastUnavailable == .cliNotTrusted)
        #expect(fixture.configurationFiles.isEmpty)
        #expect(fixture.bridge.availableSiteNames(access: sealed).isEmpty)
    }

    @Test("An app whose bundle was replaced under it keeps the bridge off, and comes back when it is intact again")
    func appReplaced() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()
        fixture.conditions.appIsIntact = false

        #expect(fixture.bridge.prepare(access: sealed) == .failure(.appReplaced))
        #expect(fixture.bridge.lastUnavailable == .appReplaced)
        #expect(fixture.configurationFiles.isEmpty)
        #expect(fixture.bridge.availableSiteNames(access: sealed).isEmpty)

        fixture.conditions.appIsIntact = true
        guard case .success = fixture.bridge.prepare(access: sealed) else {
            Issue.record("the bridge stayed off once the app was intact")
            return
        }
        #expect(fixture.bridge.lastUnavailable == nil)
    }

    @Test("The reasons are reported in a fixed order, each only when the ones before it hold")
    func reasonOrder() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.conditions.cliIsTrusted = false
        fixture.conditions.disclaimIsAvailable = false
        fixture.conditions.appIsIntact = false

        // Nothing granted outranks everything.
        #expect(fixture.bridge.prepare(access: unsealed) == .failure(.nothingGranted))
        try fixture.grantSite()
        #expect(fixture.bridge.prepare(access: unsealed) == .failure(.accessNotSealed))
        #expect(fixture.bridge.prepare(access: sealed) == .failure(.disclaimUnavailable))
        fixture.conditions.disclaimIsAvailable = true
        #expect(fixture.bridge.prepare(access: sealed) == .failure(.cliNotTrusted))
        fixture.conditions.cliIsTrusted = true
        #expect(fixture.bridge.prepare(access: sealed) == .failure(.appReplaced))
        fixture.conditions.appIsIntact = true
        _ = try fixture.prepared()
        #expect(fixture.bridge.lastUnavailable == nil)
    }

    @Test("A tool channel that cannot start keeps the bridge off, and leaves no file behind")
    func serverFailed() throws {
        let fixture = try BridgeFixture(serverPath: "/tmp/" + String(repeating: "a", count: 200))
        defer { fixture.tearDown() }
        try fixture.grantSite()

        #expect(fixture.bridge.prepare(access: sealed) == .failure(.serverFailed))
        #expect(fixture.bridge.lastUnavailable == .serverFailed)
        #expect(fixture.configurationFiles.isEmpty)
    }

    @Test("A configuration that cannot be written keeps the bridge off")
    func configurationNotWritten() throws {
        let scratch = ScratchFolder()
        defer { scratch.remove() }
        let notAFolder = scratch.url.appendingPathComponent("file")
        try Data("x".utf8).write(to: notAFolder)

        let blocked = try BridgeFixture(runs: notAFolder.appendingPathComponent("runs"))
        defer { blocked.tearDown() }
        try blocked.grantSite()
        #expect(blocked.bridge.prepare(access: sealed) == .failure(.serverFailed))

        let noExecutable = try BridgeFixture(executablePath: "")
        defer { noExecutable.tearDown() }
        try noExecutable.grantSite()
        #expect(noExecutable.bridge.prepare(access: sealed) == .failure(.serverFailed))
        #expect(noExecutable.configurationFiles.isEmpty)
    }

    @Test("A run that fails to prepare does not leave an earlier run's reason standing")
    func reasonFollowsTheLastPrepare() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()

        #expect(fixture.bridge.prepare(access: unsealed) == .failure(.accessNotSealed))
        let run = try fixture.prepared()
        #expect(fixture.bridge.lastUnavailable == nil)
        fixture.bridge.finished(run)
    }

    // MARK: What a prepared run carries

    @Test("Granted sites bring the three site tools, and texts bring read_texts")
    func preparedTools() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }

        try fixture.grantSite()
        try fixture.grantSite("power.example.org", name: "City Power")
        let sitesOnly = try fixture.prepared()
        #expect(sitesOnly.bridge.toolRules == [
            "mcp__supervisor__open_site",
            "mcp__supervisor__follow_link",
            "mcp__supervisor__read_more",
        ])
        #expect(sitesOnly.bridge.siteNames == ["Bank (example.com)", "City Power (power.example.org)"])
        #expect(!sitesOnly.bridge.textsAreOn)
        #expect(!sitesOnly.bridge.photoPlacesAreOn)
        #expect(sitesOnly.bridge.configurationPath == sitesOnly.configurationURL.path)

        fixture.sites.settings.provisorReadsTexts = true
        let both = try fixture.prepared()
        #expect(both.bridge.toolRules.count == 4)
        #expect(both.bridge.toolRules.last == "mcp__supervisor__read_texts")
        #expect(both.bridge.textsAreOn)
        #expect(both.token != sitesOnly.token)
        #expect(both.configurationURL != sitesOnly.configurationURL)
    }

    @Test("Texts alone are enough to offer read_texts, with no site names")
    func textsOnly() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true

        let run = try fixture.prepared()

        #expect(run.bridge.toolRules == ["mcp__supervisor__read_texts"])
        #expect(run.bridge.siteNames.isEmpty)
        #expect(run.bridge.textsAreOn)
        #expect(fixture.bridge.availableSiteNames(access: sealed).isEmpty)
    }

    @Test("The configuration file is private, outside the workspace, and holds the token and nothing the command line shows")
    func configurationFile() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()

        let run = try fixture.prepared()

        let attributes = try FileManager.default.attributesOfItem(atPath: run.configurationURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: fixture.runs.path)
        #expect(folder[.posixPermissions] as? Int == 0o700)
        #expect(run.configurationURL.deletingLastPathComponent() == fixture.runs)
        #expect(
            run.configurationURL.lastPathComponent
                .range(of: #"\A[0-9a-f]{8}\.json\z"#, options: .regularExpression) != nil
        )
        #expect(run.token.range(of: #"\A[0-9a-f]{32}\z"#, options: .regularExpression) != nil)

        let data = try Data(contentsOf: run.configurationURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["supervisor"])
        let entry = try #require(servers["supervisor"] as? [String: Any])
        #expect(entry["type"] as? String == "stdio")
        #expect(entry["command"] as? String == BridgeFixture.executable)
        #expect(entry["args"] as? [String] == ["--agent-bridge"])
        #expect(entry["env"] as? [String: String] == [
            "SUPERVISOR_BRIDGE_TOKEN": run.token,
            "SUPERVISOR_BRIDGE_SETTLE_MS": "6000",
        ])
        #expect(entry["alwaysLoad"] as? Bool == true)

        // What goes on the command line names the file, never the credential in it.
        let commandLine = [run.bridge.configurationPath] + run.bridge.toolRules + run.bridge.siteNames
        #expect(!commandLine.contains { $0.contains(run.token) })
    }

    @Test("Configurations live beside access.json, out of the agent's working directory")
    func defaultFolder() {
        let workspace = ProVisorHome.workspaceURL.standardizedFileURL.path + "/"

        #expect(ProVisorHome.runsURL.deletingLastPathComponent() == ProVisorHome.accessURL.deletingLastPathComponent())
        #expect(ProVisorHome.runsURL.lastPathComponent == "runs")
        #expect(!ProVisorHome.runsURL.standardizedFileURL.path.hasPrefix(workspace))
    }

    // MARK: The run's lifetime

    @Test("A launched run's own process reaches its tools through the server, as the run's visit")
    func launchedRunReachesTools() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let run = try fixture.prepared()
        fixture.bridge.launched(run, pid: getpid())

        let listed = try #require(
            await BridgeTestClient.exchange(fixture.request(run, kind: .list), at: fixture.socketPath)
        )
        #expect(listed.tools?.map(\.name) == ["read_texts"])

        let answered = try #require(
            await BridgeTestClient.exchange(fixture.request(run), at: fixture.socketPath)
        )
        #expect(answered == BridgeReply(text: "ran read_texts"))
        #expect(fixture.handled.all == ["read_texts|\(run.token)"])
    }

    @Test("Finishing a run retires its token, deletes its file, and is safe to repeat")
    func finishing() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let run = try fixture.prepared()
        fixture.bridge.launched(run, pid: getpid())
        let before = try #require(
            await BridgeTestClient.exchange(fixture.request(run), at: fixture.socketPath)
        )
        #expect(!before.isError)
        #expect(fixture.configurationFiles.count == 1)

        fixture.bridge.finished(run)
        fixture.bridge.finished(run)

        #expect(fixture.configurationFiles.isEmpty)
        let after = try #require(
            await BridgeTestClient.exchange(fixture.request(run), at: fixture.socketPath)
        )
        #expect(after == .failure("SuperVisor does not recognize this run."))
        #expect(fixture.handled.all.count == 1)
    }

    @Test("Finishing a run closes the site it had open", .timeLimit(.minutes(1)))
    func finishingEndsTheVisit() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()
        let run = try fixture.prepared()

        let opened = await fixture.center.access.open(siteID: "example.com", visit: run.token)
        #expect((try? opened.get()) != nil)
        #expect(fixture.center.access.currentPage(visit: run.token) != nil)
        #expect(fixture.center.access.siteID(visit: run.token) == "example.com")

        fixture.bridge.finished(run)

        #expect(fixture.center.access.currentPage(visit: run.token) == nil)
        #expect(fixture.center.access.siteID(visit: run.token) == nil)
    }

    @Test("Each run has a token of its own, and finishing one leaves the other working")
    func runsAreIndependent() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let first = try fixture.prepared()
        let second = try fixture.prepared()
        fixture.bridge.launched(first, pid: getpid())
        fixture.bridge.launched(second, pid: getpid())

        fixture.bridge.finished(first)

        let refused = try #require(
            await BridgeTestClient.exchange(fixture.request(first), at: fixture.socketPath)
        )
        let served = try #require(
            await BridgeTestClient.exchange(fixture.request(second), at: fixture.socketPath)
        )
        #expect(refused.isError)
        #expect(!served.isError)
        #expect(fixture.configurationFiles == [second.configurationURL.lastPathComponent])
    }

    @Test("Stopping ends every live run and closes the channel")
    func stopping() async throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let run = try fixture.prepared()
        fixture.bridge.launched(run, pid: getpid())
        let before = try #require(
            await BridgeTestClient.exchange(fixture.request(run), at: fixture.socketPath)
        )
        #expect(!before.isError)

        fixture.bridge.stop()

        #expect(fixture.configurationFiles.isEmpty)
        #expect(await BridgeTestClient.exchange(fixture.request(run), at: fixture.socketPath, timeout: 2) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    // MARK: Leftovers

    @Test("Configurations left by runs that never finished are swept, and nothing else is")
    func staleConfigurations() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let live = try fixture.prepared()
        let stale = ["0a1b2c3d.json", "ffffffff.json"]
        let kept = ["notes.txt", "ABCDEF01.json", "0a1b2c3.json", "0a1b2c3d4.json", "0a1b2c3d.json.bak"]
        for name in stale + kept {
            try Data("{}".utf8).write(to: fixture.runs.appendingPathComponent(name))
        }

        fixture.bridge.removeStaleConfigurations()

        #expect(fixture.configurationFiles == (kept + [live.configurationURL.lastPathComponent]).sorted())
    }

    @Test("Sweeping a folder that does not exist does nothing")
    func sweepWithoutFolder() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }

        fixture.bridge.removeStaleConfigurations()

        #expect(!FileManager.default.fileExists(atPath: fixture.runs.path))
    }

    // MARK: Asking without preparing

    @Test("Asking which sites a pass could read makes no run and leaves the last reason alone")
    func availableSiteNames() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()
        try fixture.grantSite("power.example.org", name: "City Power")

        #expect(fixture.bridge.prepare(access: unsealed) == .failure(.accessNotSealed))
        #expect(fixture.bridge.availableSiteNames(access: sealed) == ["Bank (example.com)", "City Power (power.example.org)"])

        #expect(fixture.bridge.lastUnavailable == .accessNotSealed)
        #expect(!FileManager.default.fileExists(atPath: fixture.runs.path))
        #expect(fixture.bridge.availableSiteNames(access: unsealed).isEmpty)
        fixture.conditions.disclaimIsAvailable = false
        #expect(fixture.bridge.availableSiteNames(access: sealed).isEmpty)
    }

    @Test("A site that is flagged, or that a run was turned away from, is named as waiting in what a pass is told")
    func waitingSitesAreLabelled() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try fixture.grantSite()
        try fixture.grantSite("power.example.org", name: "City Power")
        try fixture.grantSite("water.example.net", name: "Water")
        var flagged = try #require(fixture.center.access.sites().first { $0.id == "water.example.net" })
        flagged.needsPerson = true
        try SiteRegistry.save(
            fixture.center.access.sites().map { $0.id == flagged.id ? flagged : $0 },
            to: fixture.sites.registry
        )
        fixture.center.access.onPersonNeeded?("power.example.org")
        let waiting = "; waiting for them to sign in again)"
        let expected = [
            "Bank (example.com)",
            "City Power (power.example.org" + waiting,
            "Water (water.example.net" + waiting,
        ]

        #expect(fixture.bridge.availableSiteNames(access: sealed) == expected)
        let run = try fixture.prepared()
        #expect(run.bridge.siteNames == expected)
    }

    // MARK: Asking about the conditions

    @Test("Evaluating reports why the tools are off, makes no run, and clears the reason when they are on")
    func evaluate() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }

        #expect(fixture.bridge.evaluate(access: sealed) == .nothingGranted)
        #expect(fixture.bridge.lastUnavailable == .nothingGranted)
        try fixture.grantSite()
        #expect(fixture.bridge.evaluate(access: unsealed) == .accessNotSealed)
        fixture.conditions.disclaimIsAvailable = false
        #expect(fixture.bridge.evaluate(access: sealed) == .disclaimUnavailable)
        fixture.conditions.disclaimIsAvailable = true
        fixture.conditions.cliIsTrusted = false
        #expect(fixture.bridge.evaluate(access: sealed) == .cliNotTrusted)
        fixture.conditions.cliIsTrusted = true
        #expect(fixture.bridge.evaluate(access: sealed) == nil)
        #expect(fixture.bridge.lastUnavailable == nil)

        #expect(!FileManager.default.fileExists(atPath: fixture.runs.path))
    }

    @Test("A failed tool channel stays reported until a run is prepared")
    func evaluateKeepsFailedChannel() throws {
        let fixture = try BridgeFixture(serverPath: "/tmp/" + String(repeating: "a", count: 200))
        defer { fixture.tearDown() }
        try fixture.grantSite()
        #expect(fixture.bridge.prepare(access: sealed) == .failure(.serverFailed))

        #expect(fixture.bridge.evaluate(access: sealed) == .serverFailed)
        #expect(fixture.bridge.lastUnavailable == .serverFailed)
        // A reason that can be checked without a run replaces it.
        #expect(fixture.bridge.evaluate(access: unsealed) == .accessNotSealed)
    }

    // MARK: Calls that outlive their run

    @Test("A call for a run that has ended is refused before it touches a site", .timeLimit(.minutes(1)))
    func callAfterEnd() async throws {
        let fixture = try BridgeFixture(realHandler: true)
        defer { fixture.tearDown() }
        try fixture.grantSite()
        let run = try fixture.prepared()
        fixture.bridge.finished(run)

        let reply = await fixture.bridge.serve(
            token: run.token,
            tool: "open_site",
            arguments: .object(["site": .string("example.com")])
        )

        #expect(reply == .failure("This run has ended."))
        #expect(fixture.site.requests.isEmpty)
        #expect(fixture.center.access.siteID(visit: run.token) == nil)
        let unknown = await fixture.bridge.serve(token: String(repeating: "0", count: 32), tool: "open_site", arguments: .object([:]))
        #expect(unknown == .failure("This run has ended."))
    }

    @Test("Photo places alone are enough to offer read_photo_places, and come after read_texts")
    func photoPlacesOnly() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        #expect(fixture.bridge.prepare(access: sealed) == .failure(.nothingGranted))

        fixture.sites.settings.provisorReadsPhotoPlaces = true
        let run = try fixture.prepared()
        #expect(run.bridge.toolRules == ["mcp__supervisor__read_photo_places"])
        #expect(run.bridge.photoPlacesAreOn)
        #expect(!run.bridge.textsAreOn)
        #expect(run.bridge.siteNames.isEmpty)

        fixture.sites.settings.provisorReadsTexts = true
        let both = try fixture.prepared()
        #expect(both.bridge.toolRules == [
            "mcp__supervisor__read_texts",
            "mcp__supervisor__read_photo_places",
        ])
    }

    @Test("A photo-places call for a live run follows the setting", .timeLimit(.minutes(1)))
    func photoPlacesCallWhileLive() async throws {
        let fixture = try BridgeFixture(realHandler: true)
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsPhotoPlaces = true
        let run = try fixture.prepared()

        let on = await fixture.bridge.serve(token: run.token, tool: "read_photo_places", arguments: .object([:]))
        #expect(on == BridgeReply(text: "No photos with a position were taken in that range."))

        fixture.sites.settings.provisorReadsPhotoPlaces = false
        let off = await fixture.bridge.serve(token: run.token, tool: "read_photo_places", arguments: .object([:]))
        #expect(off == .failure("Reading where photos were taken is switched off."))
    }

    @Test("A call for a live run reaches the tools", .timeLimit(.minutes(1)))
    func callWhileLive() async throws {
        let fixture = try BridgeFixture(realHandler: true)
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let run = try fixture.prepared()

        let on = await fixture.bridge.serve(token: run.token, tool: "read_texts", arguments: .object([:]))
        #expect(on == BridgeReply(text: "No texts match."))

        fixture.sites.settings.provisorReadsTexts = false
        let off = await fixture.bridge.serve(token: run.token, tool: "read_texts", arguments: .object([:]))
        #expect(off == .failure("Reading texts is switched off."))
    }

    @Test("A run that ends while its call is under way leaves no visit behind", .timeLimit(.minutes(1)))
    func runEndsDuringCall() async throws {
        let fixture = try BridgeFixture(realHandler: true)
        defer { fixture.tearDown() }
        try fixture.grantSite()
        let run = try fixture.prepared()
        fixture.bridge.launched(run, pid: getpid())
        let request = fixture.request(
            run,
            tool: "open_site",
            arguments: .object(["site": .string("example.com")])
        )

        async let reply = BridgeTestClient.exchange(request, at: fixture.socketPath)
        var polls = 0
        while fixture.site.requests.isEmpty, polls < 500 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(!fixture.site.requests.isEmpty, "the call reached the site")
        fixture.bridge.finished(run)
        _ = await reply

        #expect(fixture.center.access.siteID(visit: run.token) == nil)
        #expect(fixture.center.access.currentPage(visit: run.token) == nil)
        let later = try #require(await BridgeTestClient.exchange(request, at: fixture.socketPath))
        #expect(later == .failure("SuperVisor does not recognize this run."))
    }

    // MARK: The connector hold

    private func holdEntry(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["supervisor"])
        return try #require(servers["supervisor"] as? [String: Any])
    }

    @Test("The settle time is six seconds, and the helper is told it in milliseconds")
    func settleTime() {
        #expect(ProVisorBridge.connectorSettle == .seconds(6))
        #expect(ProVisorBridge.connectorSettleMilliseconds == 6_000)
        #expect(
            AgentBridgeHelper.settleMilliseconds(environment: [
                AgentBridgeHelper.settleVariable: String(ProVisorBridge.connectorSettleMilliseconds),
            ]) == 6_000
        )
    }

    @Test("The hold configuration starts the helper with the settle time and no token, in a private file")
    func holdConfiguration() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }

        let path = try #require(fixture.bridge.holdConfigurationPath())

        #expect(URL(fileURLWithPath: path).deletingLastPathComponent() == fixture.runs)
        #expect(URL(fileURLWithPath: path).lastPathComponent == "connector-hold.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: fixture.runs.path)
        #expect(folder[.posixPermissions] as? Int == 0o700)

        let entry = try holdEntry(path)
        #expect(entry["type"] as? String == "stdio")
        #expect(entry["command"] as? String == BridgeFixture.executable)
        #expect(entry["args"] as? [String] == ["--agent-bridge"])
        #expect(entry["env"] as? [String: String] == ["SUPERVISOR_BRIDGE_SETTLE_MS": "6000"])
        #expect(entry["alwaysLoad"] as? Bool == true)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains("SUPERVISOR_BRIDGE_TOKEN"))
    }

    @Test("The hold configuration is written once, and again after it is deleted or the bridge stops")
    func holdIsWrittenOncePerStart() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }

        let first = try #require(fixture.bridge.holdConfigurationPath())
        let before = try FileManager.default.attributesOfItem(atPath: first)
        let second = try #require(fixture.bridge.holdConfigurationPath())
        let after = try FileManager.default.attributesOfItem(atPath: second)
        #expect(second == first)
        #expect(before[.systemFileNumber] as? Int == after[.systemFileNumber] as? Int)
        #expect(before[.modificationDate] as? Date == after[.modificationDate] as? Date)

        try FileManager.default.removeItem(atPath: first)
        let rewritten = try #require(fixture.bridge.holdConfigurationPath())
        #expect(FileManager.default.fileExists(atPath: rewritten))

        fixture.bridge.stop()
        #expect(!FileManager.default.fileExists(atPath: rewritten))
        let restarted = try #require(fixture.bridge.holdConfigurationPath())
        #expect(FileManager.default.fileExists(atPath: restarted))
        #expect(fixture.configurationFiles == ["connector-hold.json"])
    }

    @Test("Without an executable to start there is no hold configuration")
    func holdNeedsAnExecutable() throws {
        let fixture = try BridgeFixture(executablePath: "")
        defer { fixture.tearDown() }

        #expect(fixture.bridge.holdConfigurationPath() == nil)
        #expect(fixture.configurationFiles.isEmpty)
    }

    @Test("A run's own configuration carries the settle time beside its token, and the hold carries no token")
    func holdAndRunConfigurationsDiffer() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        fixture.sites.settings.provisorReadsTexts = true
        let run = try fixture.prepared()
        let hold = try #require(fixture.bridge.holdConfigurationPath())

        let runEnvironment = try #require(try holdEntry(run.configurationURL.path)["env"] as? [String: String])
        let holdEnvironment = try #require(try holdEntry(hold)["env"] as? [String: String])

        #expect(runEnvironment == [
            "SUPERVISOR_BRIDGE_TOKEN": run.token, "SUPERVISOR_BRIDGE_SETTLE_MS": "6000",
        ])
        #expect(holdEnvironment == ["SUPERVISOR_BRIDGE_SETTLE_MS": "6000"])
        #expect(Set(fixture.configurationFiles) == [run.configurationURL.lastPathComponent, "connector-hold.json"])
    }

    @Test("The hold configuration is swept when left over, and kept while the bridge holds it")
    func holdSweep() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(at: fixture.runs, withIntermediateDirectories: true)
        for name in ["connector-hold.json", ".connector-hold-0a1b2c3d.tmp", "notes.txt"] {
            try Data("{}".utf8).write(to: fixture.runs.appendingPathComponent(name))
        }

        fixture.bridge.removeStaleConfigurations()
        #expect(fixture.configurationFiles == ["notes.txt"])

        _ = try #require(fixture.bridge.holdConfigurationPath())
        fixture.bridge.removeStaleConfigurations()
        #expect(fixture.configurationFiles == ["connector-hold.json", "notes.txt"])
    }

    @Test("Every run that carries the hold names a file with no token, and no run but a bridge's has a supervisor rule")
    func holdOnEveryRunKind() throws {
        let fixture = try BridgeFixture()
        defer { fixture.tearDown() }
        let path = try #require(fixture.bridge.holdConfigurationPath())
        let now = Date(timeIntervalSince1970: 1_794_762_720)
        let proposal = Proposal(
            id: "a", title: "Cancel Foo Pro", why: nil,
            options: [ProposalOption(label: "Draft it", action: "Draft the cancellation email.")],
            kind: nil, created: Date(timeIntervalSince1970: 0), expires: nil,
            status: .proposed, result: nil, isCleared: false
        )
        let rule = StandingRule(
            id: "s-0000abcd", condition: "It is Tuesday", action: "Trash promotional mail",
            since: Date(timeIntervalSince1970: 0), revoked: nil
        )
        let gmail = ProVisorAccess(
            scout: ["mcp__claude_ai_Gmail__search_*"],
            act: ["mcp__claude_ai_Gmail__create_draft"],
            auto: ["mcp__claude_ai_Gmail__trash_*"]
        )
        let runs: [[String]] = [
            ProVisorCommand.approvedArguments(
                proposal: proposal, option: proposal.options[0], access: gmail, now: now,
                siteNames: ["Bank"], connectorHold: path
            ),
            ProVisorCommand.instructedArguments(
                proposal: proposal, instruction: "Archive.", reference: proposal.options[0],
                access: gmail, now: now, siteNames: ["Bank"], connectorHold: path
            ),
            ProVisorCommand.automaticArguments(
                proposal: proposal, rule: rule, access: gmail, now: now, connectorHold: path
            ),
            try #require(ProVisorCommand.emailedCodeArguments(
                sender: "no-reply@clear.example", since: now, access: gmail, connectorHold: path
            )),
        ]

        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!text.contains("SUPERVISOR_BRIDGE_TOKEN"))
        for arguments in runs {
            #expect(arguments.filter { $0 == "--mcp-config" }.count == 1)
            let value = arguments.firstIndex(of: "--mcp-config").map { arguments[$0 + 1] }
            #expect(value == path)
            #expect(!arguments.contains { $0.contains("mcp__supervisor__") })
        }
    }
}

// MARK: - The installed CLI's trust

@Suite("Installed CLI trust")
@MainActor
struct InstalledCLITrustTests {
    private func makeFile(_ scratch: ScratchFolder, _ contents: String = "v1") throws -> URL {
        let url = scratch.url.appendingPathComponent("claude")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("A file is judged once and the answer kept while it stays as it was")
    func remembersTheAnswer() throws {
        let scratch = ScratchFolder()
        defer { scratch.remove() }
        let file = try makeFile(scratch)
        var judged = 0
        let trust = InstalledCLITrust(resolve: { file }, check: { _ in
            judged += 1
            return true
        })

        #expect(trust.isTrusted())
        #expect(trust.isTrusted())
        #expect(trust.isTrusted())

        #expect(judged == 1)
    }

    @Test("A file that changed in size or modification time is judged again")
    func changesAreJudgedAgain() throws {
        let scratch = ScratchFolder()
        defer { scratch.remove() }
        let file = try makeFile(scratch)
        var answers = [true, false, true]
        var judged = 0
        let trust = InstalledCLITrust(resolve: { file }, check: { _ in
            judged += 1
            return answers.isEmpty ? false : answers.removeFirst()
        })

        #expect(trust.isTrusted())
        // A longer file.
        try Data("version two".utf8).write(to: file)
        #expect(!trust.isTrusted())
        #expect(!trust.isTrusted())
        #expect(judged == 2)

        // The same size, a later modification time.
        try Data("version 3!!".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: file.path
        )
        #expect(trust.isTrusted())
        #expect(judged == 3)
    }

    @Test("A file whose status changed and nothing else is judged again")
    func statusChangeIsJudgedAgain() throws {
        let scratch = ScratchFolder()
        defer { scratch.remove() }
        let file = try makeFile(scratch)
        var judged = 0
        let trust = InstalledCLITrust(resolve: { file }, check: { _ in
            judged += 1
            return true
        })
        #expect(trust.isTrusted())
        #expect(judged == 1)

        // A change of mode alters the status-change time and leaves the size, inode, and
        // modification time as they were.
        var before = stat()
        #expect(stat(file.path, &before) == 0)
        #expect(chmod(file.path, 0o700) == 0)
        var after = stat()
        #expect(stat(file.path, &after) == 0)
        #expect(before.st_size == after.st_size)
        #expect(before.st_ino == after.st_ino)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
        #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)

        #expect(trust.isTrusted())
        #expect(judged == 2)
    }

    @Test("A refusal is remembered as well, and a replaced file behind a link is judged afresh")
    func refusalsAndLinks() throws {
        let scratch = ScratchFolder()
        defer { scratch.remove() }
        let first = try makeFile(scratch, "first build")
        let second = scratch.url.appendingPathComponent("second")
        try Data("second build!".utf8).write(to: second)
        let link = scratch.url.appendingPathComponent("current")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        var judged: [String] = []
        let trust = InstalledCLITrust(resolve: { link }, check: { url in
            judged.append(url.lastPathComponent)
            return url.resolvingSymlinksInPath().lastPathComponent == "second"
        })

        #expect(!trust.isTrusted())
        #expect(!trust.isTrusted())
        #expect(judged.count == 1)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        #expect(trust.isTrusted())
        #expect(judged.count == 2)
    }

    @Test("No CLI, or a path that is no file, is not trusted and is not judged")
    func missingCLI() throws {
        let scratch = ScratchFolder()
        defer { scratch.remove() }
        var judged = 0
        let none = InstalledCLITrust(resolve: { nil }, check: { _ in
            judged += 1
            return true
        })
        let missing = InstalledCLITrust(
            resolve: { scratch.url.appendingPathComponent("gone") },
            check: { _ in
                judged += 1
                return true
            }
        )
        let folder = InstalledCLITrust(resolve: { scratch.url }, check: { _ in
            judged += 1
            return true
        })

        #expect(!none.isTrusted())
        #expect(!missing.isTrusted())
        #expect(!folder.isTrusted())
        #expect(judged == 0)
    }
}
