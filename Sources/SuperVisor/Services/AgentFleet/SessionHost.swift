import AppKit
import Darwin

/// The GUI app a Claude Code session runs inside: the terminal emulator that owns its shell, or
/// an app hosting the CLI itself (the Claude desktop app, an editor's integrated terminal).
///
/// Found by walking the session process's parents to the first one LaunchServices knows as a
/// regular, Dock-visible app. A session whose ancestry is cut off — a tmux server reparents
/// its shells to launchd — has no host, and Jump falls back to the hook's tty alone.
struct SessionHost: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String

    static let iTermBundleIdentifier = "com.googlecode.iterm2"

    /// iTerm2 is the one host whose individual tab a jump can select, by tty.
    var isITerm: Bool { bundleIdentifier == Self.iTermBundleIdentifier }

    /// A chain deeper than this is not a shell under a terminal; the bound also guarantees the
    /// walk ends should the process table change underneath it.
    private static let maximumDepth = 32

    @MainActor
    static func resolve(forSessionPID pid: pid_t) -> SessionHost? {
        var current = parentPID(of: pid)
        var depth = 0
        while let candidate = current, candidate > 1, depth < maximumDepth {
            if let app = NSRunningApplication(processIdentifier: candidate),
               app.activationPolicy == .regular {
                return SessionHost(
                    processIdentifier: candidate,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.localizedName ?? app.bundleURL?.deletingPathExtension()
                        .lastPathComponent ?? "app"
                )
            }
            current = parentPID(of: candidate)
            depth += 1
        }
        return nil
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride
        else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent == pid ? nil : parent
    }
}

/// Where a Jump can carry the user: an iTerm2 tab by tty, or the session's host app.
struct JumpTarget: Equatable, Sendable {
    let tty: String?
    let host: SessionHost?

    init?(tty: String?, host: SessionHost?) {
        guard tty != nil || host != nil else { return nil }
        self.tty = tty
        self.host = host
    }

    /// Whether the jump selects an iTerm2 tab rather than bringing an app forward. A tty with no
    /// identified host keeps the original iTerm2 behavior.
    var selectsITermTab: Bool { tty != nil && (host == nil || host?.isITerm == true) }

    var label: String {
        if selectsITermTab { return "Open in iTerm2" }
        return "Open in \(host?.name ?? "iTerm2")"
    }

    var systemImage: String { selectsITermTab ? "apple.terminal" : "arrow.up.forward.app" }
}
