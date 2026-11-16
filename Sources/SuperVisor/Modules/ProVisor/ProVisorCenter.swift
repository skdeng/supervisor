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
/// A singleton because Settings needs the live state and reaches no module instance: the
/// registry builds a second, never-activated set of modules just to list their names.
@MainActor
final class ProVisorCenter: ObservableObject {
    static let shared = ProVisorCenter()

    /// How the most recent scouting pass ended.
    struct ScoutReport: Equatable {
        let finished: Date
        /// The agent's closing summary, or why the pass failed.
        let text: String
        let failed: Bool
    }

    /// Every valid proposal on disk, whatever its status. `ProposalQueue` picks what shows.
    @Published private(set) var proposals: [Proposal] = []
    @Published private(set) var isScouting = false
    /// The proposal an acting run is carrying out right now.
    @Published private(set) var actingID: String?
    /// Approved proposals waiting behind the acting run.
    @Published private(set) var queuedIDs: [String] = []
    @Published private(set) var lastScout: ScoutReport?
    /// The user's standing approvals, in force and revoked, as last read from disk.
    @Published private(set) var standingRules: [StandingRule] = []
    /// Whether the module is enabled and the center is watching and scheduling.
    @Published private(set) var isActive = false

    /// Called when the set of proposals on disk changes.
    var onProposalsChanged: (() -> Void)?
    /// Called with how many proposals a scouting pass added.
    var onScoutAdded: ((Int) -> Void)?

    private static let lastScoutKey = "provisor.lastScoutAt"
    private static let scoutTimeout: Duration = .seconds(20 * 60)
    private static let actTimeout: Duration = .seconds(10 * 60)

    private let defaults: UserDefaults
    private var watcher: DirectoryTreeWatcher?
    private var scheduleTask: Task<Void, Never>?
    private var cadenceSubscription: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var scoutService: AgentTaskService?
    private var actService: AgentTaskService?
    /// A proposal waiting to be carried out: approved by a tap, or — with `rule` — admitted
    /// under a standing approval. Each is captured as it stood at that moment.
    private struct PendingAct {
        let proposal: Proposal
        let rule: StandingRule?
    }

    private var pendingActs: [PendingAct] = []
    /// Proposals already admitted under a standing approval, so a reload never admits one twice.
    private var automaticIDs: Set<String> = []
    private var automaticRunsThisPass = 0
    private var lastAttempt: Date?
    /// Bumped on every start and stop, so a run that outlives its activation reports to nobody.
    private var activation = 0
    private var reloadSequence = 0

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
                MainActor.assumeIsolated { self?.cancelSchedule() }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.armSchedule() }
            },
        ]

        // Publishes the current cadence on subscription, which arms the first timer.
        cadenceSubscription = SettingsStore.shared.$provisorScoutHours
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.armSchedule() }
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        activation += 1

        cancelSchedule()
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
        let services = [scoutService, actService].compactMap { $0 }
        scoutService = nil
        actService = nil
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

        pendingActs = []
        queuedIDs = []
        actingID = nil
        isScouting = false
        proposals = []
        standingRules = []
        automaticIDs = []
        automaticRunsThisPass = 0
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

    private func startScout() {
        guard isActive, !isScouting else { return }

        // Read fresh: the file is the user's, and may have been edited by hand since.
        standingRules = StandingApprovals.load(from: ProVisorHome.standingURL)

        let arguments: [String]
        do {
            try ProVisorHome.prepare()
            arguments = try ProVisorCommand.scoutArguments(
                brief: ProVisorHome.loadBrief(),
                access: ProVisorHome.loadAccess(),
                standing: standingRules,
                now: Date()
            )
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

        let service = AgentTaskService()
        scoutService = service
        let knownIDs = Set(proposals.map(\.id))
        let activation = self.activation
        Task { [weak self] in
            let outcome: Result<AgentTaskResult, any Error>
            do {
                outcome = .success(try await service.run(
                    arguments: arguments,
                    workingDirectory: ProVisorHome.workspaceURL,
                    timeout: ProVisorCenter.scoutTimeout
                ))
            } catch {
                outcome = .failure(error)
            }
            await self?.finishScout(outcome, knownIDs: knownIDs, activation: activation)
        }
    }

    private func finishScout(
        _ outcome: Result<AgentTaskResult, any Error>,
        knownIDs: Set<String>,
        activation: Int
    ) async {
        guard activation == self.activation else { return }
        scoutService = nil
        isScouting = false

        let finished = Date()
        switch outcome {
        case let .success(result):
            defaults.set(finished.timeIntervalSince1970, forKey: Self.lastScoutKey)
            lastScout = ScoutReport(
                finished: finished,
                text: Proposal.displayText(result.text, limit: 600) ?? "Finished.",
                failed: false
            )
            AppLog.notice(.provisor, "scout finished")
        case let .failure(error):
            lastScout = ScoutReport(
                finished: finished,
                text: Proposal.displayText(error.localizedDescription, limit: 600)
                    ?? "The scouting pass failed.",
                failed: true
            )
            AppLog.error(.provisor, "scout failed: \(Self.logName(error))")
        }

        // A pass cut off by a limit still leaves the proposals it had already written, so the
        // count is taken from disk either way.
        let loaded = await reload()
        guard activation == self.activation else { return }
        // Only what needs a decision is announced. Something admitted under a standing
        // approval is being dealt with, which is the point of having given one.
        let added = loaded.filter { proposal in
            proposal.status == .proposed
                && !knownIDs.contains(proposal.id)
                && !automaticIDs.contains(proposal.id)
        }.count
        if added > 0 {
            AppLog.notice(.provisor, "scout added \(added)")
            onScoutAdded?(added)
        }
        armSchedule()
    }

    // MARK: - Decisions

    /// Approves a proposal and queues the run that carries it out. With `always`, the rule the
    /// proposal offered also becomes a standing approval.
    func approve(_ id: String, always: Bool = false) {
        guard isActive,
              actingID != id,
              !queuedIDs.contains(id),
              let proposal = proposals.first(where: { $0.id == id }),
              proposal.isOpen
        else { return }
        // Captured as displayed: the run is instructed from this copy, so nothing written to
        // the file after the tap can change what was approved. This run was reviewed, so it
        // gets the reviewed tool list whether or not a rule comes of it.
        pendingActs.append(PendingAct(proposal: proposal, rule: nil))
        queuedIDs.append(id)

        // An offer is answered either way, and the answer is written where the agent reads it:
        // "just this once" is how it learns that this kind of thing is to keep being asked.
        if let offer = proposal.standingOffer {
            if always {
                updateStanding { rules in
                    guard let rule = StandingApprovals.rule(adding: offer, to: rules, now: Date())
                    else { return rules }
                    return rules + [rule]
                }
            }
            record(id, standingDecision: always ? "accepted" : "declined")
        }
        startNextAct()
    }

    /// Takes a standing approval back. Anything still waiting to run under it is dropped and
    /// goes back to being an ordinary proposal awaiting a tap.
    func revokeStanding(_ ruleID: String) {
        updateStanding { StandingApprovals.revoking(ruleID, in: $0, now: Date()) }

        let dropped = Set(pendingActs.filter { $0.rule?.id == ruleID }.map(\.proposal.id))
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
            pendingActs.append(PendingAct(proposal: proposal, rule: rule))
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
        let isAutomatic = pending.rule != nil
        queuedIDs.removeAll { $0 == proposal.id }

        let arguments: [String]
        do {
            arguments = try ProVisorCommand.actArguments(
                proposal: proposal,
                access: ProVisorHome.loadAccess(),
                under: pending.rule
            )
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
        actingID = nil

        switch outcome {
        case let .success(result):
            AppLog.notice(.provisor, "action finished")
            record(
                id,
                status: .done,
                result: result.text.isEmpty ? "Done." : result.text,
                automatic: isAutomatic ? true : nil
            )
        case let .failure(error):
            AppLog.error(.provisor, "action failed: \(Self.logName(error))")
            record(
                id,
                status: .failed,
                result: error.localizedDescription,
                automatic: isAutomatic ? true : nil
            )
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
        standingDecision: String? = nil,
        automatic: Bool? = nil
    ) {
        do {
            try ProposalStore.record(
                id: id,
                in: ProVisorHome.proposalsURL,
                status: status,
                result: Proposal.displayText(result, limit: Proposal.resultLimit),
                cleared: cleared,
                standingDecision: standingDecision,
                automatic: automatic
            )
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
            if loaded != proposals {
                proposals = loaded
                onProposalsChanged?()
            }
            admitStandingActions(from: loaded)
        }
        return loaded
    }

    // MARK: - Reporting

    private func report(setupFailure error: any Error) {
        lastScout = ScoutReport(
            finished: Date(),
            text: error.localizedDescription,
            failed: true
        )
        AppLog.error(.provisor, "setup failed")
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
        case .malformedOutput: return "malformed output"
        }
    }
}
