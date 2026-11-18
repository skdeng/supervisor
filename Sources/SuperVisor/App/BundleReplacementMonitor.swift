import AppKit
import Foundation

/// Relaunches the app once its bundle on disk is no longer the code it is running.
///
/// A build or an update that replaces the bundle under a running app leaves the process on the
/// old code. Whatever checks the process against its bundle then refuses it: the bridge helper
/// is started from the bundle on disk and will not talk to an app it cannot verify, so every
/// agent run loses its tools while finishing normally. The remedy is a relaunch, and nobody is
/// told to make one.
///
/// The monitor watches the bundle. When something in it changes and the running code is found
/// not to be the code on disk, it waits for two things, in this order, and then relaunches:
/// - **nothing is in progress** (`Activity`): no agent run, no ordinary window open, the sheet
///   closed, and no module holding something a relaunch would lose (`RelaunchHolds`);
/// - **the bundle on disk is whole**: it validates, nested code included, against the
///   requirement this app was signed to. A build replaces the executable long before it signs
///   the bundle, so an unfinished one is waited for; one signed by anyone else is left alone.
///
/// It polls only between a replacement and the relaunch. While the bundle is intact it holds
/// one file-system event stream and does nothing else.
@MainActor
final class BundleReplacementMonitor {
    /// What to do about the bundle, judged afresh each time it is looked at.
    enum Step: Equatable {
        /// The running code is the code on disk.
        case nothing
        /// Something is in progress. The bundle is not looked at until that ends.
        case waitUntilIdle
        /// The bundle on disk is not whole yet.
        case waitForBundle
        /// The bundle on disk is whole and signed as something other than this app.
        case leaveAlone
        case relaunch
    }

    /// What is in progress in the app.
    struct Activity: Equatable {
        var agentRuns = 0
        var hasOpenWindow = false
        var sheetIsOpen = false
        /// The modules holding something a relaunch would lose (`RelaunchHolds`).
        var holders: Set<String> = []

        var isBusy: Bool { !waitingOn.isEmpty }

        /// What is in progress, by name, for the log.
        var waitingOn: [String] {
            var names: [String] = []
            if agentRuns > 0 { names.append("agent run") }
            if hasOpenWindow { names.append("open window") }
            if sheetIsOpen { names.append("open sheet") }
            return names + holders.sorted().map { "\($0) hold" }
        }
    }

    /// `bundle` is nil while the bundle has not been looked at, which it is not while busy.
    static func step(
        runningCodeIsIntact: Bool,
        activity: Activity,
        bundle: PeerIdentity.BundleStatus?
    ) -> Step {
        if runningCodeIsIntact { return .nothing }
        if activity.isBusy { return .waitUntilIdle }
        switch bundle {
        case nil, .incomplete?: return .waitForBundle
        case .otherSigner?: return .leaveAlone
        case .valid?: return .relaunch
        }
    }

    /// The command that reopens the bundle once this process is gone, as a shell script and its
    /// arguments. The pid, the path, and the requirement are passed as arguments, never written
    /// into the script.
    ///
    /// The script waits up to a minute for `pid` to exit and stops if it has not, so an app
    /// that declined to quit is left running. It then waits, up to ten minutes, for the bundle
    /// to verify against the requirement: another build may have begun since the app checked,
    /// and opening a half-built bundle would start a copy signed as nothing in particular. It
    /// opens the bundle only when no copy of the app is already running, since whoever built
    /// it may have started one.
    static func relaunchCommand(
        pid: pid_t,
        bundlePath: String,
        executableName: String,
        requirement: String
    ) -> (executable: String, arguments: [String]) {
        let script = #"""
            n=0
            while /bin/kill -0 "$1" 2>/dev/null; do
              [ "$n" -ge 300 ] && exit 0
              /bin/sleep 0.2
              n=$((n+1))
            done
            n=0
            until /usr/bin/codesign --verify --deep -R="$3" "$2" 2>/dev/null; do
              [ "$n" -ge 300 ] && break
              /bin/sleep 2
              n=$((n+1))
            done
            /bin/sleep 0.5
            /usr/bin/pgrep -fx "$2/Contents/MacOS/$4" >/dev/null && exit 0
            exec /usr/bin/open -n "$2"
            """#
        return ("/bin/sh", ["-c", script, "sh", String(pid), bundlePath, requirement, executableName])
    }

    /// How the monitor paces itself. The defaults are the app's; a test passes short ones.
    struct Pacing {
        /// How long a look waits after the bundle last changed: a build writes it many times.
        var settle: TimeInterval = 3
        /// How often the bundle is looked at again while it is not yet whole.
        var bundleRecheck: Duration = .seconds(5)
        /// How often the app is looked at again while something is in progress.
        var idleRecheck: Duration = .seconds(15)
        /// How long after the bundle last changed the monitor goes on waiting for it to become
        /// whole. A later change starts the wait again.
        var bundleWaitLimit: Duration = .seconds(600)
    }

    private let bundleURL: URL
    private let pacing: Pacing
    private let activity: @MainActor () -> Activity
    private let runningCodeIsIntact: @Sendable () -> Bool
    private let bundleStatus: @Sendable (URL) -> PeerIdentity.BundleStatus
    private let relaunch: @MainActor () -> Void
    private var watcher: DirectoryTreeWatcher?
    private var pending: Task<Void, Never>?
    /// Counts the waits started, so a wait that ends after `stop` clears only itself.
    private var waits = 0
    private var lastChange = ContinuousClock.now

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        pacing: Pacing = Pacing(),
        activity: @escaping @MainActor () -> Activity,
        runningCodeIsIntact: @escaping @Sendable () -> Bool = PeerIdentity.runningCodeIsIntact,
        bundleStatus: @escaping @Sendable (URL) -> PeerIdentity.BundleStatus = PeerIdentity.bundleStatus(at:),
        relaunch: (@MainActor () -> Void)? = nil
    ) {
        self.bundleURL = bundleURL
        self.pacing = pacing
        self.activity = activity
        self.runningCodeIsIntact = runningCodeIsIntact
        self.bundleStatus = bundleStatus
        self.relaunch = relaunch ?? { Self.relaunchApp(at: bundleURL) }
    }

    /// Starts watching the bundle. Does nothing for a process that is not running from an app
    /// bundle.
    ///
    /// The watch is a file-system event stream on the bundle's path. A build removes the whole
    /// bundle and assembles it again; a watch on the executable's descriptor would be left on
    /// the removed file, while a stream follows the path.
    func start() {
        guard watcher == nil, bundleURL.pathExtension == "app" else { return }
        // The requirement is read from the code as launched, before anything replaces it.
        PeerIdentity.resolveOwnRequirement()
        let watcher = DirectoryTreeWatcher(url: bundleURL, debounce: pacing.settle) { [weak self] in
            Task { @MainActor in self?.bundleChanged() }
        }
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pending?.cancel()
        pending = nil
        waits += 1
    }

    /// Whether a wait is under way: the bundle changed and what to do about it is not settled.
    var isWaiting: Bool { pending != nil }

    /// One wait runs at a time. A change that arrives during it is seen by its next look and
    /// gives the bundle its full time to become whole again.
    func bundleChanged() {
        lastChange = .now
        guard pending == nil else { return }
        waits += 1
        let wait = waits
        pending = Task { [weak self] in
            await self?.followThrough()
            if self?.waits == wait { self?.pending = nil }
        }
    }

    private func followThrough() async {
        var saidWaitingOn: String?
        while !Task.isCancelled {
            let (intactCheck, statusCheck, url) = (runningCodeIsIntact, bundleStatus, bundleURL)
            let intact = await Task.detached(priority: .utility) { intactCheck() }.value
            guard !Task.isCancelled else { return }

            // The bundle is validated only once the app is idle: nothing but the app going idle
            // can end a busy wait, and validating reads every file the bundle holds.
            var status: PeerIdentity.BundleStatus?
            if !intact, !activity().isBusy {
                status = await Task.detached(priority: .utility) { statusCheck(url) }.value
                guard !Task.isCancelled else { return }
            }

            // Read again: the checks above took time.
            switch Self.step(runningCodeIsIntact: intact, activity: activity(), bundle: status) {
            case .nothing:
                return
            case .waitUntilIdle:
                let waitingOn = activity().waitingOn.joined(separator: ", ")
                if waitingOn != saidWaitingOn {
                    AppLog.notice(.engine, "the bundle on disk was replaced; relaunching after: \(waitingOn)")
                    saidWaitingOn = waitingOn
                }
                try? await Task.sleep(for: pacing.idleRecheck)
            case .waitForBundle:
                guard ContinuousClock.now - lastChange < pacing.bundleWaitLimit else {
                    AppLog.error(.engine, "the bundle on disk was replaced and never became whole; not relaunching")
                    return
                }
                try? await Task.sleep(for: pacing.bundleRecheck)
            case .leaveAlone:
                AppLog.notice(.engine, "the bundle on disk is signed as another app; not relaunching")
                return
            case .relaunch:
                AppLog.notice(.engine, "the bundle on disk was replaced; relaunching")
                relaunch()
                return
            }
        }
    }

    /// Starts the command that reopens the bundle and ends this process. When the command
    /// cannot be started the app keeps running: an out-of-date app serves better than none.
    private static func relaunchApp(at bundleURL: URL) {
        guard let requirement = PeerIdentity.ownRequirementText,
              let executableName = Bundle(url: bundleURL)?.executableURL?.lastPathComponent
        else {
            AppLog.error(.engine, "the relaunch could not be started")
            return
        }
        let command = relaunchCommand(
            pid: ProcessInfo.processInfo.processIdentifier,
            bundlePath: bundleURL.path,
            executableName: executableName,
            requirement: requirement
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ChildEnvironment.minimal()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.error(.engine, "the relaunch could not be started")
            return
        }
        NSApp.terminate(nil)
    }
}
