import AppKit
import Combine
import Darwin
import Foundation

/// Runs ProVisor's agent and holds what it has proposed.
///
/// The app's part is deliberately small. It starts a scouting run on a schedule, shows the
/// proposal files that run writes, and — only on the user's tap — starts a second run to carry
/// one proposal out. What to look for, what is worth proposing, and what was learned from
/// earlier decisions all live with the agent: in its brief and in the notes it keeps.
///
/// Scouting runs and follow-up runs, which can change nothing outside the workspace, can also
/// read the sites, texts, and photo places the user granted, through the bridge
/// (`ProVisorBridge`). Runs that
/// carry out an action never can.
///
/// A singleton because Settings needs the live state and reaches no module instance: the
/// registry builds a second, never-activated set of modules just to list their names.
@MainActor
final class ProVisorCenter: ObservableObject, FollowUpHolding {
    static let shared = ProVisorCenter()

    /// Every valid proposal on disk, whatever its status. `ProposalQueue` picks what shows.
    @Published private(set) var proposals: [Proposal] = []
    @Published private(set) var isScouting = false
    /// Whether a pass over the checks a decision left owed is running.
    @Published private(set) var isFollowingUp = false
    /// Why passes did not get the bridge's tools the last time one started; nil while
    /// they do, and before any pass has decided.
    @Published private(set) var siteToolsUnavailable: ProVisorBridge.Unavailable?
    /// The proposal an acting run is carrying out right now.
    @Published private(set) var actingID: String?
    /// Approved proposals waiting behind the acting run.
    @Published private(set) var queuedIDs: [String] = []
    /// Why the last scouting pass failed, in the app's own words, or nil when it finished or
    /// none has run. What the agent says when a pass ends is kept nowhere: its account of a
    /// run is in the notes it writes under `memory/`.
    @Published private(set) var lastScoutFailure: String?
    /// The user's standing approvals, in force and revoked, as last read from disk.
    @Published private(set) var standingRules: [StandingRule] = []
    /// Whether the module is enabled and the center is watching and scheduling.
    @Published private(set) var isActive = false
    /// The sites the person is being asked to sign in to: granted sites that need them, and
    /// sites an open proposal asks for (`SignInDemand`).
    @Published private(set) var signInDemand: [SignInDemand.Item] = []
    /// The sites to put in front of the person as sign-ins, on the banner and as sheet rows:
    /// the announceable items of `signInDemand`, less those put off (`SignInDemand.prompts`).
    @Published private(set) var signInPrompts: [SignInDemand.Item] = []

    /// Called when the set of proposals on disk changes.
    var onProposalsChanged: (() -> Void)?
    /// Called with how many proposals needing a decision a finished run added: a scouting
    /// pass, or a reviewed run raising something it found and could not settle.
    var onProposalsAdded: ((Int) -> Void)?
    /// Called with the sites that entered `signInPrompts` since the last look, none of which
    /// the person has been told about yet. `signInPrompts` already holds them when it is called.
    /// A site put off and then turned away from again enters anew.
    var onSignInNeeded: (([SignInDemand.Item]) -> Void)?

    private static let lastScoutKey = "provisor.lastScoutAt"
    /// The `BriefRevision` digest of the brief the last finished scouting pass ran with.
    private static let briefDigestKey = "provisor.briefDigest"
    private static let scoutTimeout: Duration = .seconds(20 * 60)
    private static let actTimeout: Duration = .seconds(10 * 60)
    private static let followUpTimeout: Duration = .seconds(10 * 60)
    private static let emailedCodeTimeout: Duration = .seconds(60)

    private let defaults: UserDefaults
    private var watcher: DirectoryTreeWatcher?
    private var scheduleTask: Task<Void, Never>?
    private var cadenceSubscription: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var scoutService: AgentTaskService?
    private var actService: AgentTaskService?
    private var followUpService: AgentTaskService?
    /// Waits until the next time a follow-up pass may start (`FollowUpSchedule.nextStart`).
    private var followUpTask: Task<Void, Never>?
    private var followUpLedger: FollowUpLedger
    private var followUpDemand = FollowUpDemand()
    /// While any hold stands, no follow-up pass starts (`holdFollowUps`).
    private var followUpHolds = FollowUpHolds()
    /// Whether the follow-up pass in progress, or the last one, reached the point of starting
    /// its agent process.
    private var followUpLaunched = false
    private var accessWatcher: FileChangeWatcher?
    /// The handoffs the app made, read from disk at start and saved on every change. The copy
    /// here is the one sweeps work from, so a save that fails cannot bring the same findings
    /// in twice while the app runs.
    private var handoffLedger = HandoffLedger()
    /// Follows the folders handed-off sessions work in, for the findings they leave.
    private var handoffWatcher: DirectoryTreeWatcher?
    /// Waits to read a findings file that was still changing at the last look
    /// (`HandoffFindings.quietSeconds`).
    private var findingsLookTask: Task<Void, Never>?
    private var signInSubscription: AnyCancellable?
    private var signInAnnouncer = SignInAnnouncer()
    private var postponements = SignInPostponements()
    /// The open requests whose host is still being looked up in the browsing history, as of the
    /// last publish of the demand.
    private var requestsAwaitingRecognition: Set<String> = []
    /// Waits until the soonest open site request expires, when the demand changes with no file
    /// or site changing (`SignInDemand.nextExpiry`).
    private var demandExpiryTask: Task<Void, Never>?
    private let hostRecognition: HostRecognition
    /// The emailed-code lookups under way, held so stopping can end them.
    private var lookupServices: [UUID: AgentTaskService] = [:]
    private lazy var bridge = ProVisorBridge(sites: SiteAccessCenter.shared)
    /// A proposal waiting to be carried out, captured as it stood when it was approved or
    /// admitted, with what the run is to do.
    private struct PendingAct {
        let proposal: Proposal
        let task: ActTask
    }

    /// The text a queued or running proposal is being carried out as, and whose words it is.
    struct CapturedAction: Equatable {
        let text: String
        let isTyped: Bool
    }

    private enum ActTask {
        /// One of the proposal's options, approved on the review screen.
        case approved(ProposalOption)
        /// An instruction the user typed on the review screen, with the option that was shown
        /// beside the text box.
        case instructed(String, reference: ProposalOption)
        /// Admitted under a standing approval, with nobody reviewing it first.
        case standing(StandingRule)

        var rule: StandingRule? {
            if case let .standing(rule) = self { return rule }
            return nil
        }
    }

    private var pendingActs: [PendingAct] = []
    /// The act in progress, for as long as `actingID` names it.
    private var actingTask: PendingAct?
    /// Proposals already admitted under a standing approval, so a reload never admits one twice.
    private var automaticIDs: Set<String> = []
    /// Runs admitted under a standing approval since the last scouting pass started. Only a
    /// scouting pass resets it, so follow-up passes draw on the same allowance.
    private var automaticRunsThisPass = 0
    private var announcer = ProposalAnnouncer()
    private var lastAttempt: Date?
    /// Bumped on every start and stop, so a run that outlives its activation reports to nobody.
    private var activation = 0
    private var reloadSequence = 0

    private init(
        defaults: UserDefaults = .standard,
        historyLookup: @escaping @Sendable (String) -> Bool = { BrowsingHistory().hasVisited(host: $0) }
    ) {
        self.defaults = defaults
        followUpLedger = FollowUpLedger(defaults: defaults)
        hostRecognition = HostRecognition(lookup: historyLookup)
    }

    /// When the last scouting pass that finished did so.
    var lastScoutDate: Date? {
        let stored = defaults.double(forKey: Self.lastScoutKey)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        isActive = true
        activation += 1

        do {
            try ProVisorHome.prepare()
        } catch {
            report(setupFailure: error)
        }

        standingRules = StandingApprovals.load(from: ProVisorHome.standingURL)
        // Items a run raised just before the app last quit are still waiting in the folder,
        // and so is anything a handed-off session wrote while the app was not looking.
        admitRaisedItems()
        handoffLedger = HandoffLedger.load(from: ProVisorHome.handoffLedgerURL)
        admitReturnedFindings()
        let handoffWatcher = DirectoryTreeWatcher(url: ProVisorHome.handoffsURL, debounce: 2) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.admitReturnedFindings()
                }
            }
        }
        self.handoffWatcher = handoffWatcher
        handoffWatcher.start()
        bridge.removeStaleConfigurations()
        SiteAccessCenter.shared.emailedCode = { [weak self] sender, since in
            await self?.lookUpEmailedCode(sender: sender, since: since)
        }
        let accessWatcher = FileChangeWatcher(url: ProVisorHome.accessURL) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshSiteTools()
                }
            }
        }
        self.accessWatcher = accessWatcher
        accessWatcher.start()
        refreshSiteTools()
        startWatchingSignInDemand()

        let watcher = DirectoryTreeWatcher(url: ProVisorHome.proposalsURL) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.reloadSoon()
                }
            }
        }
        self.watcher = watcher
        watcher.start()
        reloadSoon()

        // A sleeping Mac must not wake straight into a run: the timer is dropped on the way
        // down and re-armed on the way up, which also applies the settle delay.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelSchedule()
                    self?.cancelFollowUp()
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.armSchedule()
                    self?.armFollowUp()
                }
            },
        ]

        // Publishes the current cadence on subscription, which arms the first timer.
        cadenceSubscription = SettingsStore.shared.$provisorScoutHours
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.armSchedule() }
        armFollowUp()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        activation += 1

        cancelSchedule()
        cancelFollowUp()
        SiteAccessCenter.shared.emailedCode = nil
        stopWatchingSignInDemand()
        accessWatcher?.stop()
        accessWatcher = nil
        handoffWatcher?.stop()
        handoffWatcher = nil
        findingsLookTask?.cancel()
        findingsLookTask = nil
        handoffLedger = HandoffLedger()
        siteToolsUnavailable = nil
        cadenceSubscription?.cancel()
        cadenceSubscription = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        watcher?.stop()
        watcher = nil

        // The agent process must not outlive the app. Ask it to stop, give it a moment, then
        // take its whole process group down.
        let services = [scoutService, actService, followUpService].compactMap { $0 }
            + Array(lookupServices.values)
        scoutService = nil
        actService = nil
        followUpService = nil
        lookupServices = [:]
        for service in services {
            service.cancel()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline, services.contains(where: { $0.hasUnresolvedTask }) {
            for service in services {
                service.pollForTermination()
            }
            Darwin.usleep(10_000)
        }
        for service in services where service.hasUnresolvedTask {
            service.forceStopForTeardown()
        }

        // Each run's own task ends its access when its process ends; stopping the bridge makes
        // sure none outlives the center.
        bridge.stop()

        followUpDemand = FollowUpDemand()
        followUpHolds.releaseAll()
        pendingActs = []
        queuedIDs = []
        actingID = nil
        actingTask = nil
        isScouting = false
        isFollowingUp = false
        proposals = []
        standingRules = []
        automaticIDs = []
        automaticRunsThisPass = 0
        announcer = ProposalAnnouncer()
        signInDemand = []
        signInPrompts = []
    }

    // MARK: - Scouting

    /// Starts a scouting pass now, whatever the schedule says.
    func scoutNow() {
        startScout()
    }

    private func armSchedule() {
        cancelSchedule()
        guard isActive else { return }
        let hours = SettingsStore.shared.provisorScoutHours
        guard hours > 0 else { return }

        let delay = ProVisorSchedule.delay(
            lastScout: lastScoutDate,
            lastAttempt: lastAttempt,
            intervalHours: hours,
            now: Date()
        )
        // One sleeping task until the next pass is due; nothing ticks in between.
        scheduleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.scheduleTask = nil
            self.startScout()
        }
    }

    private func cancelSchedule() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    /// Starts a scouting pass unless one is running. A pass that comes due while a follow-up
    /// pass runs waits for it: finishing that pass re-arms the schedule, which is then overdue.
    private func startScout() {
        guard isActive, !isScouting, !isFollowingUp else { return }

        // Read fresh: the file is the user's, and may have been edited by hand since.
        standingRules = StandingApprovals.load(from: ProVisorHome.standingURL)

        let brief: String
        let access: ProVisorAccess
        do {
            try ProVisorHome.prepare()
            brief = try ProVisorHome.loadBrief()
            access = try ProVisorHome.loadAccess()
        } catch {
            // Counted as an attempt, so the schedule backs off and tries again later instead
            // of stopping for good on a file the user is halfway through editing.
            lastAttempt = Date()
            report(setupFailure: error)
            armSchedule()
            return
        }

        isScouting = true
        lastAttempt = Date()
        automaticRunsThisPass = 0
        cancelSchedule()
        AppLog.notice(.provisor, "scout started")

        let prepared = prepareBridge(access: access)
        let arguments = ProVisorCommand.scoutArguments(
            brief: brief,
            access: access,
            standing: standingRules,
            now: Date(),
            briefChanged: BriefRevision.hasChanged(
                brief: brief,
                recorded: defaults.string(forKey: Self.briefDigestKey),
                hasScouted: lastScoutDate != nil
            ),
            bridge: prepared?.bridge,
            connectorHold: prepared == nil ? bridge.holdConfigurationPath() : nil
        )
        let service = AgentTaskService()
        scoutService = service
        let activation = self.activation
        let briefDigest = BriefRevision.digest(of: brief)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runPass(
                service,
                arguments: arguments,
                timeout: ProVisorCenter.scoutTimeout,
                prepared: prepared
            )
            await self.finishScout(outcome, briefDigest: briefDigest, activation: activation)
        }
    }

    /// Prepares the run's bridge tools, or nothing when the conditions for them do not
    /// hold, and publishes why.
    private func prepareBridge(access: ProVisorAccess) -> ProVisorBridge.PreparedRun? {
        defer { siteToolsUnavailable = bridge.lastUnavailable }
        guard case let .success(run) = bridge.prepare(access: access) else { return nil }
        return run
    }

    /// Runs a pass's agent process in the workspace and ends the run's tool access when the
    /// process ends, however it ends, whether or not the center is still active.
    private func runPass(
        _ service: AgentTaskService,
        arguments: [String],
        timeout: Duration,
        prepared: ProVisorBridge.PreparedRun?,
        launched: (@MainActor () -> Void)? = nil
    ) async -> Result<AgentTaskResult, any Error> {
        defer {
            if let prepared { bridge.finished(prepared) }
        }
        do {
            return .success(try await service.run(
                arguments: arguments,
                workingDirectory: ProVisorHome.workspaceURL,
                timeout: timeout,
                onLaunch: { [bridge] pid in
                    if let prepared { bridge.launched(prepared, pid: pid) }
                    launched?()
                }
            ))
        } catch {
            return .failure(error)
        }
    }

    /// `briefDigest` is recorded only for a pass that finished: one that failed may not have
    /// reached its notes, so the next pass is told of the change again.
    private func finishScout(
        _ outcome: Result<AgentTaskResult, any Error>,
        briefDigest: String,
        activation: Int
    ) async {
        guard activation == self.activation else { return }
        scoutService = nil
        isScouting = false

        let finished = Date()
        switch outcome {
        case .success:
            defaults.set(finished.timeIntervalSince1970, forKey: Self.lastScoutKey)
            defaults.set(briefDigest, forKey: Self.briefDigestKey)
            lastScoutFailure = nil
            AppLog.notice(.provisor, "scout finished")
        case let .failure(error):
            lastScoutFailure = Self.failureSentence(error)
            AppLog.error(.provisor, "scout failed: \(Self.logName(error))")
        }

        // A pass cut off by a limit still leaves the proposals it had already written, so the
        // count is taken from disk either way.
        let loaded = await reload()
        guard activation == self.activation else { return }
        announceAdded(in: loaded)
        armSchedule()
        armFollowUp()
    }

    /// Counts the proposals a finished run added. A request whose host is still being looked
    /// up in the person's browsing history is held back until the answer arrives
    /// (`announceReleased`), since the answer decides whether it is announced as a sign-in.
    private func announceAdded(in loaded: [Proposal]) {
        report(added: announcer.countNew(
            in: loaded,
            automatic: automaticIDs,
            covered: SignInDemand.coveredProposalIDs(signInPrompts),
            awaitingRecognition: requestsAwaitingRecognition,
            now: Date()
        ))
    }

    /// Counts the held-back requests whose host has been looked up: one announced as a sign-in
    /// is covered by it, and one for a host the person's browsers do not know is a new idea.
    private func announceReleased(now: Date) {
        report(added: announcer.countReleased(
            in: proposals,
            automatic: automaticIDs,
            covered: SignInDemand.coveredProposalIDs(signInPrompts),
            awaitingRecognition: requestsAwaitingRecognition,
            now: now
        ))
    }

    private func report(added: Int) {
        guard added > 0 else { return }
        AppLog.notice(.provisor, "proposals added \(added)")
        onProposalsAdded?(added)
    }

    /// Brings anything a reviewed run raised into the queue. The run cannot write there itself.
    private func admitRaisedItems() {
        let admitted = RaisedItems.admit(
            from: ProVisorHome.raisedURL,
            into: ProVisorHome.proposalsURL
        )
        if admitted > 0 {
            AppLog.notice(.provisor, "raised items admitted \(admitted)")
        }
    }

    // MARK: - Follow-up passes

    /// Arms the one timer for the next follow-up pass: it fires when a pass that is owed may
    /// start, and is dropped when none is owed, a scouting or follow-up pass is running, whose
    /// end arms it again, or a hold stands (`holdFollowUps`), whose release does. A pass is owed for a due note, or after the person signed in to a
    /// site that something was waiting on (`FollowUpDemand`); the latter starts on its own
    /// schedule (`FollowUpSchedule.nextStartAfterGrant`). It is evaluated again whenever
    /// something that decides it changes: a reviewed run, a scouting pass, or a follow-up pass
    /// finishes, a site is signed in to, the last hold is released, the Mac wakes, or the center
    /// starts.
    private func armFollowUp() {
        cancelFollowUp()
        let now = Date()
        guard isActive, !isScouting, !isFollowingUp, !followUpHolds.isHeld, isFollowUpOwed(now: now) else {
            return
        }
        scheduleFollowUp(at: nextFollowUpStart(now: now), from: now)
    }

    /// A pass that could not start stays owed. Its retry follows the ordinary schedule counted
    /// from this attempt, so a failure that persists is tried at most once in the minimum gap
    /// between passes, whichever schedule the pass was owed on.
    private func retryFollowUp(after attempt: Date) {
        cancelFollowUp()
        guard isActive, !isScouting, !isFollowingUp, !followUpHolds.isHeld, isFollowUpOwed(now: attempt) else {
            return
        }
        let start = FollowUpSchedule.nextStart(
            now: attempt,
            last: attempt,
            startedToday: followUpLedger.startedToday(now: attempt, timeZone: .current),
            calendar: .current
        )
        scheduleFollowUp(at: start, from: attempt)
    }

    private func scheduleFollowUp(at start: Date, from now: Date) {
        followUpTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, start.timeIntervalSince(now))))
            guard let self, !Task.isCancelled else { return }
            self.followUpTask = nil
            self.startFollowUp()
        }
    }

    private func cancelFollowUp() {
        followUpTask?.cancel()
        followUpTask = nil
    }

    /// Whether a pass is owed: a sign-in is waiting on one, a note is due, or a handed-off
    /// session left findings no pass has read (`ReturnedNotes`). A note that waits on a site is
    /// due only while the site can be read.
    private func isFollowUpOwed(now: Date) -> Bool {
        let sites = SiteAccessCenter.shared
        let (granted, awaiting) = (sites.access.sites(), sites.awaitingSignIn)
        let today = LocalDay(now, timeZone: .current)
        return followUpDemand.isOwed(
            hasDueNote: FollowUpNotes.hasDueNote(
                in: ProVisorHome.followUpsURL,
                on: today,
                readable: { FollowUpNotes.isReadable($0, granted: granted, awaiting: awaiting) }
            ) || ReturnedNotes.hasNew(in: ProVisorHome.returnedURL, on: today)
        )
    }

    /// Keeps follow-up passes from starting until the token is released (`FollowUpHolds`). A
    /// pass already waiting to start is called off and armed again on release.
    func holdFollowUps() -> FollowUpHolds.Token {
        let token = followUpHolds.take()
        cancelFollowUp()
        return token
    }

    /// Lifts the hold `token` names; once none stands, a pass that is owed is armed.
    func releaseFollowUps(_ token: FollowUpHolds.Token) {
        if followUpHolds.release(token) {
            armFollowUp()
        }
    }

    /// Asks for a follow-up pass after the person signed in to `siteID`, which something was
    /// waiting on, so the check that waited on it is made with it. One request stands at a time
    /// however many sites it names.
    private func siteWasGranted(_ siteID: String) {
        guard isActive else { return }
        followUpDemand.requestAfterGrant(site: siteID)
        armFollowUp()
    }

    /// The person saved the sign-in for `record`, or signed in to it with its stored grant kept
    /// (`SiteAccessCenter.personSignedIn`); `wasAwaited` says the site was waiting on them.
    /// The save answers the earliest open request for the site, which is recorded done
    /// (`SiteRequests.settle`), and owes a pass when there was such a request or the site was
    /// waiting (`SignInDemand.effectOfSaving`). Every save arrives here, from whichever window
    /// made it.
    private func siteSaved(_ record: SiteRecord, wasAwaited: Bool) {
        guard isActive else { return }
        let effect = SignInDemand.effectOfSaving(
            record.id,
            proposals: proposals,
            now: Date(),
            wasAwaited: wasAwaited
        )
        if let proposalID = effect.settles {
            let outcome = SiteRequests.settle(
                proposalID: proposalID,
                host: record.id,
                savedSiteID: record.id,
                siteName: record.name,
                in: ProVisorHome.proposalsURL,
                isBusy: actingID == proposalID || queuedIDs.contains(proposalID)
            )
            if outcome == .settled {
                AppLog.notice(.provisor, "site request settled")
                reloadSoon()
            } else {
                AppLog.notice(.provisor, "site request left open: \(outcome.logName)")
            }
        }
        if effect.owesPass {
            siteWasGranted(record.id)
        }
    }

    private func nextFollowUpStart(now: Date) -> Date {
        let last = followUpLedger.last
        let startedToday = followUpLedger.startedToday(now: now, timeZone: .current)
        guard followUpDemand.isOwedAfterGrant else {
            return FollowUpSchedule.nextStart(
                now: now,
                last: last,
                startedToday: startedToday,
                calendar: .current
            )
        }
        return FollowUpSchedule.nextStartAfterGrant(
            now: now,
            last: last,
            startedToday: startedToday,
            grantsStartedToday: followUpLedger.grantStartedToday(now: now, timeZone: .current),
            calendar: .current
        )
    }

    /// The agent process of a follow-up pass started, so the sites it was told the person
    /// signed in to are answered and a pass owed for a sign-in is charged to that day's count.
    private func followUpDidLaunch(
        told: [String],
        charge: FollowUpSchedule.Charge,
        activation: Int
    ) {
        guard activation == self.activation else { return }
        followUpLaunched = true
        followUpDemand.passStarted(told: told)
        if charge == .afterGrant {
            followUpLedger = followUpLedger.recordingGrantStart(now: Date(), timeZone: .current)
            followUpLedger.save(to: defaults)
        }
    }

    /// Starts a pass over the due notes in `followups/`, which settles what checks out and
    /// raises what does not. It shares the scout's one-pass-at-a-time rule, and a pass that is
    /// running when the timer fires holds it back to a later time. The scouting report in
    /// Settings is left as it was.
    private func startFollowUp() {
        // Releasing the last hold arms the timer again.
        guard isActive, !followUpHolds.isHeld else { return }
        guard !isScouting, !isFollowingUp else {
            armFollowUp()
            return
        }
        let now = Date()
        guard isFollowUpOwed(now: now) else { return }
        guard let charge = FollowUpSchedule.chargeToStart(
            now: now,
            last: followUpLedger.last,
            afterGrantOwed: followUpDemand.isOwedAfterGrant,
            startedToday: followUpLedger.startedToday(now: now, timeZone: .current),
            grantsStartedToday: followUpLedger.grantStartedToday(now: now, timeZone: .current)
        ) else {
            armFollowUp()
            return
        }

        standingRules = StandingApprovals.load(from: ProVisorHome.standingURL)
        let brief: String
        let access: ProVisorAccess
        do {
            try ProVisorHome.prepare()
            brief = try ProVisorHome.loadBrief()
            access = try ProVisorHome.loadAccess()
        } catch {
            AppLog.error(.provisor, "follow-up setup failed")
            retryFollowUp(after: now)
            return
        }

        isFollowingUp = true
        followUpLaunched = false
        // The sites the pass is told about stay owed until its process has started.
        let told = followUpDemand.justSignedIn
        let justSignedIn = ProVisorTools.signedInLabels(
            told,
            granted: SiteAccessCenter.shared.access.sites()
        )
        if charge == .ordinary {
            followUpLedger = followUpLedger.recordingStart(now: now, timeZone: .current)
            followUpLedger.save(to: defaults)
        }
        AppLog.notice(.provisor, "follow-up started")

        let prepared = prepareBridge(access: access)
        let arguments = ProVisorCommand.followUpArguments(
            brief: brief,
            access: access,
            standing: standingRules,
            now: now,
            justSignedIn: justSignedIn,
            bridge: prepared?.bridge,
            connectorHold: prepared == nil ? bridge.holdConfigurationPath() : nil
        )
        let service = AgentTaskService()
        followUpService = service
        let activation = self.activation
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.runPass(
                service,
                arguments: arguments,
                timeout: ProVisorCenter.followUpTimeout,
                prepared: prepared,
                launched: { [weak self] in
                    self?.followUpDidLaunch(told: told, charge: charge, activation: activation)
                }
            )
            await self.finishFollowUp(outcome, activation: activation)
        }
    }

    private func finishFollowUp(
        _ outcome: Result<AgentTaskResult, any Error>,
        activation: Int
    ) async {
        guard activation == self.activation else { return }
        followUpService = nil
        isFollowingUp = false

        switch outcome {
        case .success:
            AppLog.notice(.provisor, "follow-up finished")
        case let .failure(error):
            AppLog.error(.provisor, "follow-up failed: \(Self.logName(error))")
        }

        // Proposals the pass wrote are counted from disk, and any under a standing approval are
        // admitted by the reload, as after a scouting pass.
        let loaded = await reload()
        guard activation == self.activation else { return }
        announceAdded(in: loaded)
        // A scouting pass that came due during this one is overdue, so arming starts it after the
        // settle delay.
        armSchedule()
        if followUpLaunched {
            armFollowUp()
        } else {
            retryFollowUp(after: Date())
        }
    }

    /// Re-reads why a pass would run without the bridge's tools, without starting one.
    /// Settings asks when it appears; the center asks when `access.json` changes.
    func refreshSiteTools() {
        guard isActive, let access = try? ProVisorHome.loadAccess() else { return }
        siteToolsUnavailable = bridge.evaluate(access: access)
    }

    // MARK: - Emailed sign-in codes

    /// The code a site emailed to `sender` after `since`, looked up by a minimal run on the
    /// user's mail. It never goes through the acting queue, so a pass waiting on a sign-in
    /// cannot be held up behind it.
    private func lookUpEmailedCode(sender: String, since: Date) async -> String? {
        guard isActive, let access = try? ProVisorHome.loadAccess() else { return nil }
        let lookup = EmailedCodeLookup(run: { [weak self] arguments in
            await self?.runLookup(arguments)
        })
        return await lookup.code(
            sender: sender,
            since: since,
            access: access,
            connectorHold: bridge.holdConfigurationPath()
        )
    }

    /// Runs one lookup in a fresh empty folder, which is deleted afterwards, and returns the
    /// run's answer; nil when it failed.
    private func runLookup(_ arguments: [String]) async -> String? {
        guard isActive else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provisor-code-\(UUID().uuidString.prefix(8).lowercased())",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: folder) }

        let service = AgentTaskService()
        let key = UUID()
        lookupServices[key] = service
        defer { lookupServices[key] = nil }
        do {
            return try await service.run(
                arguments: arguments,
                workingDirectory: folder,
                timeout: Self.emailedCodeTimeout
            ).text
        } catch {
            AppLog.error(.provisor, "code lookup failed: \(Self.logName(error))")
            return nil
        }
    }

    // MARK: - Decisions

    /// Approves one of a proposal's options and queues the run that carries it out. With
    /// `always`, the rule the proposal offered also becomes a standing approval; an offer goes
    /// with the recommended option, so `always` counts only for that one.
    ///
    /// `displayed` is the proposal as the review window showed it. Returns why the approval
    /// was not taken, or nil when the run is queued.
    @discardableResult
    func approve(
        _ displayed: Proposal,
        option index: Int = 0,
        always: Bool = false
    ) -> DecisionRefusal? {
        if let refusal = refusal(for: displayed) { return refusal }
        // Nothing an acting run holds can carry out a change to ProVisor itself.
        guard !displayed.isImprovement, displayed.options.indices.contains(index) else {
            return .unavailable
        }

        let decision = ProposalReview.standingDecision(
            for: displayed,
            optionIndex: index,
            always: always
        )
        // This run was reviewed, so it gets the reviewed tool list whether or not a rule comes
        // of it.
        guard enqueue(
            displayed,
            task: .approved(displayed.options[index]),
            choice: .option(index),
            standingDecision: decision
        ) else { return .notSaved }

        if decision == ProposalReview.acceptedOffer, let offer = displayed.standingOffer {
            updateStanding { rules in
                guard let rule = StandingApprovals.rule(adding: offer, to: rules, now: Date())
                else { return rules }
                return rules + [rule]
            }
        }
        return nil
    }

    /// Queues a run that carries out an instruction the user typed in place of the proposal's
    /// own options. `reference` is the option that was on screen beside the text box, which
    /// the run is given as background. Returns why it was not taken, or nil when queued.
    @discardableResult
    func instruct(_ displayed: Proposal, reference index: Int, text: String) -> DecisionRefusal? {
        if let refusal = refusal(for: displayed) { return refusal }
        guard !displayed.isImprovement,
              displayed.options.indices.contains(index),
              let instruction = ProposalReview.instruction(from: text)
        else { return .unavailable }

        return enqueue(
            displayed,
            task: .instructed(instruction, reference: displayed.options[index]),
            choice: .instruction(instruction),
            standingDecision: nil
        ) ? nil : .notSaved
    }

    /// Whether a proposal can be handed to a session in the Claude desktop app: the app is on
    /// this Mac.
    var canHandOff: Bool {
        NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: SessionLink.claudeDesktopBundleIdentifier
        ) != nil
    }

    /// SuperVisor's source checkout as Settings names it, where a session about ProVisor
    /// itself is opened; nil when none is set or the folder no longer holds the source.
    var sourceFolder: URL? {
        ProVisorHome.sourceFolder(at: SettingsStore.shared.provisorSourceFolder)
    }

    /// Takes a proposal into a session the person directs in the Claude desktop app
    /// (`Handoff`): makes the handoff's folder with its brief, records the handoff, and opens
    /// the draft of a new session there. `index` is the option on screen. `typed` is what the
    /// review window's text box held, or nil when that option was selected in its place; the
    /// session is told to start on whichever the person chose (`Handoff.Request`). Returns why
    /// nothing was opened, or nil when the draft is opening.
    ///
    /// The proposal stays open: handing it off starts no run and decides nothing. It is
    /// recorded done when that session's findings come back (`admitReturnedFindings`).
    ///
    /// A proposal about ProVisor itself opens in SuperVisor's source (`sourceFolder`). Its
    /// handoff folder is still made, and still holds the guide and the brief and receives the
    /// findings, so what comes back is read exactly as any other handoff's is.
    @discardableResult
    func handOff(_ displayed: Proposal, option index: Int, typed: String?) -> DecisionRefusal? {
        if let refusal = refusal(for: displayed) { return refusal }
        guard displayed.options.indices.contains(index),
              let request = Handoff.Request(option: displayed.options[index], typed: typed)
        else { return .unavailable }

        let now = Date()
        let workplace: Handoff.Workplace = displayed.isImprovement
            ? .source(folder: sourceFolder, handoffs: ProVisorHome.handoffsURL, home: ProVisorHome.rootURL)
            : .ownFolder
        let handoff = Handoff(
            proposal: displayed,
            request: request,
            now: now,
            timeZone: .current,
            workplace: workplace
        )
        guard let link = handoff.link(root: ProVisorHome.handoffsURL),
              let application = link.applicationURL()
        else { return .appMissing }
        // The records come before the link, as a decision's does before its run: findings are
        // read only from a folder the ledger names.
        do {
            try HandoffFolder.write(handoff, in: ProVisorHome.handoffsURL)
            var ledger = handoffLedger
            ledger.record(handoff, at: now)
            try ledger.save(to: ProVisorHome.handoffLedgerURL)
            handoffLedger = ledger
            try ProposalStore.recordHandoff(id: displayed.id, in: ProVisorHome.proposalsURL, now: now)
        } catch HandoffFolderError.foreignEntry {
            AppLog.error(.provisor, "handoff refused: foreign entry in the handoff folder")
            return .handoffFolder
        } catch {
            AppLog.error(.provisor, "handoff not recorded")
            return .notSaved
        }
        reloadSoon()
        let id = displayed.id
        link.open(at: application, category: .provisor) { [weak self] in
            // No session opened, so the proposal must not say one did.
            AppLog.error(.provisor, "handoff link not opened")
            try? ProposalStore.removeHandoff(id: id, in: ProVisorHome.proposalsURL)
            self?.reloadSoon()
        }
        AppLog.notice(.provisor, handoff.sessionFolder == nil ? "handoff opened" : "handoff opened in source")
        return nil
    }

    /// Brings in what handed-off sessions wrote since the last look (`HandoffFindings`), marks
    /// each proposal returned, and arms the pass that reads the notes. A proposal still
    /// awaiting a decision is recorded done, unless a run is already carrying it out. A file
    /// that was still changing is looked at again once it has had time to settle.
    private func admitReturnedFindings() {
        guard isActive else { return }
        findingsLookTask?.cancel()
        findingsLookTask = nil
        let ledger = handoffLedger
        let sweep = HandoffFindings.admit(
            ledger: ledger,
            from: ProVisorHome.handoffsURL,
            into: ProVisorHome.returnedURL
        )
        if let nextLook = sweep.nextLook {
            findingsLookTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, nextLook.timeIntervalSinceNow)))
                guard let self, !Task.isCancelled else { return }
                self.admitReturnedFindings()
            }
        }
        guard sweep.ledger != ledger else { return }
        handoffLedger = sweep.ledger
        do {
            try sweep.ledger.save(to: ProVisorHome.handoffLedgerURL)
        } catch {
            // After a relaunch the findings are read once more, into a second note.
            AppLog.error(.provisor, "handoff ledger not saved")
        }
        guard !sweep.admitted.isEmpty else { return }
        for id in sweep.admitted {
            let isBusy = actingID == id || queuedIDs.contains(id)
            do {
                _ = try ProposalStore.recordReturn(
                    id: id,
                    in: ProVisorHome.proposalsURL,
                    settlesOpen: !isBusy
                )
            } catch {
                AppLog.error(.provisor, "handoff return not recorded")
            }
        }
        reloadSoon()
        AppLog.notice(.provisor, "handoff findings admitted \(sweep.admitted.count)")
        armFollowUp()
    }

    private func refusal(for displayed: Proposal) -> DecisionRefusal? {
        ProposalReview.refusal(
            displayed: displayed,
            onFile: proposals.first { $0.id == displayed.id },
            isBusy: actingID == displayed.id || queuedIDs.contains(displayed.id),
            isActive: isActive,
            now: Date()
        )
    }

    /// Records the choice in the proposal's file and queues the run, or does neither.
    ///
    /// The write comes first because a run whose proposal could not be marked would leave the
    /// proposal open in the queue, to be approved and carried out a second time.
    private func enqueue(
        _ proposal: Proposal,
        task: ActTask,
        choice: ProposalChoice,
        standingDecision: String?
    ) -> Bool {
        // The choice is written where the agent reads it: a different option, "just this
        // once", and the user's own words are each how it learns what to propose next time.
        do {
            try ProposalStore.record(
                id: proposal.id,
                in: ProVisorHome.proposalsURL,
                standingDecision: standingDecision,
                choice: choice
            )
        } catch {
            AppLog.error(.provisor, "decision not recorded")
            return false
        }
        reloadSoon()

        // Captured as displayed: the run is instructed from this copy, so nothing written to
        // the file after the tap can change what was approved.
        pendingActs.append(PendingAct(proposal: proposal, task: task))
        queuedIDs.append(proposal.id)
        startNextAct()
        return true
    }

    /// What a queued or running proposal is being carried out as, from the copy captured at
    /// the tap. Nil for one that is neither.
    func capturedAction(for id: String) -> CapturedAction? {
        let pending = actingTask?.proposal.id == id
            ? actingTask
            : pendingActs.first { $0.proposal.id == id }
        guard let pending else { return nil }
        switch pending.task {
        case let .approved(option):
            return CapturedAction(text: option.action, isTyped: false)
        case let .instructed(instruction, _):
            return CapturedAction(text: instruction, isTyped: true)
        case .standing:
            return CapturedAction(text: pending.proposal.recommended.action, isTyped: false)
        }
    }

    /// Takes a standing approval back. Anything still waiting to run under it is dropped and
    /// goes back to being an ordinary proposal awaiting a tap.
    func revokeStanding(_ ruleID: String) {
        updateStanding { StandingApprovals.revoking(ruleID, in: $0, now: Date()) }

        let dropped = Set(pendingActs.filter { $0.task.rule?.id == ruleID }.map(\.proposal.id))
        pendingActs.removeAll { dropped.contains($0.proposal.id) }
        queuedIDs.removeAll { dropped.contains($0) }
        AppLog.notice(.provisor, "standing approval revoked")
    }

    /// Reads the rules from disk, applies `change`, and writes them back. Read first because
    /// the file is the user's to edit; kept in memory only once the write has succeeded, so a
    /// failed save never leaves a rule in force that is not on file.
    private func updateStanding(_ change: ([StandingRule]) -> [StandingRule]) {
        let current = StandingApprovals.load(from: ProVisorHome.standingURL)
        let updated = change(current)
        guard updated != current else {
            standingRules = current
            return
        }
        do {
            try StandingApprovals.save(updated, to: ProVisorHome.standingURL)
            standingRules = updated
        } catch {
            standingRules = current
            AppLog.error(.provisor, "standing approvals not saved")
        }
    }

    /// Admits proposals that name a standing approval in force, up to the per-pass limit.
    ///
    /// `under` is the agent's claim, and the agent has been reading mail from anyone, so the
    /// claim buys only what the code allows: a rule that exists and is in force, the shorter
    /// tool list, and a handful per pass. Whatever is not admitted stays an ordinary proposal.
    private func admitStandingActions(from loaded: [Proposal]) {
        guard isActive else { return }
        let now = Date()
        let candidates = loaded.filter { proposal in
            !automaticIDs.contains(proposal.id)
                // One the person took into a session is theirs; no rule acts on it. The
                // ledger says which those are, since the agent can rewrite a proposal's stamp.
                && !handoffLedger.proposals.contains(proposal.id)
                && actingID != proposal.id
                && !queuedIDs.contains(proposal.id)
                && StandingApprovals.rule(for: proposal, in: standingRules, now: now) != nil
        }
        guard !candidates.isEmpty,
              automaticRunsThisPass < StandingApprovals.actionsPerPass,
              // No tools set aside for unreviewed runs means standing approvals are off.
              let access = try? ProVisorHome.loadAccess(),
              !access.auto.isEmpty
        else { return }

        for proposal in candidates {
            guard automaticRunsThisPass < StandingApprovals.actionsPerPass,
                  let rule = StandingApprovals.rule(for: proposal, in: standingRules, now: now)
            else { break }
            automaticRunsThisPass += 1
            automaticIDs.insert(proposal.id)
            pendingActs.append(PendingAct(proposal: proposal, task: .standing(rule)))
            queuedIDs.append(proposal.id)
        }
        AppLog.notice(.provisor, "standing actions admitted \(automaticRunsThisPass)")
        startNextAct()
    }

    /// Declines an open proposal, or clears the row of one already carried out.
    func dismiss(_ id: String) {
        guard actingID != id, let proposal = proposals.first(where: { $0.id == id }) else {
            return
        }
        pendingActs.removeAll { $0.proposal.id == id }
        queuedIDs.removeAll { $0 == id }

        switch proposal.status {
        case .proposed, .failed:
            record(id, status: .dismissed)
        case .done:
            record(id, cleared: true)
        case .dismissed, .withdrawn:
            break
        }
    }

    private func startNextAct() {
        guard isActive, actingID == nil, !pendingActs.isEmpty else { return }
        let pending = pendingActs.removeFirst()
        let proposal = pending.proposal
        let isAutomatic = pending.task.rule != nil
        queuedIDs.removeAll { $0 == proposal.id }

        let arguments: [String]
        do {
            let access = try ProVisorHome.loadAccess()
            // Sites a later pass can read are named to a run that ends by leaving checks owed.
            let siteNames = bridge.availableSiteNames(access: access)
            let hold = bridge.holdConfigurationPath()
            switch pending.task {
            case let .approved(option):
                arguments = ProVisorCommand.approvedArguments(
                    proposal: proposal,
                    option: option,
                    access: access,
                    siteNames: siteNames,
                    connectorHold: hold
                )
            case let .instructed(instruction, reference):
                arguments = ProVisorCommand.instructedArguments(
                    proposal: proposal,
                    instruction: instruction,
                    reference: reference,
                    access: access,
                    siteNames: siteNames,
                    connectorHold: hold
                )
            case let .standing(rule):
                arguments = ProVisorCommand.automaticArguments(
                    proposal: proposal,
                    rule: rule,
                    access: access,
                    connectorHold: hold
                )
            }
        } catch {
            record(
                proposal.id,
                status: .failed,
                result: error.localizedDescription,
                automatic: isAutomatic ? true : nil
            )
            startNextAct()
            return
        }

        actingTask = pending
        actingID = proposal.id
        AppLog.notice(.provisor, "action started")

        let service = AgentTaskService()
        actService = service
        let activation = self.activation
        Task { [weak self] in
            let outcome: Result<AgentTaskResult, any Error>
            do {
                outcome = .success(try await service.run(
                    arguments: arguments,
                    workingDirectory: ProVisorHome.workspaceURL,
                    timeout: ProVisorCenter.actTimeout
                ))
            } catch {
                outcome = .failure(error)
            }
            self?.finishAct(
                proposal.id,
                outcome: outcome,
                isAutomatic: isAutomatic,
                activation: activation
            )
        }
    }

    private func finishAct(
        _ id: String,
        outcome: Result<AgentTaskResult, any Error>,
        isAutomatic: Bool,
        activation: Int
    ) {
        guard activation == self.activation else { return }
        actService = nil
        actingTask = nil
        actingID = nil

        switch outcome {
        case let .success(result):
            let report = ActionReport(result.text)
            AppLog.notice(
                .provisor,
                "action finished, \(report.needsNotice ? "result kept in the sheet" : "nothing left to show")"
            )
            write {
                try ProposalStore.recordCarriedOut(
                    id: id,
                    in: ProVisorHome.proposalsURL,
                    report: report,
                    automatic: isAutomatic
                )
            }
        case let .failure(error):
            AppLog.error(.provisor, "action failed: \(Self.logName(error))")
            record(
                id,
                status: .failed,
                result: error.localizedDescription,
                automatic: isAutomatic ? true : nil
            )
        }
        // A reviewed run may have raised something it found and could not settle.
        admitRaisedItems()
        Task { [weak self] in
            guard let loaded = await self?.reload(), activation == self?.activation else {
                return
            }
            self?.announceAdded(in: loaded)
        }
        // A run under a standing approval writes no notes; a reviewed one may leave a check owed.
        if !isAutomatic {
            armFollowUp()
        }
        startNextAct()
    }

    /// Writes a decision or an outcome into the proposal's file, where the agent reads it on
    /// its next pass.
    private func record(
        _ id: String,
        status: Proposal.Status? = nil,
        result: String? = nil,
        cleared: Bool? = nil,
        automatic: Bool? = nil
    ) {
        write {
            try ProposalStore.record(
                id: id,
                in: ProVisorHome.proposalsURL,
                status: status,
                result: Proposal.displayText(result, limit: Proposal.resultLimit),
                cleared: cleared,
                automatic: automatic
            )
        }
    }

    /// Makes one change to a proposal file and reloads the queue.
    private func write(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            AppLog.error(.provisor, "decision not recorded")
        }
        reloadSoon()
    }

    // MARK: - Proposals on disk

    private func reloadSoon() {
        Task { [weak self] in
            _ = await self?.reload()
        }
    }

    /// Reads the proposals folder off the main actor and publishes the result.
    @discardableResult
    private func reload() async -> [Proposal] {
        reloadSequence += 1
        let sequence = reloadSequence
        let directory = ProVisorHome.proposalsURL
        let loaded = await Task.detached(priority: .utility) {
            ProposalStore.load(from: directory)
        }.value

        // A slower, older read must not replace a newer one.
        if sequence == reloadSequence, isActive {
            announcer.seedIfNeeded(with: loaded)
            if loaded != proposals {
                proposals = loaded
                onProposalsChanged?()
            }
            let sites = SiteAccessCenter.shared
            let state = signInState(sites: sites.sites, awaiting: sites.awaitingSignIn, now: Date())
            signInAnnouncer.seedIfNeeded(
                with: SignInDemand.prompts(in: state.items, postponed: postponements.hosts),
                pending: state.pending
            )
            publishSignInDemand(state)
            admitStandingActions(from: loaded)
        }
        return loaded
    }

    // MARK: - Sign-in demand

    /// Follows the site list and the sites runs were turned away from. The values the
    /// publishers deliver are used as they come: a `@Published` property still holds its old
    /// value while its subscribers run.
    private func startWatchingSignInDemand() {
        let sites = SiteAccessCenter.shared
        sites.refresh()
        sites.onSiteSaved = { [weak self] record, wasAwaited in
            self?.siteSaved(record, wasAwaited: wasAwaited)
        }
        sites.onPersonNeeded = { [weak self] siteID in
            self?.siteTurnedAway(siteID)
        }
        hostRecognition.onAnswer = { [weak self] in
            self?.refreshSignInDemand()
        }
        signInSubscription = Publishers.CombineLatest(sites.$sites, sites.$awaitingSignIn)
            .sink { [weak self] records, awaiting in
                guard let self, isActive else { return }
                publishSignInDemand(signInState(sites: records, awaiting: awaiting, now: Date()))
            }
    }

    private func stopWatchingSignInDemand() {
        signInSubscription?.cancel()
        signInSubscription = nil
        SiteAccessCenter.shared.onSiteSaved = nil
        SiteAccessCenter.shared.onPersonNeeded = nil
        hostRecognition.onAnswer = nil
        hostRecognition.reset()
        signInAnnouncer = SignInAnnouncer()
        postponements = SignInPostponements()
        requestsAwaitingRecognition = []
        demandExpiryTask?.cancel()
        demandExpiryTask = nil
    }

    /// Hides a granted site's prompt, and keeps it from the banner, until a run is next turned
    /// away from it (`SignInPostponements`).
    func postponeSignIn(_ item: SignInDemand.Item) {
        guard isActive else { return }
        postponements.postpone(item)
        AppLog.notice(.provisor, "sign-in put off for \(item.host)")
        refreshSignInDemand()
    }

    /// A run was turned away from `siteID`: a prompt put off for it is offered again, and
    /// announced as new.
    private func siteTurnedAway(_ siteID: String) {
        guard isActive, postponements.hosts.contains(siteID) else { return }
        postponements.turnedAway(siteID)
        refreshSignInDemand()
    }

    private func refreshSignInDemand() {
        guard isActive else { return }
        let sites = SiteAccessCenter.shared
        publishSignInDemand(signInState(sites: sites.sites, awaiting: sites.awaitingSignIn, now: Date()))
    }

    /// The demand at one instant, which every part of a publish judges by.
    private struct SignInState {
        let items: [SignInDemand.Item]
        /// The hosts in demand whose recognition is still being looked up, so not yet shown.
        let pending: Set<String>
        /// The open requests for the hosts in `pending`.
        let awaitingRecognition: Set<String>
        let now: Date
    }

    private func signInState(sites: [SiteRecord], awaiting: Set<String>, now: Date) -> SignInState {
        let items = SignInDemand.items(
            proposals: proposals,
            sites: sites,
            awaiting: awaiting,
            now: now,
            recognised: hostRecognition.recognised
        )
        let pending = SignInDemand.hostsAwaitingRecognition(
            proposals: proposals,
            sites: sites,
            now: now,
            recognised: hostRecognition.recognised
        )
        return SignInState(
            items: items,
            pending: pending,
            awaitingRecognition: SignInDemand.requestIDs(forHosts: pending, in: proposals, now: now),
            now: now
        )
    }

    /// Publishes the items and the prompts drawn from them when they differ from the last ones,
    /// passes on the prompts the person has not been told about, counts the held-back requests
    /// whose host has been looked up, and arms the wait for the next request to expire.
    private func publishSignInDemand(_ state: SignInState) {
        if state.items != signInDemand {
            signInDemand = state.items
        }
        postponements.prune(keeping: state.items)
        let prompts = SignInDemand.prompts(in: state.items, postponed: postponements.hosts)
        if prompts != signInPrompts {
            signInPrompts = prompts
        }
        requestsAwaitingRecognition = state.awaitingRecognition
        armDemandExpiry(now: state.now)
        let fresh = signInAnnouncer.newItems(in: prompts, pending: state.pending)
        if !fresh.isEmpty {
            AppLog.notice(.provisor, "sign-in needed \(fresh.count)")
            onSignInNeeded?(fresh)
        }
        announceReleased(now: state.now)
    }

    /// Arms the one wait for the soonest open site request to expire after `now`, replacing any
    /// armed before; with no request that expires, nothing waits.
    private func armDemandExpiry(now: Date) {
        demandExpiryTask?.cancel()
        demandExpiryTask = nil
        guard isActive, let expiry = SignInDemand.nextExpiry(of: proposals, now: now) else { return }
        demandExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSince(Date()))))
            guard let self, !Task.isCancelled else { return }
            self.demandExpiryTask = nil
            self.refreshSignInDemand()
        }
    }

    // MARK: - Reporting

    private func report(setupFailure error: any Error) {
        lastScoutFailure = Self.setupFailureSentence(error)
        AppLog.error(.provisor, "setup failed")
    }

    /// Why a pass could not be set up, in words the app wrote: a setup error's own
    /// description, which names a file of the user's, or one sentence for a folder or file
    /// that could not be made.
    static func setupFailureSentence(_ error: any Error) -> String {
        (error as? ProVisorSetupError)?.localizedDescription
            ?? "ProVisor's folder could not be prepared."
    }

    /// Why a pass that started failed, in words the app wrote (`AgentTaskError.fixedDescription`).
    static func failureSentence(_ error: any Error) -> String {
        (error as? AgentTaskError)?.fixedDescription ?? "The scouting pass failed."
    }

    /// Names a failure for the log without its text, which can quote the agent's own output —
    /// and that output is drawn from the user's mail.
    private static func logName(_ error: any Error) -> String {
        guard let error = error as? AgentTaskError else { return "unexpected" }
        switch error {
        case .binaryNotFound: return "binary not found"
        case .launchFailed: return "launch failed"
        case .unreadableSource: return "unreadable source"
        case .timedOut: return "timed out"
        case .cancelled: return "cancelled"
        case .agentError: return "agent error"
        case let .limitReached(limit): return limit.logName
        case .malformedOutput: return "malformed output"
        }
    }
}
