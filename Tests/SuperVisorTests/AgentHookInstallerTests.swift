import Foundation
import Testing

@testable import SuperVisor

/// The install transform writes into a configuration file owned by another application, so the
/// invariants under test are what it must never disturb as much as what it must add.
@Suite("Agent hook settings transforms")
struct AgentHookInstallerTests {
    private let ourCommand = "python3 \"$HOME/.claude/hooks/supervisor-agent-hook.py\""
    private let legacyCommand = "python3 ~/.claude/hooks/claude-island-state.py"

    private func commands(in settings: [String: Any], event: String) -> [String] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    @Test("Every hooked event gains exactly one command")
    func installWiresEveryEvent() {
        let result = AgentHookInstaller.applyingInstall(to: [:])

        for event in AgentHookInstaller.hookedEvents {
            #expect(commands(in: result, event: event) == [ourCommand])
        }
    }

    @Test("Per-tool and blocking events stay unwired")
    func installSkipsHighFrequencyAndBlockingEvents() {
        let result = AgentHookInstaller.applyingInstall(to: [:])
        let hooks = result["hooks"] as? [String: Any] ?? [:]

        for event in ["PreToolUse", "PostToolUse", "PermissionRequest"] {
            #expect(hooks[event] == nil)
        }
    }

    @Test("Installing twice produces the same object")
    func installIsIdempotent() {
        let once = AgentHookInstaller.applyingInstall(to: [:])
        let twice = AgentHookInstaller.applyingInstall(to: once)

        for event in AgentHookInstaller.hookedEvents {
            #expect(commands(in: twice, event: event) == commands(in: once, event: event))
        }
    }

    @Test("Installing removes ClaudeIsland's entries, including events we do not wire")
    func installEvictsLegacyEntries() {
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": legacyCommand]]]],
                "PreToolUse": [
                    ["matcher": "*", "hooks": [["type": "command", "command": legacyCommand]]]
                ],
            ]
        ]

        let result = AgentHookInstaller.applyingInstall(to: existing)

        #expect(commands(in: result, event: "Stop") == [ourCommand])
        let hooks = result["hooks"] as? [String: Any] ?? [:]
        #expect(hooks["PreToolUse"] == nil, "an event left with no commands is pruned")
    }

    @Test("A third party's hook on the same event survives install and uninstall")
    func unrelatedHooksArePreserved() {
        let theirs = "python3 ~/.claude/hooks/somebody-else.py"
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": theirs]]]]
            ]
        ]

        let installed = AgentHookInstaller.applyingInstall(to: existing)
        #expect(commands(in: installed, event: "Stop").contains(theirs))
        #expect(commands(in: installed, event: "Stop").contains(ourCommand))

        let removed = AgentHookInstaller.applyingUninstall(from: installed)
        #expect(commands(in: removed, event: "Stop") == [theirs])
    }

    @Test("Unrelated top-level settings keys are untouched")
    func unrelatedKeysArePreserved() {
        let existing: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash(ls:*)"]],
        ]

        let result = AgentHookInstaller.applyingInstall(to: existing)

        #expect(result["model"] as? String == "opus")
        let permissions = result["permissions"] as? [String: Any]
        #expect(permissions?["allow"] as? [String] == ["Bash(ls:*)"])
    }

    @Test("Uninstalling drops the hooks key when nothing else remains")
    func uninstallRemovesEmptyHooksObject() {
        let installed = AgentHookInstaller.applyingInstall(to: ["model": "opus"])
        let removed = AgentHookInstaller.applyingUninstall(from: installed)

        #expect(removed["hooks"] == nil)
        #expect(removed["model"] as? String == "opus")
    }

    @Test("Uninstalling a configuration that was never installed changes nothing")
    func uninstallIsSafeWhenAbsent() {
        let existing: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "command", "command": "echo hi"]]]]]
        ]

        let result = AgentHookInstaller.applyingUninstall(from: existing)

        #expect(commands(in: result, event: "Stop") == ["echo hi"])
    }

    @Test("A hooks object with an unexpected shape is passed through untouched")
    func malformedHooksSurvive() {
        let existing: [String: Any] = ["hooks": ["Stop": "not-an-array"]]

        let result = AgentHookInstaller.applyingUninstall(from: existing)

        let hooks = result["hooks"] as? [String: Any] ?? [:]
        #expect(hooks["Stop"] as? String == "not-an-array")
    }
}
