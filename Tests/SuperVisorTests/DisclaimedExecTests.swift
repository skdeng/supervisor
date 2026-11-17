import Darwin
import Foundation
import Testing

@testable import SuperVisor

/// The launcher mode that replaces `SuperVisor` with another program. The program parsing runs
/// in this process; the exec itself runs in the built executable, which replaces its own process
/// and so cannot be called from a test.
@Suite("Disclaimed exec")
struct DisclaimedExecTests {
    private struct Outcome {
        let standardOutput: String
        let standardError: String
        let status: Int32
        let exitedNormally: Bool
        let timedOut: Bool
    }

    /// Runs the built executable with `arguments`, bounded, and collects its output.
    private func launch(_ arguments: [String]) throws -> Outcome {
        let executable = try #require(BuiltExecutable.url)
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = BuiltExecutable.frameworkEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { process.stopAndReap() }

        let finished = process.waitForExit(timeout: 20)
        if !finished { process.stopAndReap() }
        let standardOutput = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        let standardError = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
        return Outcome(
            standardOutput: String(decoding: standardOutput, as: UTF8.self),
            standardError: String(decoding: standardError, as: UTF8.self),
            status: process.terminationStatus,
            exitedNormally: process.terminationReason == .exit,
            timedOut: !finished
        )
    }

    // MARK: Argument parsing

    @Test("The program and its arguments follow the first flag")
    func parsing() {
        #expect(DisclaimedExec.isRequested(in: ["SuperVisor", "--exec-disclaimed", "/bin/echo"]))
        #expect(!DisclaimedExec.isRequested(in: ["SuperVisor", "--agent-bridge"]))
        #expect(!DisclaimedExec.isRequested(in: ["--exec-disclaimed"]))
        #expect(!DisclaimedExec.isRequested(in: []))

        let command = DisclaimedExec.command(from: [
            "SuperVisor", "--exec-disclaimed", "/bin/echo", "a b", "--exec-disclaimed", "",
        ])
        #expect(command?.program == "/bin/echo")
        #expect(command?.arguments == ["/bin/echo", "a b", "--exec-disclaimed", ""])

        #expect(DisclaimedExec.command(from: ["SuperVisor", "--exec-disclaimed", "/bin/echo"])?.arguments == ["/bin/echo"])
        #expect(DisclaimedExec.command(from: ["SuperVisor"]) == nil)
        #expect(DisclaimedExec.command(from: ["SuperVisor", "--exec-disclaimed"]) == nil)
        #expect(DisclaimedExec.command(from: ["SuperVisor", "--exec-disclaimed", "echo"]) == nil)
        #expect(DisclaimedExec.command(from: ["SuperVisor", "--exec-disclaimed", ""]) == nil)
    }

    // MARK: In the built executable

    @Test("The target runs in place of the launcher with its arguments, and its output and status come back",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func runsTarget() throws {
        let outcome = try launch(["--exec-disclaimed", "/bin/echo", "hi"])
        #expect(!outcome.timedOut)
        #expect(outcome.standardOutput == "hi\n")
        #expect(outcome.standardError == "")
        #expect(outcome.exitedNormally)
        #expect(outcome.status == 0)

        let failing = try launch(["--exec-disclaimed", "/usr/bin/false"])
        #expect(failing.exitedNormally)
        #expect(failing.status == 1)
    }

    @Test("A target that does not exist ends with status 127 and one fixed line on stderr",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func missingTarget() throws {
        let outcome = try launch(["--exec-disclaimed", "/nonexistent/program", "argument"])
        #expect(!outcome.timedOut)
        #expect(outcome.status == 127)
        #expect(outcome.exitedNormally)
        #expect(outcome.standardOutput == "")
        #expect(outcome.standardError == DisclaimedExec.failureLine)
        #expect(!outcome.standardError.contains("nonexistent"))
    }

    @Test("A target that is not an absolute path, or is absent, is refused the same way",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func unusableTargets() throws {
        for arguments in [
            ["--exec-disclaimed"],
            ["--exec-disclaimed", "echo", "hi"],
            ["--exec-disclaimed", "./echo"],
            ["--exec-disclaimed", ""],
        ] {
            let outcome = try launch(arguments)
            #expect(outcome.status == 127, "\(arguments)")
            #expect(outcome.standardOutput == "", "\(arguments)")
            #expect(outcome.standardError == DisclaimedExec.failureLine, "\(arguments)")
        }
    }

    @Test("Arguments reach the target as given: spaces, quotes, shell syntax, empty strings, and a second flag",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func argumentsSurvive() throws {
        // printf reuses its format for every argument, so each one comes back in brackets.
        let outcome = try launch([
            "--exec-disclaimed", "/usr/bin/printf", "[%s]",
            "two  words", " padded ", "quote\"s and 'single'", "$HOME `date`", "", "--exec-disclaimed",
            "tab\there",
        ])
        #expect(outcome.status == 0)
        #expect(outcome.standardOutput
            == "[two  words][ padded ][quote\"s and 'single'][$HOME `date`][][--exec-disclaimed][tab\there]")
    }

    @Test("The target's own argument zero is its path",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func argumentZero() throws {
        let outcome = try launch(["--exec-disclaimed", "/bin/sh", "-c", #"printf '%s' "$0""#])
        #expect(outcome.standardOutput == "/bin/sh")
    }

    @Test("The target inherits the launcher's environment",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func environmentIsInherited() throws {
        let executable = try #require(BuiltExecutable.url)
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--exec-disclaimed", "/usr/bin/env"]
        process.environment = ["SUPERVISOR_EXEC_PROBE": "carried"]
            .merging(BuiltExecutable.frameworkEnvironment) { current, _ in current }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.stopAndReap() }
        #expect(process.waitForExit(timeout: 20))
        let text = String(decoding: (try? output.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        #expect(text.split(separator: "\n").contains("SUPERVISOR_EXEC_PROBE=carried"))
    }

    @Test("Only the three standard streams reach the target; every other descriptor is closed",
          .enabled(if: BuiltExecutable.url != nil, BuiltExecutable.skipReason))
    func descriptorsAreClosed() throws {
        let executable = try #require(BuiltExecutable.url)
        var plant: [Int32] = [-1, -1]
        var capture: [Int32] = [-1, -1]
        try #require(pipe(&plant) == 0 && pipe(&capture) == 0)
        // Each descriptor is closed once: a number closed twice may by then belong to a test
        // running in parallel.
        defer { [plant[0], capture[0]].forEach { close($0) } }

        // The launcher is started with the write end of `plant` open as descriptor 7, not marked
        // close-on-exec, so only the launcher's own flags can keep it from the target.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, plant[1], 7)
        posix_spawn_file_actions_adddup2(&fileActions, capture[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&fileActions, plant[0])
        posix_spawn_file_actions_addclose(&fileActions, capture[0])

        let script = #"if (echo leak >&7) 2>/dev/null; then echo leaked; else echo closed; fi"#
        let arguments = [executable.path, "--exec-disclaimed", "/bin/sh", "-c", script]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let environment = BuiltExecutable.frameworkEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.compactMap { $0 }.forEach { free($0) } }

        var child: pid_t = 0
        try #require(posix_spawn(&child, executable.path, &fileActions, nil, argv, environment) == 0)
        close(plant[1])
        close(capture[1])

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(20)
        var reaped = false
        while !reaped, Date() < deadline {
            reaped = waitpid(child, &status, WNOHANG) == child
            if !reaped { usleep(10_000) }
        }
        if !reaped { kill(child, SIGKILL); waitpid(child, &status, 0) }
        #expect(reaped)

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(capture[0], &buffer, buffer.count)
        #expect(String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self) == "closed\n")
        // Nothing was written to the planted descriptor either.
        var planted = [UInt8](repeating: 0, count: 16)
        let flags = fcntl(plant[0], F_GETFL)
        _ = fcntl(plant[0], F_SETFL, flags | O_NONBLOCK)
        #expect(read(plant[0], &planted, planted.count) <= 0)
    }
}
