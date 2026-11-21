import Foundation
import Testing
import WebKit

@testable import SuperVisor

/// A center on a scratch folder and defaults of its own, with a sync a test scripts.
@MainActor
private final class CenterFixture {
    let folder = ScratchFolder()
    let defaultsName = "direct-messages-\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: SettingsStore
    let store: DirectMessageStore
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Whether the sync that was held saw its task cancelled.
    private(set) var heldSyncWasCancelled = false
    /// What the next syncs answer, first first; nil stands for limits that could not be set.
    var results: [DirectMessageSync.Result?] = []
    private(set) var runs = 0
    private var runningNow = 0
    private(set) var maximumConcurrentRuns = 0
    /// When set, a sync waits here until the test lets it go.
    var gate: CheckedContinuation<Void, Never>?
    var holdsSyncs = false

    init() {
        defaults = UserDefaults(suiteName: defaultsName)!
        settings = SettingsStore(defaults: defaults)
        store = DirectMessageStore(directory: folder.url.appendingPathComponent("dm", isDirectory: true))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    func center() -> DirectMessageCenter {
        DirectMessageCenter(
            source: TestMessageSource.source,
            settings: settings,
            store: store,
            defaults: defaults,
            dataStore: dataStore,
            runner: { [unowned self] _ in
                self.runs += 1
                self.runningNow += 1
                self.maximumConcurrentRuns = max(self.maximumConcurrentRuns, self.runningNow)
                defer { self.runningNow -= 1 }
                if self.holdsSyncs {
                    await withCheckedContinuation { self.gate = $0 }
                    self.heldSyncWasCancelled = Task.isCancelled
                }
                return self.results.isEmpty ? nil : self.results.removeFirst()
            },
            now: { [now] in now }
        )
    }

    func synced(chats: Int = 2) -> DirectMessageSync.Result {
        let threads = (0..<chats).map { index in
            DirectMessageThread(
                id: "t\(index)", title: nil, participants: ["maya"], isGroup: false,
                lastActivity: now.addingTimeInterval(Double(-index)), isUnread: nil,
                messages: [DirectMessage(
                    id: "m\(index)", sent: now.addingTimeInterval(-60), isFromViewer: false,
                    sender: "maya", text: "hello", shared: nil
                )]
            )
        }
        return DirectMessageSync.Result(
            outcome: .synced,
            snapshot: DirectMessageSnapshot(source: "test-source", syncedAt: now, threads: threads)
        )
    }

    func waitForHeldSync() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while gate == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        holdsSyncs = false
        gate?.resume()
        gate = nil
    }

    func setSessionCookie() async {
        let cookie = HTTPCookie(properties: [
            .domain: "chat.example.com", .path: "/", .name: "sessionid", .value: "abc", .secure: true,
        ])!
        await dataStore.httpCookieStore.setCookie(cookie)
    }

    func cookieCount() async -> Int {
        await dataStore.httpCookieStore.allCookies().count
    }

    func signInModel(for center: DirectMessageCenter) -> (DirectMessageSignInModel, TestSite) {
        let site = TestSite()
        site.route("/accounts/login", host: TestMessageSource.host, page: TestPages.page("Log in", "<p>Log in</p>"))
        return (DirectMessageSignInModel(center: center, pages: site.answer, settling: .fast), site)
    }
}

@Suite("Direct message center")
@MainActor
struct DirectMessageCenterTests {
    private typealias State = DirectMessageCenter.SignInState

    @Test("The status follows the setting, the sign-in, and the snapshot")
    func statuses() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = DirectMessageSnapshot(source: "s", syncedAt: date, threads: [])

        #expect(DirectMessageCenter.status(enabled: false, state: State(signedIn: date), snapshot: snapshot) == .off)
        #expect(DirectMessageCenter.status(enabled: true, state: State(), snapshot: nil) == .notSignedIn)
        #expect(
            DirectMessageCenter.status(enabled: true, state: State(signedIn: date, needsPerson: true), snapshot: snapshot)
                == .needsYou
        )
        #expect(
            DirectMessageCenter.status(enabled: true, state: State(signedIn: date), snapshot: nil)
                == .signedIn(lastSync: nil, chats: 0)
        )
        #expect(
            DirectMessageCenter.status(enabled: true, state: State(signedIn: date), snapshot: snapshot)
                == .signedIn(lastSync: date, chats: 0)
        )
    }

    @Test("A sync starts only while the source is on, signed in, not waiting on the person, and idle")
    func refusals() {
        let signedIn = State(signedIn: Date(timeIntervalSince1970: 1))
        func refusal(
            enabled: Bool = true, state: State = signedIn, signingIn: Bool = false, syncing: Bool = false
        ) -> DirectMessageCenter.Refusal? {
            DirectMessageCenter.refusal(enabled: enabled, state: state, isSigningIn: signingIn, isSyncing: syncing)
        }

        #expect(refusal() == nil)
        #expect(refusal(enabled: false) == .off)
        #expect(refusal(state: State()) == .notSignedIn)
        #expect(refusal(state: State(signedIn: Date(), needsPerson: true)) == .needsYou)
        #expect(refusal(signingIn: true) == .signingIn)
        #expect(refusal(syncing: true) == .alreadySyncing)
    }

    @Test("Switched on and never signed in, the source waits for a sign-in and makes no sync")
    func startsSignedOut() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        #expect(center.status == .off)

        center.setEnabled(true)

        #expect(center.status == .notSignedIn)
        #expect(await center.sync() == nil)
        #expect(fixture.runs == 0)
    }

    @Test("A confirmed sign-in records the sign-in and saves the chats the check read")
    func confirmsSignIn() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced(chats: 3)]

        let outcome = await center.confirmSignIn()

        #expect(outcome == .synced)
        #expect(center.status == .signedIn(lastSync: fixture.now, chats: 3))
        #expect(center.snapshot()?.threads.count == 3)
        #expect(center.problem == nil)
        #expect(!center.isSyncing)
    }

    @Test("A sign-in the source still asks for leaves a source that was never signed in as it was")
    func unconfirmedSignIn() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [DirectMessageSync.Result(outcome: .needsSignIn)]

        #expect(await center.confirmSignIn() == .needsSignIn)
        #expect(center.status == .notSignedIn)
    }

    @Test("An inbox that loads signed in with no readable chat still counts as a sign-in, with the problem shown")
    func signedInWithNothingRead() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [DirectMessageSync.Result(outcome: .nothingCaptured)]

        #expect(await center.confirmSignIn() == .nothingCaptured)
        #expect(center.status == .signedIn(lastSync: nil, chats: 0))
        #expect(center.problem == .nothingCaptured)
    }

    @Test("A sync that finds the session ended waits for the person, keeps the last copy, and syncs no more")
    func sessionEnds() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced(), DirectMessageSync.Result(outcome: .needsSignIn)]
        _ = await center.confirmSignIn()

        #expect(await center.sync() == .needsSignIn)
        #expect(center.status == .needsYou)
        #expect(center.snapshot()?.threads.count == 2)

        #expect(await center.sync() == nil)
        #expect(fixture.runs == 2)

        fixture.results = [fixture.synced(chats: 1)]
        #expect(await center.confirmSignIn() == .synced)
        #expect(center.status == .signedIn(lastSync: fixture.now, chats: 1))
    }

    @Test("An inbox that does not load changes neither the sign-in nor the last copy")
    func pageUnavailable() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced(), DirectMessageSync.Result(outcome: .pageUnavailable)]
        _ = await center.confirmSignIn()

        #expect(await center.sync() == .pageUnavailable)
        #expect(center.status == .signedIn(lastSync: fixture.now, chats: 2))
        #expect(center.problem == .pageUnavailable)
    }

    @Test("When the page's limits cannot be set, nothing is loaded and the row says so")
    func limitsUnavailable() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced(), nil]
        _ = await center.confirmSignIn()

        #expect(await center.sync() == nil)
        #expect(center.problem == .limitsUnavailable)
        #expect(center.status == .signedIn(lastSync: fixture.now, chats: 2))
    }

    @Test("No sync starts while the person is signing in")
    func noSyncWhileSigningIn() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()

        let (model, _) = fixture.signInModel(for: center)
        #expect(center.isSigningIn)
        #expect(await center.sync() == nil)
        #expect(fixture.runs == 1)

        model.close()
        #expect(!center.isSigningIn)
        fixture.results = [fixture.synced()]
        #expect(await center.sync() == .synced)
    }

    @Test("A sign-in that a newer one replaced leaves the newer one counted when it closes")
    func replacedSignIn() {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        let (first, _) = fixture.signInModel(for: center)
        let (second, _) = fixture.signInModel(for: center)

        first.close()
        #expect(center.isSigningIn)

        second.close()
        #expect(!center.isSigningIn)
    }

    @Test("Switching the source off closes the sign-in the person has open", .timeLimit(.minutes(1)))
    func switchingOffClosesSignIn() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        let (model, _) = fixture.signInModel(for: center)
        var windowClosed = false
        model.onClosed = { windowClosed = true }
        await model.openStartPage()

        center.setEnabled(false)

        #expect(model.isClosed)
        #expect(model.browser.isClosed)
        #expect(windowClosed)
        #expect(!center.isSigningIn)
        #expect(await model.done() == false)
    }

    @Test("Switching the source off cancels the sync under way and then empties the source's data store")
    func switchingOffStopsSyncAndRemovesSession() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()
        await fixture.setSessionCookie()
        #expect(await fixture.cookieCount() == 1)

        fixture.holdsSyncs = true
        fixture.results = [fixture.synced()]
        async let pending = center.sync()
        await fixture.waitForHeldSync()
        center.setEnabled(false)
        // The session stays until the sync's browser is gone, which is when the sync ends.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.cookieCount() == 1)

        fixture.release()
        #expect(await pending == nil)
        await center.sessionSettled()

        #expect(fixture.heldSyncWasCancelled)
        #expect(await fixture.cookieCount() == 0)
    }

    @Test("A sign-in confirmed straight after switching back on waits for the old session to be removed first")
    func signInAfterSwitchingBackOn() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()
        await fixture.setSessionCookie()

        center.setEnabled(false)
        center.setEnabled(true)
        fixture.results = [fixture.synced(chats: 1)]
        let outcome = await center.confirmSignIn()

        #expect(outcome == .synced)
        #expect(await fixture.cookieCount() == 0)
        #expect(center.status == .signedIn(lastSync: fixture.now, chats: 1))
    }

    @Test("Two sign-in checks asked for while a sync runs make their syncs one after another")
    func confirmationsDoNotOverlap() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()

        fixture.holdsSyncs = true
        fixture.results = [fixture.synced(), fixture.synced(), fixture.synced()]
        async let running = center.sync()
        await fixture.waitForHeldSync()
        async let first = center.confirmSignIn()
        async let second = center.confirmSignIn()
        try? await Task.sleep(for: .milliseconds(50))
        fixture.release()

        #expect(await running == .synced)
        #expect(await first == .synced)
        #expect(await second == .synced)
        #expect(fixture.maximumConcurrentRuns == 1)
        #expect(fixture.runs == 4)
    }

    @Test("Switching the source off deletes the copy and the sign-in, and switching it on starts over")
    func switchingOff() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()
        let file = fixture.store.url(for: "test-source")!
        #expect(FileManager.default.fileExists(atPath: file.path))

        center.setEnabled(false)

        #expect(center.status == .off)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(center.snapshot() == nil)

        center.setEnabled(true)
        #expect(center.status == .notSignedIn)
        #expect(DirectMessageCenter.loadState(source: "test-source", from: fixture.defaults) == State())
    }

    @Test("A sync still running when the source is switched off saves nothing when it ends")
    func dropsSyncAcrossSwitchOff() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()

        fixture.holdsSyncs = true
        fixture.results = [fixture.synced(chats: 5)]
        async let pending = center.sync()
        await fixture.waitForHeldSync()
        #expect(center.isSyncing)
        center.setEnabled(false)
        center.setEnabled(true)
        fixture.release()

        #expect(await pending == nil)
        #expect(center.snapshot() == nil)
        #expect(center.status == .notSignedIn)
        #expect(!center.isSyncing)
    }

    @Test("A caller that finds a sync under way waits for it and gets its outcome")
    func joinsSyncUnderWay() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced()]
        _ = await center.confirmSignIn()

        fixture.holdsSyncs = true
        fixture.results = [fixture.synced(chats: 4)]
        async let first = center.sync()
        await fixture.waitForHeldSync()
        async let second = center.sync()
        try? await Task.sleep(for: .milliseconds(50))
        fixture.release()

        #expect(await first == .synced)
        #expect(await second == .synced)
        #expect(fixture.runs == 2)
    }

    @Test("The sign-in is remembered by the next launch")
    func rememberedAcrossLaunches() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        fixture.results = [fixture.synced(), DirectMessageSync.Result(outcome: .needsSignIn)]
        _ = await center.confirmSignIn()

        #expect(fixture.center().status == .signedIn(lastSync: fixture.now, chats: 2))

        _ = await center.sync()
        #expect(fixture.center().status == .needsYou)
    }

    @Test("The log line for a sync carries the outcome and counts")
    func logLine() {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        var result = fixture.synced(chats: 2)
        result.report.responses = 9
        result.report.parse.messages = 2
        result.report.refusedOperations = ["A": 1, "B": 2]
        result.report.blockedSockets = 4

        #expect(
            DirectMessageCenter.logLine(source: "test-source", result: result)
                == "direct messages test-source: synced, 2 chats, 2 messages, 9 responses, 3 refused, 4 sockets blocked"
        )
    }

    @Test("Done finishes only when the source read as signed in")
    func signInRefusals() {
        #expect(DirectMessageSignInModel.refusal(for: .synced, sourceName: "Chatter") == nil)
        #expect(DirectMessageSignInModel.refusal(for: .nothingCaptured, sourceName: "Chatter") == nil)
        #expect(DirectMessageSignInModel.refusal(for: .needsSignIn, sourceName: "Chatter")?.contains("Chatter") == true)
        #expect(DirectMessageSignInModel.refusal(for: .pageUnavailable, sourceName: "Chatter") != nil)
        #expect(DirectMessageSignInModel.refusal(for: nil, sourceName: "Chatter") != nil)
    }

    @Test("The sign-in window holds syncs back while it is open, and Done checks the sign-in with a sync", .timeLimit(.minutes(1)))
    func signInModel() async {
        let fixture = CenterFixture()
        defer { fixture.folder.remove() }
        let center = fixture.center()
        center.setEnabled(true)
        let (model, _) = fixture.signInModel(for: center)
        #expect(center.isSigningIn)
        await model.openStartPage()
        #expect(model.host == TestMessageSource.host)
        #expect(!model.loadFailed)

        fixture.results = [DirectMessageSync.Result(outcome: .needsSignIn)]
        #expect(await model.done() == false)
        #expect(model.phase == .notConfirmed(
            DirectMessageSignInModel.refusal(for: .needsSignIn, sourceName: "Chatter")!
        ))

        fixture.results = [fixture.synced()]
        #expect(await model.done())
        #expect(model.phase == .finished)
        #expect(center.status == .signedIn(lastSync: fixture.now, chats: 2))

        model.close()
        #expect(!center.isSigningIn)
        #expect(model.browser.isClosed)
    }
}
