import AppKit

/// Process entry point. Wires an `NSApplication` to the `AppDelegate` and runs the loop.
/// The app is a menu-bar agent (`.accessory` policy set in the delegate) with no main
/// window or storyboard, so it is driven entirely from code.
@main
enum SuperVisorMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
