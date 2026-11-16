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
        actingTask = nil
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
        guard displayed.options.indices.contains(index) else { return .unavailable }

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
        guard displayed.options.indices.contains(index),
              let instruction = ProposalReview.instruction(from: text)
        else { return .unavailable }

        return enqueue(
            displayed,
            task: .instructed(instruction, reference: displayed.options[index]),
            choice: .instruction(instruction),
            standingDecision: nil
        ) ? nil : .notSaved
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
            switch pending.task {
            case let .approved(option):
                arguments = ProVisorCommand.approvedArguments(
                    proposal: proposal,
                    option: option,
                    access: access
                )
            case let .instructed(instruction, reference):
                arguments = ProVisorCommand.instructedArguments(
                    proposal: proposal,
                    instruction: instruction,
                    reference: reference,
                    access: access
                )
            case let .standing(rule):
                arguments = ProVisorCommand.automaticArguments(
                    proposal: proposal,
                    rule: rule,
                    access: access
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
        automatic: Bool? = nil
    ) {
        do {
            try ProposalStore.record(
                id: id,
                in: ProVisorHome.proposalsURL,
                status: status,
                result: Proposal.displayText(result, limit: Proposal.resultLimit),
                cleared: cleared,
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
