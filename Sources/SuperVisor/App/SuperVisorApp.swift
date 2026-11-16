import AppKit

/// Process entry point. Wires an `NSApplication` to the `AppDelegate` and runs the loop.
/// The app is a menu-bar agent (`.accessory` policy set in the delegate) with no main
/// window or storyboard, so it is driven entirely from code.
@main
enum SuperVisorMain {
    static func main() {
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
