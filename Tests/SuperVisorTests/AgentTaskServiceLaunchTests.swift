import Darwin
import Foundation
import Testing

@testable import SuperVisor

@MainActor
@Suite("Agent task launch")
struct AgentTaskServiceLaunchTests {
    /// An executable that runs `body` as a shell script, then prints `result` (a shell
    /// expression) as the agent's result line.
    private func makeStandIn(
        in folder: ScratchFolder,
        body: String = "",
        result: String = #""$$""#
    ) throws -> URL {
        let script = folder.url.appendingPathComponent("agent")
        try """
        #!/bin/sh
        \(body)
        printf '{"type":"result","is_error":false,"result":"%s"}\\n' \(result)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // MARK: onLaunch

    @Test("onLaunch receives the child's pid once, while the child still exists")
    func onLaunchReceivesChildPID() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let service = AgentTaskService(executableOverride: try makeStandIn(in: folder))

        var launched: [pid_t] = []
        var existedAtLaunch: [Bool] = []
        let result = try await service.run(
            arguments: [],
            workingDirectory: folder.url,
            timeout: .seconds(30),
            onLaunch: { pid in
                launched.append(pid)
                existedAtLaunch.append(kill(pid, 0) == 0)
            }
        )

        #expect(launched.count == 1)
        #expect(launched.first.map { String($0) } == result.text, "the pid is the child's own")
        #expect(launched.first != getpid())
        #expect(existedAtLaunch == [true])
    }

    @Test("A run started without an onLaunch callback completes and returns the agent's result")
    func runsWithoutCallback() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let service = AgentTaskService(executableOverride: try makeStandIn(in: folder))

        let result = try await service.run(
            arguments: [],
            workingDirectory: folder.url,
            timeout: .seconds(30)
        )
        #expect(Int32(result.text) != nil)
    }

    @Test(
        "A run stopped by a limit fails as that limit, whatever its exit status and stderr",
        arguments: [
            ("error_max_turns", AgentRunLimit.turns, 1),
            ("error_max_budget_usd", AgentRunLimit.spending, 1),
            ("error_max_turns", AgentRunLimit.turns, 0),
        ]
    )
    func limitStop(subtype: String, limit: AgentRunLimit, status: Int) async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let script = folder.url.appendingPathComponent("agent")
        try """
        #!/bin/sh
        printf '{"type":"result","is_error":true,"subtype":"\(subtype)"}\\n'
        echo "a line on stderr" >&2
        exit \(status)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let service = AgentTaskService(executableOverride: script)

        do {
            _ = try await service.run(arguments: [], workingDirectory: folder.url, timeout: .seconds(30))
            Issue.record("the run reported success")
        } catch let error as AgentTaskError {
            guard case let .limitReached(reached) = error else {
                Issue.record("failed as \(error.caseName)")
                return
            }
            #expect(reached == limit)
            #expect(error.localizedDescription == limit.sentence)
        }
    }

    @Test("A limit's log name and sentence are fixed text")
    func limitNames() {
        #expect(AgentRunLimit.turns.logName == "turn limit")
        #expect(AgentRunLimit.spending.logName == "spending limit")
        #expect(AgentRunLimit(resultSubtype: "error_during_execution") == nil)
        #expect(AgentRunLimit(resultSubtype: 7) == nil)
    }

    @Test("A stand-in that cannot be launched reports a launch failure and never calls onLaunch")
    func launchFailureSkipsCallback() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let notExecutable = folder.url.appendingPathComponent("missing")
        let service = AgentTaskService(executableOverride: notExecutable)

        var launches = 0
        do {
            _ = try await service.run(
                arguments: [],
                workingDirectory: folder.url,
                timeout: .seconds(30),
                onLaunch: { _ in launches += 1 }
            )
            Issue.record("the run should not have started")
        } catch let error as AgentTaskError {
            #expect(error.caseName == "launchFailed")
        }
        #expect(launches == 0)
    }

    // MARK: Descriptors

    @Test("The child holds no descriptor of the app's beyond its standard streams, even one left open across exec")
    func descriptorsDoNotLeak() async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        defer { descriptors.forEach { close($0) } }
        // A descriptor the app might hold with close-on-exec cleared: a plain spawn would hand
        // it to the child.
        _ = fcntl(descriptors[1], F_SETFD, 0)
        _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK)

        let folder = ScratchFolder()
        defer { folder.remove() }
        let probe = try makeStandIn(
            in: folder,
            body: #"if (echo leak >&"$1") 2>/dev/null; then verdict=leaked; else verdict=closed; fi"#,
            result: #""$verdict""#
        )
        let service = AgentTaskService(executableOverride: probe)

        let result = try await service.run(
            arguments: [String(descriptors[1])],
            workingDirectory: folder.url,
            timeout: .seconds(30)
        )

        #expect(result.text == "closed")
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(read(descriptors[0], &buffer, buffer.count) <= 0, "nothing reached the pipe")
    }

    // MARK: Disclaiming responsibility

    @Test("A disclaim that does not take starts nothing and reports a launch failure")
    func failedDisclaimStartsNothing() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let marker = folder.url.appendingPathComponent("ran")
        let standIn = try makeStandIn(in: folder, body: "touch \"\(marker.path)\"")
        let service = AgentTaskService(executableOverride: standIn, disclaim: { _ in false })

        var launches = 0
        do {
            _ = try await service.run(
                arguments: [],
                workingDirectory: folder.url,
                timeout: .seconds(30),
                onLaunch: { _ in launches += 1 }
            )
            Issue.record("the run should not have started")
        } catch let error as AgentTaskError {
            #expect(error.caseName == "launchFailed")
        }

        #expect(launches == 0)
        // A child that had been started would have written its marker within moments.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("The disclaim is applied to the spawn attributes of every run")
    func disclaimIsApplied() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let applied = Recorder<Bool>()
        let service = AgentTaskService(
            executableOverride: try makeStandIn(in: folder),
            disclaim: { attributes in
                let took = ProcessResponsibility.disclaim(&attributes)
                applied.record(took)
                return took
            }
        )

        _ = try await service.run(arguments: [], workingDirectory: folder.url, timeout: .seconds(30))
        #expect(applied.all == [true])
    }

    // MARK: Environment

    /// The variables a stand-in sees, by name.
    private func environment(
        of text: String
    ) throws -> [String: String] {
        let decoded = try #require(Data(base64Encoded: text))
        var variables: [String: String] = [:]
        for line in String(decoding: decoded, as: UTF8.self).split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            variables[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return variables
    }

    private func makeEnvironmentProbe(in folder: ScratchFolder) throws -> URL {
        try makeStandIn(
            in: folder,
            result: #""$(/usr/bin/env | /usr/bin/base64 | /usr/bin/tr -d '\n')""#
        )
    }

    @Test("The child gets the fixed environment: nothing of the app's own reaches it")
    func childEnvironmentIsFixed() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let service = AgentTaskService(executableOverride: try makeEnvironmentProbe(in: folder))

        let result = try await service.run(
            arguments: [],
            workingDirectory: folder.url,
            timeout: .seconds(30)
        )
        let seen = try environment(of: result.text)

        // The shell adds a few variables of its own to whatever it is given.
        let shellAdded: Set<String> = ["PWD", "SHLVL", "_", "OLDPWD"]
        let allowed = Set(ChildEnvironment.minimal().keys).union(shellAdded)
        #expect(Set(seen.keys).subtracting(allowed).isEmpty, "\(Set(seen.keys).subtracting(allowed))")
        for (name, value) in ChildEnvironment.minimal() {
            #expect(seen[name] == value, "\(name)")
        }

        // Variables this test process has that the child must not.
        let foreign = ProcessInfo.processInfo.environment.keys.filter { !allowed.contains($0) }
        try #require(!foreign.isEmpty, "the test process has no variable outside the fixed list")
        for name in foreign {
            #expect(seen[name] == nil, "\(name) reached the child")
        }
        #expect(ProcessInfo.processInfo.environment["PATH"] != seen["PATH"])
    }

    @Test("Variables passed to run reach the child, and replace a fixed one of the same name")
    func extraEnvironmentReachesChild() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let service = AgentTaskService(executableOverride: try makeEnvironmentProbe(in: folder))

        let result = try await service.run(
            arguments: [],
            workingDirectory: folder.url,
            timeout: .seconds(30),
            environment: ["SUPERVISOR_EXTRA_PROBE": "42", "LANG": "C"]
        )
        let seen = try environment(of: result.text)
        #expect(seen["SUPERVISOR_EXTRA_PROBE"] == "42")
        #expect(seen["LANG"] == "C")
        #expect(seen["HOME"] == NSHomeDirectory())
    }

    @Test("Error case names are stable identifiers")
    func caseNames() {
        #expect(AgentTaskError.binaryNotFound.caseName == "binaryNotFound")
        #expect(AgentTaskError.launchFailed("x").caseName == "launchFailed")
        #expect(AgentTaskError.unreadableSource.caseName == "unreadableSource")
        #expect(AgentTaskError.timedOut.caseName == "timedOut")
        #expect(AgentTaskError.cancelled.caseName == "cancelled")
        #expect(AgentTaskError.agentError("secret text").caseName == "agentError")
        #expect(AgentTaskError.limitReached(.turns).caseName == "limitReached")
        #expect(AgentTaskError.malformedOutput("secret text").caseName == "malformedOutput")
    }
}
