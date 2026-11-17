import AppKit

/// Process entry point. Wires an `NSApplication` to the `AppDelegate` and runs the loop.
/// The app is a menu-bar agent (`.accessory` policy set in the delegate) with no main
/// window or storyboard, so it is driven entirely from code.
@main
enum SuperVisorMain {
    static func main() {
        // The disclaimed launcher is this executable with a flag. It replaces itself with the
        // program it is given, so it runs before anything else.
        if DisclaimedExec.isRequested(in: CommandLine.arguments) {
            DisclaimedExec.run(arguments: CommandLine.arguments)
        }

        // The tool bridge's helper process is this executable with a flag. It serves stdio and
        // exits without ever starting the app.
        if AgentBridgeHelper.isRequested(in: CommandLine.arguments) {
            AgentBridgeHelper.run()
        }

        // A launch that names a self-check runs that check and exits; the menu-bar app never
        // starts in it.
        if let check = SelfCheck.requested(in: CommandLine.arguments) {
            SelfCheck.run(name: check.name, report: check.report)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
