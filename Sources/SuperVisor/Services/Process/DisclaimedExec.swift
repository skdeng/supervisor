import Darwin
import Foundation

/// A mode of this executable that replaces itself with another program, started with
/// responsibility disclaimed (see `ProcessResponsibility`), so a program from a user-writable
/// location never answers for the app's privacy grants. A caller that needs a `Process`'s
/// plumbing keeps it and names this executable as the program.
///
///     SuperVisor --exec-disclaimed /absolute/path/to/program argument…
///
/// The program's argument zero is its path, its environment is this process's, and its standard
/// streams are this process's; every other descriptor is closed. Nothing here uses AppKit or the
/// app's log, and every failure ends the process with status 127 and one fixed line on stderr.
enum DisclaimedExec {
    static let flag = "--exec-disclaimed"
    static let failureStatus: Int32 = 127
    static let failureLine = "supervisor: the requested program could not be started\n"

    static func isRequested(in arguments: [String]) -> Bool {
        arguments.dropFirst().contains(flag)
    }

    /// The program named after the first `flag` in `arguments`, and the argument list it starts
    /// with (its own path first). Nil when no program follows the flag, or it is not an
    /// absolute path.
    static func command(from arguments: [String]) -> (program: String, arguments: [String])? {
        guard let flagIndex = arguments.dropFirst().firstIndex(of: flag),
              arguments.indices.contains(flagIndex + 1),
              arguments[flagIndex + 1].hasPrefix("/")
        else { return nil }
        let program = arguments[flagIndex + 1]
        return (program, [program] + arguments[(flagIndex + 2)...])
    }

    /// Replaces this process with the program `command(from:)` finds in `arguments`.
    static func run(arguments: [String]) -> Never {
        guard let command = command(from: arguments) else { fail() }
        let program = command.program
        let programArguments = command.arguments

        var attributes: posix_spawnattr_t?
        var fileActions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&fileActions)

        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0,
            ProcessResponsibility.disclaim(&attributes)
        else { fail() }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addinherit_np(&fileActions, descriptor) == 0 else {
                fail()
            }
        }

        let argumentPointers = programArguments.map { strdup($0) } + [nil]
        let environmentPointers = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        var processIdentifier: pid_t = 0
        // With SETEXEC a successful spawn replaces this process and never returns.
        _ = posix_spawn(
            &processIdentifier,
            program,
            &fileActions,
            &attributes,
            argumentPointers,
            environmentPointers
        )
        fail()
    }

    private static func fail() -> Never {
        _ = failureLine.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
        exit(failureStatus)
    }
}
