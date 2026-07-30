import AppKit
import Carbon
import Foundation

/// Focuses the iTerm2 tab whose session owns a validated terminal device.
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

    func teleport(toTTY tty: String) {
        guard AgentFleetCenter.isValidTTY(tty) else { return }
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.googlecode.iterm2"
        ).isEmpty else {
            AppLog.error(.swarm, "terminal teleport found no matching tab for \(tty)")
            return
        }
        guard let script else { return }

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
        } else if result.booleanValue != true {
            AppLog.error(.swarm, "terminal teleport found no matching tab for \(tty)")
        }
    }
}
