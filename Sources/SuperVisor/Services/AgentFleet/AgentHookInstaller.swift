import Foundation

/// Whether the session hooks SwarmVisor reads are wired into Claude Code's configuration.
enum AgentHookInstallState: Equatable, Sendable {
    /// No hook entry references the app's script.
    case absent
    /// Wired, but the installed script differs from the copy this build ships.
    case outdated
    case installed

    var isWired: Bool { self != .absent }
}

/// Installs, updates, and removes the Claude Code hooks that feed SwarmVisor.
///
/// SwarmVisor derives busy/idle/waiting state from the session registry on its own, so hooks
/// supply only what the registry omits: the session's tty (which every Jump depends on), the
/// text of a finished turn, and the reason a turn failed.
///
/// The settings transforms are pure functions over the decoded JSON object. Writing another
/// application's configuration file has to be conservative — unrelated keys, unrelated hook
/// events, and other tools' entries for the same events all survive a round trip, and the
/// original file is copied aside once before the first modification.
enum AgentHookInstaller {
    /// Events whose payloads carry something the session registry does not.
    ///
    /// Per-tool events are absent by design: they would spawn a process per tool call to report
    /// state the registry already publishes. No event here blocks the CLI — notably
    /// `PermissionRequest`, whose only possible answer is the pass-through decision that not
    /// wiring it at all produces, at no latency and with no risk of stalling a prompt.
    static let hookedEvents = [
        "UserPromptSubmit",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionStart",
        "SessionEnd",
    ]

    static let scriptName = "supervisor-agent-hook.py"

    /// Hooks belonging to ClaudeIsland, a separate app that used to provide this signal. Its
    /// entries are removed alongside an install so the two never both feed the socket.
    static let legacyScriptName = "claude-island-state.py"

    static let hookCommand = "python3 \"$HOME/.claude/hooks/\(scriptName)\""

    // MARK: - Locations

    static var claudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var settingsURL: URL {
        claudeDirectory.appendingPathComponent("settings.json", isDirectory: false)
    }

    static var installedScriptURL: URL {
        claudeDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(scriptName, isDirectory: false)
    }

    static var bundledScriptURL: URL? {
        Bundle.main.url(forResource: "supervisor-agent-hook", withExtension: "py")
    }

    /// Preserves the configuration as it stood before SuperVisor first touched it. Written only
    /// when absent, so a later install cannot overwrite the pristine copy with a patched one.
    static var backupURL: URL {
        claudeDirectory.appendingPathComponent(
            "settings.json.pre-supervisor.bak",
            isDirectory: false
        )
    }

    // MARK: - State

    static func currentState() -> AgentHookInstallState {
        guard let settings = readSettings(),
              containsHookCommand(settings, matching: scriptName)
        else { return .absent }

        guard let bundled = bundledScriptURL,
              let bundledContents = try? Data(contentsOf: bundled),
              let installedContents = try? Data(contentsOf: installedScriptURL),
              bundledContents == installedContents
        else { return .outdated }

        return .installed
    }

    // MARK: - Operations

    /// Copies the shipped script into place and rewrites the hook entries to match this build.
    static func install() throws {
        guard let bundled = bundledScriptURL else {
            throw AgentHookInstallerError.scriptMissingFromBundle
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: installedScriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let contents = try Data(contentsOf: bundled)
        try contents.write(to: installedScriptURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedScriptURL.path
        )

        try updateSettings { settings in
            applyingInstall(to: settings)
        }
        removeLegacyArtifacts()

        AppLog.notice(.swarm, "session hooks installed for \(hookedEvents.count) events")
    }

    /// Unwires the hooks and deletes the installed script. Leaves every unrelated entry, and
    /// the backup, in place.
    static func uninstall() throws {
        try updateSettings { settings in
            applyingUninstall(from: settings)
        }
        try? FileManager.default.removeItem(at: installedScriptURL)
        AppLog.notice(.swarm, "session hooks removed")
    }

    // MARK: - Settings transforms

    /// Replaces any existing entries for this app — and any left by ClaudeIsland — with one
    /// entry per hooked event. Re-running produces an identical object.
    static func applyingInstall(to settings: [String: Any]) -> [String: Any] {
        var hooks = strippingManagedEntries(from: hooksObject(in: settings))

        for event in hookedEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append([
                "hooks": [
                    ["type": "command", "command": hookCommand] as [String: Any]
                ] as [Any]
            ])
            hooks[event] = groups
        }

        var updated = settings
        updated["hooks"] = hooks
        return updated
    }

    static func applyingUninstall(from settings: [String: Any]) -> [String: Any] {
        let hooks = strippingManagedEntries(from: hooksObject(in: settings))

        var updated = settings
        if hooks.isEmpty {
            updated.removeValue(forKey: "hooks")
        } else {
            updated["hooks"] = hooks
        }
        return updated
    }

    /// Drops every command entry referencing this app's script or ClaudeIsland's, then prunes
    /// the groups and events left empty. Entries belonging to anything else are untouched, so
    /// a user's own `Stop` hook survives an install and an uninstall alike.
    private static func strippingManagedEntries(
        from hooks: [String: Any]
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }

            var keptGroups: [[String: Any]] = []
            for group in groups {
                guard let commands = group["hooks"] as? [[String: Any]] else {
                    keptGroups.append(group)
                    continue
                }
                let keptCommands = commands.filter { !isManaged($0) }
                if keptCommands.isEmpty { continue }

                var keptGroup = group
                keptGroup["hooks"] = keptCommands
                keptGroups.append(keptGroup)
            }

            if !keptGroups.isEmpty {
                result[event] = keptGroups
            }
        }

        return result
    }

    private static func isManaged(_ command: [String: Any]) -> Bool {
        guard let text = command["command"] as? String else { return false }
        return text.contains(scriptName) || text.contains(legacyScriptName)
    }

    private static func containsHookCommand(
        _ settings: [String: Any],
        matching name: String
    ) -> Bool {
        for (_, value) in hooksObject(in: settings) {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                guard let commands = group["hooks"] as? [[String: Any]] else { continue }
                for command in commands
                where (command["command"] as? String)?.contains(name) == true {
                    return true
                }
            }
        }
        return false
    }

    private static func hooksObject(in settings: [String: Any]) -> [String: Any] {
        settings["hooks"] as? [String: Any] ?? [:]
    }

    // MARK: - Persistence

    static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any]
        else { return nil }
        return settings
    }

    private static func updateSettings(
        _ transform: ([String: Any]) -> [String: Any]
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: claudeDirectory,
            withIntermediateDirectories: true
        )

        let existing = readSettings()
        if existing != nil, !fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.copyItem(at: settingsURL, to: backupURL)
        }

        let updated = transform(existing ?? [:])
        let data = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Deletes ClaudeIsland's hook script once nothing references it. Its settings entries are
    /// already gone by this point, so no session can invoke the script and find it missing.
    private static func removeLegacyArtifacts() {
        let legacyScript = claudeDirectory
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent(legacyScriptName, isDirectory: false)
        if FileManager.default.fileExists(atPath: legacyScript.path) {
            try? FileManager.default.removeItem(at: legacyScript)
            AppLog.notice(.swarm, "removed legacy hook script")
        }
    }
}

enum AgentHookInstallerError: Error, LocalizedError {
    case scriptMissingFromBundle

    var errorDescription: String? {
        switch self {
        case .scriptMissingFromBundle:
            "The hook script is missing from the app bundle. Rebuild with make-app.sh."
        }
    }
}
