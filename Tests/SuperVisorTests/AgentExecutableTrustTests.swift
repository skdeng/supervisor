import Foundation
import Security
import Testing

@testable import SuperVisor

@Suite("Agent executable trust")
struct AgentExecutableTrustTests {
    private static let installedCLI = AgentTaskService.resolveExecutable()

    @Test("The requirement is valid code-signing syntax")
    func requirementCompiles() {
        var compiled: SecRequirement?
        #expect(SecRequirementCreateWithString(
            AgentExecutableTrust.requirement as CFString, [], &compiled
        ) == errSecSuccess)
        #expect(compiled != nil)
    }

    @Test("A system program signed by Apple is not the agent CLI, as a file or as a running process")
    func systemProgramIsNotTrusted() throws {
        #expect(!AgentExecutableTrust.isTrusted(executable: URL(fileURLWithPath: "/bin/sleep")))
        #expect(!AgentExecutableTrust.isTrusted(executable: URL(fileURLWithPath: "/usr/bin/true")))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.stopAndReap() }
        #expect(!AgentExecutableTrust.isTrusted(process: child.processIdentifier))
    }

    @Test("This process, unrelated pids, and a missing file are not trusted")
    func otherSubjectsAreNotTrusted() {
        #expect(!AgentExecutableTrust.isTrusted(process: getpid()))
        for pid: pid_t in [-1, 0, 1, .max] {
            #expect(!AgentExecutableTrust.isTrusted(process: pid), "\(pid)")
        }
        #expect(!AgentExecutableTrust.isTrusted(executable: URL(fileURLWithPath: "/nonexistent/claude")))
        #expect(!AgentExecutableTrust.isTrusted(executable: URL(fileURLWithPath: "/etc/hosts")))
    }

    @Test("The installed agent CLI that a run would start satisfies the requirement",
          .enabled(if: installedCLI != nil, "No agent CLI is installed where AgentTaskService looks for one."))
    func installedCLIIsTrusted() throws {
        let installed = try #require(Self.installedCLI)
        #expect(AgentExecutableTrust.isTrusted(executable: installed))
    }
}
