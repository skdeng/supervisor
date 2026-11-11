import AppKit
import Darwin

/// The GUI app a Claude Code session runs inside: the terminal emulator that owns its shell, or
/// an app hosting the CLI itself (the Claude desktop app, an editor's integrated terminal).
///
/// Found by walking the session process's parents to the first one LaunchServices knows as a
/// regular, Dock-visible app. A session whose ancestry is cut off — a tmux server reparents
/// its shells to launchd — has no host, and Jump falls back to the session's link or the
/// hook's tty.
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

/// A URL the session's host app opens to show that one session.
struct SessionLink: Equatable, Sendable {
    let url: URL
    /// The app the link belongs to, and the only app it is ever opened in.
    let bundleIdentifier: String
    /// Names the app in a Jump label when process ancestry found no host.
    let appName: String

    static let claudeDesktopBundleIdentifier = "com.anthropic.claudefordesktop"

    /// The Claude desktop app's link to one of its sessions, built from the `entrypoint` and
    /// `hostSessionId` Claude Code records in the session registry. The desktop app's URL
    /// handler accepts `claude://code/continue?session=<id>` for an id of this exact shape and
    /// navigates to that session. A registry file is writable by anything running as the user,
    /// so an id of any other shape yields no link. The pattern is anchored with `\A` and `\z`,
    /// which every regex engine treats as the absolute ends of the input; ICU's `$` also matches
    /// before a trailing line terminator.
    static func claudeDesktop(entrypoint: String?, hostSessionID: String?) -> SessionLink? {
        guard entrypoint == "claude-desktop",
              let hostSessionID,
              hostSessionID.range(
                  of: #"\Alocal_[A-Za-z0-9-]{1,64}\z"#,
                  options: .regularExpression
              ) != nil
        else { return nil }

        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: hostSessionID)]
        guard let url = components.url else { return nil }
        return SessionLink(
            url: url,
            bundleIdentifier: claudeDesktopBundleIdentifier,
            appName: "Claude"
        )
    }
}

/// Where a Jump can carry the user: an iTerm2 tab by tty, the session itself inside a host app
/// that has a link to it, or the host app brought forward.
struct JumpTarget: Equatable, Sendable {
    let tty: String?
    let host: SessionHost?
    let sessionLink: SessionLink?

    /// The host comes from process ancestry, which a registry file cannot forge, so a link
    /// belonging to any app other than a resolved host is dropped.
    init?(tty: String?, host: SessionHost?, sessionLink: SessionLink? = nil) {
        let link = sessionLink.flatMap { link in
            host == nil || host?.bundleIdentifier == link.bundleIdentifier ? link : nil
        }
        guard tty != nil || host != nil || link != nil else { return nil }
        self.tty = tty
        self.host = host
        self.sessionLink = link
    }

    /// Whether the jump selects an iTerm2 tab. A tty with no identified host is taken for
    /// iTerm2's; a session link marks the session as living in another app, whatever tty the
    /// CLI runs under there.
    var selectsITermTab: Bool {
        tty != nil && sessionLink == nil && (host == nil || host?.isITerm == true)
    }

    var label: String {
        if selectsITermTab { return "Open in iTerm2" }
        return "Open in \(host?.name ?? sessionLink?.appName ?? "iTerm2")"
    }

    var systemImage: String { selectsITermTab ? "apple.terminal" : "arrow.up.forward.app" }
}
