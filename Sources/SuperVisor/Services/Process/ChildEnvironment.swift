import Foundation

/// The environment given to a child process: a fixed, short list, so a variable planted in the
/// app's own environment (through `launchctl setenv`, say) cannot steer what the child loads or runs.
enum ChildEnvironment {
    /// The directories a child searches for the programs it starts.
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The fixed list, with `extra` added on top (an entry of `extra` replaces a fixed one of the
    /// same name). The account's name, home folder, and temporary folder come from the system's
    /// record of the user; `NSUserName()`, `NSHomeDirectory()`, and `NSTemporaryDirectory()` ignore
    /// `$USER`, `$HOME`, and `$TMPDIR`.
    static func minimal(adding extra: [String: String] = [:]) -> [String: String] {
        var environment = [
            "PATH": path,
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/zsh",
        ]
        environment.merge(extra) { _, added in added }
        return environment
    }
}
