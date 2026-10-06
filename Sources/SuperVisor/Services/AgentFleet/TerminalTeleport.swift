import AppKit
import Carbon
import Foundation

/// Carries the user to a session: the iTerm2 tab whose session owns a validated terminal device,
/// or, for a session hosted anywhere else (the Claude desktop app, an editor, another terminal),
/// that host app brought to the front.
@MainActor
final class TerminalTeleport {
    private static let scriptSource = """
    on teleport(targetTTY)
        tell application "iTerm2"
            repeat with targetWindow in windows
                repeat with targetTab in tabs of targetWindow
                    repeat with targetSession in sessions of targetTab
                        if tty of targetSession is targetTTY then
                            select targetTab
                            select targetWindow
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
    end teleport
    """

    private lazy var script: NSAppleScript? = {
        guard let script = NSAppleScript(source: Self.scriptSource) else {
            AppLog.error(.swarm, "terminal teleport AppleScript error: script creation failed")
            return nil
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            AppLog.error(
                .swarm,
                "terminal teleport AppleScript error: \(error?.description ?? "unknown error")"
            )
            return nil
        }
        return script
    }()

    func teleport(to target: JumpTarget) {
        if let tty = target.tty, target.selectsITermTab, teleportToITermTab(tty) {
            return
        }
        // The tab lookup can miss (a tty iTerm2 no longer owns); the host app is still the
        // nearest place to put the user.
        if let host = target.host {
            activate(host)
        }
    }

    /// Brings the host forward through LaunchServices. `NSRunningApplication.activate` is
    /// subject to cooperative activation, which an accessory app that never becomes active
    /// cannot satisfy; opening the already-running bundle is the request macOS honors.
    private func activate(_ host: SessionHost) {
        guard let app = NSRunningApplication(processIdentifier: host.processIdentifier),
              !app.isTerminated
        else {
            AppLog.error(.swarm, "session host \(host.name) is no longer running")
            return
        }
        guard let bundleURL = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                AppLog.error(.swarm, "session host activation failed: \(error.localizedDescription)")
            }
        }
    }

    private func teleportToITermTab(_ tty: String) -> Bool {
        guard AgentFleetCenter.isValidTTY(tty) else { return false }
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: SessionHost.iTermBundleIdentifier
        ).isEmpty else {
            AppLog.error(.swarm, "terminal teleport found no matching tab for \(tty)")
            return false
        }
        guard let script else { return false }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "teleport"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )

        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: tty), at: 1)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            AppLog.error(
                .swarm,
                "terminal teleport AppleScript error for \(tty): \(error.description)"
            )
            return false
        }
        guard result.booleanValue else {
            AppLog.error(.swarm, "terminal teleport found no matching tab for \(tty)")
            return false
        }
        return true
    }
}
