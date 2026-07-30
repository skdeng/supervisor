import AppKit
import Combine
import CoreGraphics
import EventKit
import Foundation

enum FlowSegmentKind: Equatable {
    case work
    case breakTime
}

struct FlowSegment: Identifiable, Equatable {
    let id = UUID()
    let start: Date
    let end: Date
    let kind: FlowSegmentKind
}

enum FlowCompactPresentation: Equatable {
    case breakCountdown(start: Date, until: Date)
    case recharged
}

struct FlowBreakWindow: Equatable {
    let start: Date
    let until: Date
}

/// Activity-aware work and break state derived only from seconds since the last user input.
/// One cancellable deadline task sleeps until the next state-machine boundary or input sample.
@MainActor
final class FlowTracker: ObservableObject {
    private struct Session {
        var activeSegmentStart: Date
        var completedWork: TimeInterval
        var lastActivity: Date
        var nudgeDeferredUntil: Date?
        var hadNudge: Bool

        func workDuration(at date: Date) -> TimeInterval {
            completedWork + max(0, date.timeIntervalSince(activeSegmentStart))
        }
    }

    private enum Phase {
        case idle
        case working(Session)
        case nudgePending(Session, meetingEnd: Date?)
        case nudged(Session, nextRepeek: Date, message: String)
        case resting(Session, since: Date)
        case onBreak(start: Date, until: Date)
    }

    private static let naturalBreakThreshold: TimeInterval = 180
    private static let recentInputThreshold: TimeInterval = 60
    private static let microPauseThreshold: TimeInterval = 10
    private static let normalSampleCadence: TimeInterval = 60
    private static let pendingSampleCadence: TimeInterval = 5
    private static let finalStretchDuration: TimeInterval = 10 * 60
    private static let snoozeDuration: TimeInterval = 10 * 60
    private static let skipDuration: TimeInterval = 60 * 60
    private static let repeekDuration: TimeInterval = 15 * 60
    private static let acknowledgementDuration: TimeInterval = 4

    @Published private var phase: Phase = .idle
    @Published private(set) var currentWorkDuration: TimeInterval = 0
    @Published private(set) var daySegments: [FlowSegment] = []
    @Published private(set) var acknowledgementUntil: Date?

    private let settings: SettingsStore
    private let eventStore = EKEventStore()
    private var context: NotchContext?
    private var deadlineTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var screenObservers: [NSObjectProtocol] = []
    private var settingsCancellables = Set<AnyCancellable>()
    private var isActive = false
    private var isSleeping = false
    private var isScreenLocked = false
    private var suspensionBreakCandidate: Date?
    private var lastIdleSampleAt: Date?
    private var idleSessionFloor: Date?
    private var compactPresence = false
    private var bannerPresence = false
    private var dayAnchor: Date

    init(settings: SettingsStore = .shared) {
        self.settings = settings
        self.dayAnchor = Calendar.current.startOfDay(for: Date())
    }

    /// The pill stays empty during a work session — the nudge banner is the only work-time
    /// surfacing; compact presence exists solely for a running break and the recharged ack.
    var compactPresentation: FlowCompactPresentation? {
        if let window = breakWindow {
            return .breakCountdown(start: window.start, until: window.until)
        }
        if acknowledgementUntil != nil {
            return .recharged
        }
        return nil
    }

    var hasExpandedPresentation: Bool {
        switch phase {
        case .idle:
            return acknowledgementUntil != nil
        default:
            return true
        }
    }

    var breakWindow: FlowBreakWindow? {
        guard case let .onBreak(start, until) = phase else { return nil }
        return FlowBreakWindow(start: start, until: until)
    }

    var nudgeMessage: String? {
        guard case let .nudged(_, _, message) = phase else { return nil }
        return message
    }

    /// Today's closed segments plus the current open segment (work or break) extended to now, so
    /// the timeline colors work in progress instead of ending at the last committed block.
    var timelineSegments: [FlowSegment] {
        let now = Date()
        var result = daySegments
        switch phase {
        case let .working(session),
             let .nudgePending(session, _),
             let .nudged(session, _, _):
            let start = max(session.activeSegmentStart, dayAnchor)
            if now > start {
                result.append(FlowSegment(start: start, end: now, kind: .work))
            }
        case let .resting(_, since):
            let start = max(since, dayAnchor)
            if now > start {
                result.append(FlowSegment(start: start, end: now, kind: .breakTime))
            }
        case let .onBreak(start, _):
            let clampedStart = max(start, dayAnchor)
            if now > clampedStart {
                result.append(FlowSegment(start: clampedStart, end: now, kind: .breakTime))
            }
        case .idle:
            break
        }
        return result
    }

    /// The Take/Snooze/Skip actions surface only once a session reaches its final stretch (the
    /// last stretch before a nudge) — before that there is no imminent break to act on.
    var showsBreakActions: Bool {
        guard sessionIsActive else { return false }
        let stretchStart = max(0, workInterval - Self.finalStretchDuration)
        return currentWorkDuration >= stretchStart
    }

    var breakLengthMinutes: Int {
        settings.flowBreakLengthMinutes
    }

    var isAcknowledgingWithoutSession: Bool {
        guard acknowledgementUntil != nil else { return false }
        if case .idle = phase { return true }
        return false
    }

    func activate(_ context: NotchContext) {
        guard !isActive else { return }
        isActive = true
        self.context = context
        compactPresence = false
        bannerPresence = false
        dayAnchor = Calendar.current.startOfDay(for: Date())
        installSystemObservers()
        observeSettings()
        evaluate(at: Date())
        reconcileCompactPresence()
        armNextDeadline()
    }

    func deactivate() {
        guard isActive else { return }
        cancelDeadline()
        removeSystemObservers()
        settingsCancellables.removeAll()
        phase = .idle
        currentWorkDuration = 0
        daySegments = []
        acknowledgementUntil = nil
        lastIdleSampleAt = nil
        idleSessionFloor = nil
        suspensionBreakCandidate = nil
        isSleeping = false
        isScreenLocked = false
        isActive = false
        if compactPresence || bannerPresence {
            let hadBanner = bannerPresence
            compactPresence = false
            bannerPresence = false
            context?.setNeedsCompactRefresh()
            // Deactivating mid-nudge abandons an indefinite peek; a zero-length peek releases
            // the hold without forcing an open sheet closed.
            if hadBanner {
                context?.requestPeek(0)
            }
        }
        self.context = nil
    }

    func takeBreak() {
        guard isActive, breakWindow == nil else { return }
        let now = Date()
        rolloverDayIfNeeded(at: now)

        switch phase {
        case let .working(session),
             let .nudgePending(session, _),
             let .nudged(session, _, _):
            _ = closeWorkSegment(session, at: now)
        case let .resting(_, since):
            appendSegment(start: since, end: now, kind: .breakTime)
        case .idle, .onBreak:
            return
        }

        acknowledgementUntil = nil
        currentWorkDuration = 0
        phase = .onBreak(
            start: now,
            until: now.addingTimeInterval(TimeInterval(settings.flowBreakLengthMinutes * 60))
        )
        AppLog.notice(.flow, "break taken")
        reconcileCompactPresence()
        armNextDeadline()
    }

    func endBreakEarly() {
        guard case let .onBreak(start, _) = phase else { return }
        let now = Date()
        rolloverDayIfNeeded(at: now)
        appendSegment(start: start, end: now, kind: .breakTime)
        phase = .idle
        currentWorkDuration = 0
        acknowledgementUntil = nil
        idleSessionFloor = now
        evaluate(at: now)
        reconcileCompactPresence()
        armNextDeadline()
    }

    func snooze() {
        guard activeSessionForNudgeAction != nil else { return }
        AppLog.notice(.flow, "break snoozed")
        deferNudge(by: Self.snoozeDuration, suppressForAtLeast: nil)
    }

    func skip() {
        guard activeSessionForNudgeAction != nil else { return }
        AppLog.notice(.flow, "break skipped")
        deferNudge(by: nil, suppressForAtLeast: Self.skipDuration)
    }

    private var workInterval: TimeInterval {
        TimeInterval(settings.flowWorkIntervalMinutes * 60)
    }

    private var sessionIsActive: Bool {
        switch phase {
        case .working, .nudgePending, .nudged, .resting:
            return true
        case .idle, .onBreak:
            return false
        }
    }

    private func installSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(true) }
            }
        )
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSleeping(false) }
            }
        )

        let screenCenter = DistributedNotificationCenter.default()
        screenObservers.append(
            screenCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenLocked(true) }
            }
        )
        screenObservers.append(
            screenCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setScreenLocked(false) }
            }
        )
    }

    private func removeSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let screenCenter = DistributedNotificationCenter.default()
        for observer in screenObservers {
            screenCenter.removeObserver(observer)
        }
        screenObservers.removeAll()
    }

    private func observeSettings() {
        settings.$flowWorkIntervalMinutes
            .combineLatest(
                settings.$flowBreakLengthMinutes,
                settings.$flowDeferDuringMeetings
            )
            .dropFirst()
            .sink { [weak self] _, _, _ in
                self?.settingsDidChange()
            }
            .store(in: &settingsCancellables)
        MeetingDismissalStore.shared.$dismissed
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.settingsDidChange()
            }
            .store(in: &settingsCancellables)
    }

    private func settingsDidChange() {
        guard isActive, !isSuspended else { return }
        evaluate(at: Date())
        reconcileCompactPresence()
        armNextDeadline()
    }

    private var isSuspended: Bool {
        isSleeping || isScreenLocked
    }

    private func setSleeping(_ sleeping: Bool) {
        let wasSuspended = isSuspended
        isSleeping = sleeping
        handleSuspensionEdge(wasSuspended: wasSuspended)
    }

    private func setScreenLocked(_ locked: Bool) {
        let wasSuspended = isSuspended
        isScreenLocked = locked
        handleSuspensionEdge(wasSuspended: wasSuspended)
    }

    private func handleSuspensionEdge(wasSuspended: Bool) {
        guard isActive else { return }
        if !wasSuspended, isSuspended {
            prepareForSuspension(at: Date())
        } else if wasSuspended, !isSuspended {
            resumeAfterSuspension(at: Date())
        }
    }

    private func prepareForSuspension(at now: Date) {
        rolloverDayIfNeeded(at: now)
        updateLastActivityForSuspension(at: now)
        switch phase {
        case let .working(session),
             let .nudgePending(session, _),
             let .nudged(session, _, _):
            suspensionBreakCandidate = session.lastActivity
        case let .resting(_, since):
            suspensionBreakCandidate = since
        case .idle, .onBreak:
            suspensionBreakCandidate = nil
        }
        cancelDeadline()
    }

    private func updateLastActivityForSuspension(at now: Date) {
        guard let idle = readIdleSeconds() else { return }
        lastIdleSampleAt = now
        let observedActivity = now.addingTimeInterval(-idle)
        switch phase {
        case var .working(session):
            session.lastActivity = clampedActivity(observedActivity, for: session, now: now)
            phase = .working(session)
            currentWorkDuration = session.workDuration(at: now)
        case let .nudgePending(stored, meetingEnd):
            var session = stored
            session.lastActivity = clampedActivity(observedActivity, for: session, now: now)
            phase = .nudgePending(session, meetingEnd: meetingEnd)
            currentWorkDuration = session.workDuration(at: now)
        case let .nudged(stored, nextRepeek, message):
            var session = stored
            session.lastActivity = clampedActivity(observedActivity, for: session, now: now)
            phase = .nudged(session, nextRepeek: nextRepeek, message: message)
            currentWorkDuration = session.workDuration(at: now)
        case .idle, .resting, .onBreak:
            break
        }
    }

    private func resumeAfterSuspension(at now: Date) {
        defer {
            suspensionBreakCandidate = nil
        }
        rolloverDayIfNeeded(at: now)

        if case let .onBreak(_, until) = phase, now >= until {
            finishScheduledBreak(until: until, presentationTime: now)
        } else if let candidate = suspensionBreakCandidate,
                  now.timeIntervalSince(candidate) >= Self.naturalBreakThreshold {
            enterRestingIfNeeded(at: candidate)
        }

        evaluate(at: now)
        reconcileCompactPresence()
        armNextDeadline()
    }

    private func evaluate(at now: Date) {
        guard isActive, !isSuspended else { return }
        rolloverDayIfNeeded(at: now)
        expireAcknowledgementIfNeeded(at: now)

        if case let .onBreak(_, until) = phase {
            if now >= until {
                finishScheduledBreak(until: until, presentationTime: now)
                sampleIdleAndAdvance(at: now)
            }
            return
        }

        sampleIdleAndAdvance(at: now)
    }

    private func sampleIdleAndAdvance(at now: Date) {
        guard let idle = readIdleSeconds() else { return }
        lastIdleSampleAt = now

        switch phase {
        case .idle:
            guard idle < Self.recentInputThreshold else { return }
            let observedActivity = now.addingTimeInterval(-idle)
            let start = maxDate(observedActivity, idleSessionFloor)
            idleSessionFloor = nil
            let session = Session(
                activeSegmentStart: start,
                completedWork: 0,
                lastActivity: observedActivity,
                nudgeDeferredUntil: nil,
                hadNudge: false
            )
            phase = .working(session)
            currentWorkDuration = session.workDuration(at: now)
            advanceWorkingState(session, idle: idle, at: now)

        case let .working(session):
            handleActiveSessionSample(session, idle: idle, phase: .working, at: now)

        case let .nudgePending(session, meetingEnd):
            handleActiveSessionSample(
                session,
                idle: idle,
                phase: .pending(meetingEnd: meetingEnd),
                at: now
            )

        case let .nudged(session, nextRepeek, message):
            handleActiveSessionSample(
                session,
                idle: idle,
                phase: .nudged(nextRepeek: nextRepeek, message: message),
                at: now
            )

        case let .resting(session, since):
            guard idle < Self.naturalBreakThreshold else {
                currentWorkDuration = session.completedWork
                return
            }
            resumeFromNaturalBreak(session, since: since, idle: idle, at: now)

        case .onBreak:
            break
        }
    }

    private enum ActivePhase {
        case working
        case pending(meetingEnd: Date?)
        case nudged(nextRepeek: Date, message: String)
    }

    private func handleActiveSessionSample(
        _ storedSession: Session,
        idle: TimeInterval,
        phase activePhase: ActivePhase,
        at now: Date
    ) {
        var session = storedSession
        let observedActivity = now.addingTimeInterval(-idle)
        session.lastActivity = clampedActivity(observedActivity, for: session, now: now)

        if idle >= Self.naturalBreakThreshold {
            enterResting(session, at: session.lastActivity)
            return
        }

        currentWorkDuration = session.workDuration(at: now)
        switch activePhase {
        case .working:
            phase = .working(session)
            advanceWorkingState(session, idle: idle, at: now)
        case .pending:
            phase = .nudgePending(session, meetingEnd: nil)
            evaluateNudgeGates(session, idle: idle, at: now)
        case let .nudged(nextRepeek, message):
            if now >= nextRepeek {
                let next = nextRepeekDate(after: nextRepeek, relativeTo: now)
                let updatedMessage = makeNudgeMessage(elapsed: currentWorkDuration, repeated: true)
                phase = .nudged(session, nextRepeek: next, message: updatedMessage)
                context?.requestPeek(.infinity)
            } else {
                phase = .nudged(session, nextRepeek: nextRepeek, message: message)
            }
        }
    }

    private func advanceWorkingState(_ storedSession: Session, idle: TimeInterval, at now: Date) {
        var session = storedSession
        guard isNudgeEligible(session, at: now) else {
            phase = .working(session)
            return
        }
        session.nudgeDeferredUntil = nil
        phase = .nudgePending(session, meetingEnd: nil)
        evaluateNudgeGates(session, idle: idle, at: now)
    }

    private func evaluateNudgeGates(_ session: Session, idle: TimeInterval, at now: Date) {
        guard idle >= Self.microPauseThreshold else {
            phase = .nudgePending(session, meetingEnd: nil)
            return
        }
        if settings.flowDeferDuringMeetings, let meetingEnd = currentMeetingEnd(at: now) {
            phase = .nudgePending(session, meetingEnd: meetingEnd)
            return
        }
        fireNudge(session, at: now)
    }

    private func fireNudge(_ storedSession: Session, at now: Date) {
        var session = storedSession
        session.hadNudge = true
        let message = makeNudgeMessage(elapsed: currentWorkDuration, repeated: false)
        phase = .nudged(
            session,
            nextRepeek: now.addingTimeInterval(Self.repeekDuration),
            message: message
        )
        AppLog.notice(.flow, "nudge fired")
        // The nudge banner holds until the user acts on it or a real break resolves it;
        // reconcileCompactPresence ends the peek when the banner clears.
        context?.requestPeek(.infinity)
    }

    private func enterRestingIfNeeded(at breakStart: Date) {
        switch phase {
        case let .working(session),
             let .nudgePending(session, _),
             let .nudged(session, _, _):
            enterResting(session, at: breakStart)
        case .idle, .resting, .onBreak:
            break
        }
    }

    private func enterResting(_ session: Session, at breakStart: Date) {
        let closed = closeWorkSegment(session, at: breakStart)
        currentWorkDuration = closed.completedWork
        phase = .resting(closed, since: breakStart)
    }

    private func resumeFromNaturalBreak(
        _ storedSession: Session,
        since breakStart: Date,
        idle: TimeInterval,
        at now: Date
    ) {
        let activity = now.addingTimeInterval(-idle)
        let awayDuration = max(0, activity.timeIntervalSince(breakStart))
        appendSegment(start: breakStart, end: activity, kind: .breakTime)

        if awayDuration >= Self.naturalBreakThreshold {
            let shouldAcknowledge = storedSession.hadNudge
            let freshSession = Session(
                activeSegmentStart: activity,
                completedWork: 0,
                lastActivity: activity,
                nudgeDeferredUntil: nil,
                hadNudge: false
            )
            phase = .working(freshSession)
            currentWorkDuration = freshSession.workDuration(at: now)
            if shouldAcknowledge {
                acknowledgementUntil = now.addingTimeInterval(Self.acknowledgementDuration)
                AppLog.notice(.flow, "recharged acknowledgement shown")
            }
            advanceWorkingState(freshSession, idle: idle, at: now)
        } else {
            var session = storedSession
            session.activeSegmentStart = activity
            session.lastActivity = activity
            phase = .working(session)
            currentWorkDuration = session.workDuration(at: now)
            advanceWorkingState(session, idle: idle, at: now)
        }
    }

    private func finishScheduledBreak(until: Date, presentationTime: Date) {
        guard case let .onBreak(start, _) = phase else { return }
        appendSegment(start: start, end: until, kind: .breakTime)
        phase = .idle
        currentWorkDuration = 0
        idleSessionFloor = until
        acknowledgementUntil = presentationTime.addingTimeInterval(Self.acknowledgementDuration)
        AppLog.notice(.flow, "recharged acknowledgement shown")
    }

    private func deferNudge(by delay: TimeInterval?, suppressForAtLeast minimum: TimeInterval?) {
        let now = Date()
        guard var session = activeSessionForNudgeAction else { return }
        let currentDeadline = effectiveNudgeDeadline(for: session, at: now)
        if let delay {
            session.nudgeDeferredUntil = currentDeadline.addingTimeInterval(delay)
        } else if let minimum {
            session.nudgeDeferredUntil = max(
                currentDeadline,
                now.addingTimeInterval(minimum)
            )
        }
        session.lastActivity = now
        phase = .working(session)
        currentWorkDuration = session.workDuration(at: now)
        lastIdleSampleAt = now
        reconcileCompactPresence()
        armNextDeadline()
    }

    private var activeSessionForNudgeAction: Session? {
        switch phase {
        case let .working(session),
             let .nudgePending(session, _),
             let .nudged(session, _, _):
            return session
        case .idle, .resting, .onBreak:
            return nil
        }
    }

    private func isNudgeEligible(_ session: Session, at now: Date) -> Bool {
        guard session.workDuration(at: now) >= workInterval else { return false }
        guard let deferred = session.nudgeDeferredUntil else { return true }
        return now >= deferred
    }

    private func effectiveNudgeDeadline(for session: Session, at now: Date) -> Date {
        let remainingWork = max(0, workInterval - session.workDuration(at: now))
        let workDeadline = now.addingTimeInterval(remainingWork)
        if let deferred = session.nudgeDeferredUntil {
            return max(workDeadline, deferred)
        }
        return workDeadline
    }

    private func closeWorkSegment(_ storedSession: Session, at requestedEnd: Date) -> Session {
        var session = storedSession
        let end = min(max(requestedEnd, session.activeSegmentStart), Date())
        appendSegment(start: session.activeSegmentStart, end: end, kind: .work)
        session.completedWork += max(0, end.timeIntervalSince(session.activeSegmentStart))
        session.activeSegmentStart = end
        session.lastActivity = end
        return session
    }

    private func appendSegment(start: Date, end: Date, kind: FlowSegmentKind) {
        guard end > start else { return }
        rolloverDayIfNeeded(at: end)
        let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: dayAnchor) ?? end
        let clippedStart = max(start, dayAnchor)
        let clippedEnd = min(end, nextMidnight)
        guard clippedEnd > clippedStart else { return }
        daySegments.append(FlowSegment(start: clippedStart, end: clippedEnd, kind: kind))
    }

    private func rolloverDayIfNeeded(at date: Date) {
        let start = Calendar.current.startOfDay(for: date)
        guard start != dayAnchor else { return }
        dayAnchor = start
        if !daySegments.isEmpty {
            daySegments = []
        }
    }

    private func expireAcknowledgementIfNeeded(at now: Date) {
        guard let until = acknowledgementUntil, now >= until else { return }
        acknowledgementUntil = nil
    }

    private func currentMeetingEnd(at now: Date) -> Date? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let predicate = eventStore.predicateForEvents(
            withStart: now.addingTimeInterval(-1),
            end: now.addingTimeInterval(1),
            calendars: nil
        )
        return eventStore.events(matching: predicate)
            .compactMap { event -> Date? in
                guard !event.isAllDay else { return nil }
                guard let start = event.startDate, let end = event.endDate else { return nil }
                guard start <= now, end > now else { return nil }
                let baseID = event.eventIdentifier ?? event.calendarItemIdentifier
                guard !MeetingDismissalStore.shared.isDismissed(
                    MeetingDismissalStore.occurrenceID(baseIdentifier: baseID, start: start)
                ) else { return nil }
                return end
            }
            .max()
    }

    private func readIdleSeconds() -> TimeInterval? {
        guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private func clampedActivity(_ activity: Date, for session: Session, now: Date) -> Date {
        min(now, max(activity, session.activeSegmentStart))
    }

    private func maxDate(_ date: Date, _ optionalDate: Date?) -> Date {
        guard let optionalDate else { return date }
        return max(date, optionalDate)
    }

    private func makeNudgeMessage(elapsed: TimeInterval, repeated: Bool) -> String {
        let duration = Self.conciseDuration(elapsed)
        if repeated {
            return "\(duration) — really, stretch"
        }
        return "\(duration) heads-down — stretch?"
    }

    private static func conciseDuration(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(minutes)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    private func nextRepeekDate(after previous: Date, relativeTo now: Date) -> Date {
        var next = previous
        while next <= now {
            next = next.addingTimeInterval(Self.repeekDuration)
        }
        return next
    }

    private func reconcileCompactPresence() {
        let compactPresent = compactPresentation != nil
        let bannerPresent = nudgeMessage != nil
        guard compactPresent != compactPresence || bannerPresent != bannerPresence else { return }
        let bannerCleared = bannerPresence && !bannerPresent
        compactPresence = compactPresent
        bannerPresence = bannerPresent
        context?.setNeedsCompactRefresh()
        // The nudge banner peeks indefinitely, so the peek must be released here — on Take /
        // Snooze / Skip or a spontaneous break — or the surface would stay pinned open forever.
        // A zero-length peek resolves the hold through the engine's completion path: it is a
        // no-op while the sheet is open (never yanks it shut), and it hands the hold to any
        // other module still supplying a banner.
        if bannerCleared {
            context?.requestPeek(0)
        }
    }

    private func armNextDeadline() {
        cancelDeadline()
        guard isActive, !isSuspended else { return }
        let now = Date()
        var candidates: [Date] = []

        if let acknowledgementUntil, acknowledgementUntil > now {
            candidates.append(acknowledgementUntil)
        }

        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: dayAnchor),
           midnight > now {
            candidates.append(midnight)
        }

        switch phase {
        case .idle, .resting:
            candidates.append(nextSampleDate(cadence: Self.normalSampleCadence, now: now))

        case let .working(session):
            candidates.append(nextSampleDate(cadence: Self.normalSampleCadence, now: now))
            let nudgeDeadline = effectiveNudgeDeadline(for: session, at: now)
            if nudgeDeadline > now {
                candidates.append(nudgeDeadline)
            }

        case let .nudgePending(_, meetingEnd):
            if let meetingEnd, meetingEnd > now {
                candidates.append(meetingEnd)
            } else {
                candidates.append(nextSampleDate(cadence: Self.pendingSampleCadence, now: now))
            }

        case let .nudged(_, nextRepeek, _):
            candidates.append(nextSampleDate(cadence: Self.normalSampleCadence, now: now))
            if nextRepeek > now {
                candidates.append(nextRepeek)
            }

        case let .onBreak(_, until):
            if until > now {
                candidates.append(until)
            }
        }

        guard let deadline = candidates.min() else { return }
        let delay = max(0.05, deadline.timeIntervalSince(now))
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.deadlineTask = nil
            self.evaluate(at: Date())
            self.reconcileCompactPresence()
            self.armNextDeadline()
        }
    }

    private func nextSampleDate(cadence: TimeInterval, now: Date) -> Date {
        guard let lastIdleSampleAt else { return now.addingTimeInterval(cadence) }
        return max(now.addingTimeInterval(0.05), lastIdleSampleAt.addingTimeInterval(cadence))
    }

    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }
}
