import Foundation
import Testing

@testable import SuperVisor

@Suite("Bundle replacement")
@MainActor
struct BundleReplacementMonitorTests {
    private typealias Monitor = BundleReplacementMonitor
    private typealias Activity = BundleReplacementMonitor.Activity

    // MARK: Decisions

    @Test("An agent run, an open window, the open sheet, or a module's hold is something in progress")
    func activity() {
        #expect(!Activity().isBusy)
        #expect(Activity(agentRuns: 1).isBusy)
        #expect(Activity(hasOpenWindow: true).isBusy)
        #expect(Activity(sheetIsOpen: true).isBusy)
        #expect(Activity(holders: ["fileshelf"]).isBusy)
        #expect(
            Activity(agentRuns: 2, hasOpenWindow: true, sheetIsOpen: true, holders: ["media", "calendar"]).waitingOn
                == ["agent run", "open window", "open sheet", "calendar hold", "media hold"]
        )
    }

    @Test("The app relaunches only when its code was replaced, nothing is in progress, and the bundle is whole and its own")
    func steps() {
        let idle = Activity()
        let busy = Activity(agentRuns: 1)

        #expect(Monitor.step(runningCodeIsIntact: true, activity: idle, bundle: .valid) == .nothing)
        #expect(Monitor.step(runningCodeIsIntact: true, activity: busy, bundle: nil) == .nothing)
        // Being busy is judged before the bundle, whatever the bundle is.
        #expect(Monitor.step(runningCodeIsIntact: false, activity: busy, bundle: nil) == .waitUntilIdle)
        #expect(Monitor.step(runningCodeIsIntact: false, activity: busy, bundle: .valid) == .waitUntilIdle)
        #expect(Monitor.step(runningCodeIsIntact: false, activity: busy, bundle: .otherSigner) == .waitUntilIdle)
        #expect(Monitor.step(runningCodeIsIntact: false, activity: idle, bundle: nil) == .waitForBundle)
        #expect(Monitor.step(runningCodeIsIntact: false, activity: idle, bundle: .incomplete) == .waitForBundle)
        #expect(Monitor.step(runningCodeIsIntact: false, activity: idle, bundle: .otherSigner) == .leaveAlone)
        #expect(Monitor.step(runningCodeIsIntact: false, activity: idle, bundle: .valid) == .relaunch)
    }

    @Test("The relaunch command carries the pid, path, and requirement as arguments, outside the script")
    func command() {
        let path = "/Applications/Odd \"Name\"; rm -rf $HOME.app"
        let requirement = #"identifier "com.example.app" and anchor apple generic"#
        let command = Monitor.relaunchCommand(
            pid: 4321,
            bundlePath: path,
            executableName: "Odd",
            requirement: requirement
        )

        #expect(command.executable == "/bin/sh")
        #expect(command.arguments.first == "-c")
        #expect(Array(command.arguments.dropFirst(2)) == ["sh", "4321", path, requirement, "Odd"])
        let script = command.arguments[1]
        #expect(!script.contains("4321"))
        #expect(!script.contains("Odd"))
        #expect(!script.contains("com.example"))
        #expect(script.contains(#"/bin/kill -0 "$1""#))
        #expect(script.contains(#"/usr/bin/codesign --verify --deep -R="$3" "$2""#))
        #expect(script.contains(#"/usr/bin/pgrep -fx "$2/Contents/MacOS/$4""#))
        #expect(script.contains(#"exec /usr/bin/open -n "$2""#))
    }

    // MARK: The wait

    /// What the injected checks answer. The signature checks run off the main actor.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var storedIntact = true
        private var storedStatus = PeerIdentity.BundleStatus.valid
        private var storedLooks = 0

        var intact: Bool {
            get { lock.withLock { storedIntact } }
            set { lock.withLock { storedIntact = newValue } }
        }

        var status: PeerIdentity.BundleStatus {
            get { lock.withLock { storedStatus } }
            set { lock.withLock { storedStatus = newValue } }
        }

        /// How many times the bundle on disk was validated.
        var looks: Int { lock.withLock { storedLooks } }

        func look() -> PeerIdentity.BundleStatus {
            lock.withLock {
                storedLooks += 1
                return storedStatus
            }
        }
    }

    @MainActor
    private final class Counter {
        var activity = Activity()
        var relaunches = 0
    }

    private static let quick = BundleReplacementMonitor.Pacing(
        settle: 0.01,
        bundleRecheck: .milliseconds(20),
        idleRecheck: .milliseconds(20),
        bundleWaitLimit: .seconds(30)
    )

    private func monitor(
        _ world: World,
        _ counter: Counter,
        pacing: BundleReplacementMonitor.Pacing = quick
    ) -> BundleReplacementMonitor {
        BundleReplacementMonitor(
            bundleURL: URL(fileURLWithPath: "/tmp/Stand-In.app"),
            pacing: pacing,
            activity: { counter.activity },
            runningCodeIsIntact: { world.intact },
            bundleStatus: { _ in world.look() },
            relaunch: { counter.relaunches += 1 }
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Long enough for a wait that would act to have acted many times over.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    @Test("A change to the bundle of an intact app relaunches nothing and validates nothing", .timeLimit(.minutes(1)))
    func intactApp() async {
        let (world, counter) = (World(), Counter())
        let monitor = monitor(world, counter)

        monitor.bundleChanged()
        await waitUntil { !monitor.isWaiting }

        #expect(counter.relaunches == 0)
        #expect(world.looks == 0)
    }

    @Test("A replaced app with a whole bundle and nothing in progress relaunches once", .timeLimit(.minutes(1)))
    func replacedAndIdle() async {
        let (world, counter) = (World(), Counter())
        world.intact = false
        let monitor = monitor(world, counter)

        monitor.bundleChanged()
        monitor.bundleChanged()
        await waitUntil { counter.relaunches > 0 && !monitor.isWaiting }

        #expect(counter.relaunches == 1)
    }

    @Test("While something is in progress the bundle is not validated, and the relaunch follows once it ends", .timeLimit(.minutes(1)))
    func busyThenIdle() async {
        let (world, counter) = (World(), Counter())
        world.intact = false
        counter.activity = Activity(holders: ["fileshelf"])
        let monitor = monitor(world, counter)

        monitor.bundleChanged()
        await settle()
        #expect(counter.relaunches == 0)
        #expect(world.looks == 0)

        counter.activity = Activity()
        await waitUntil { counter.relaunches > 0 }
        #expect(counter.relaunches == 1)
    }

    @Test("A bundle still being built is waited for", .timeLimit(.minutes(1)))
    func bundleBecomesWhole() async {
        let (world, counter) = (World(), Counter())
        world.intact = false
        world.status = .incomplete
        let monitor = monitor(world, counter)

        monitor.bundleChanged()
        await waitUntil { world.looks >= 3 }
        #expect(counter.relaunches == 0)

        world.status = .valid
        await waitUntil { counter.relaunches > 0 }
        #expect(counter.relaunches == 1)
    }

    @Test("A bundle that never becomes whole is given up on, and a later change starts the wait again", .timeLimit(.minutes(1)))
    func givesUp() async {
        let (world, counter) = (World(), Counter())
        world.intact = false
        world.status = .incomplete
        var pacing = Self.quick
        pacing.bundleWaitLimit = .milliseconds(100)
        let monitor = monitor(world, counter, pacing: pacing)

        monitor.bundleChanged()
        await waitUntil { !monitor.isWaiting }
        #expect(!monitor.isWaiting)
        #expect(world.looks >= 1)
        #expect(counter.relaunches == 0)

        world.status = .valid
        monitor.bundleChanged()
        await waitUntil { counter.relaunches > 0 }
        #expect(counter.relaunches == 1)
    }

    @Test("A bundle signed as another app is left alone at once", .timeLimit(.minutes(1)))
    func otherSigner() async {
        let (world, counter) = (World(), Counter())
        world.intact = false
        world.status = .otherSigner
        let monitor = monitor(world, counter)

        monitor.bundleChanged()
        await waitUntil { !monitor.isWaiting }

        #expect(!monitor.isWaiting)
        #expect(counter.relaunches == 0)
        #expect(world.looks == 1)
    }

    @Test("A stopped monitor relaunches nothing, even when the bundle then becomes whole", .timeLimit(.minutes(1)))
    func stopped() async {
        let (world, counter) = (World(), Counter())
        world.intact = false
        world.status = .incomplete
        let monitor = monitor(world, counter)

        monitor.bundleChanged()
        await waitUntil { world.looks >= 2 }
        monitor.stop()
        world.status = .valid
        await settle()

        #expect(counter.relaunches == 0)
    }

    // MARK: The bundle on disk

    @Test("A folder that is no signed bundle is incomplete, and another app's bundle is another signer's")
    func bundleStatus() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv-bundle-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(PeerIdentity.bundleStatus(at: folder) == .incomplete)
        #expect(PeerIdentity.bundleStatus(at: folder.appendingPathComponent("Missing.app")) == .incomplete)
        #expect(
            PeerIdentity.bundleStatus(at: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
                == .otherSigner
        )
    }

    // MARK: Holds

    @Test("A hold stands while any owner holds it")
    func holds() {
        let holds = RelaunchHolds()
        #expect(!holds.isHeld)
        holds.set(true, for: "a")
        holds.set(true, for: "a")
        holds.set(true, for: "b")
        holds.set(false, for: "a")
        #expect(holds.isHeld)
        holds.set(false, for: "b")
        holds.set(false, for: "b")
        #expect(!holds.isHeld)
    }
}
