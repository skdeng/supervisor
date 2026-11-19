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
        var current = ProcessAncestry.parentPID(of: pid)
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
            current = ProcessAncestry.parentPID(of: candidate)
            depth += 1
        }
        return nil
    }
}

/// A URL a session's host app opens: one of its sessions, or the draft of a new one.
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

    /// The longest prompt a new-session link carries. The desktop app cuts a prompt past its own
    /// limit of 14,336 characters, and a cut prompt says something other than what was written.
    static let newSessionPromptLimit = 4_000

    /// The Claude desktop app's link to the draft of a new session: `claude://code/new` with the
    /// prompt in `q` and the working folder in `folder`. The app shows the prompt unsent, for
    /// the person to read and send, and asks them to trust a folder it has not opened before.
    ///
    /// Nil for an empty prompt, one past `newSessionPromptLimit`, one holding a control
    /// character, or a folder that is not an absolute file path. Every character outside the
    /// unreserved set is percent-encoded: the app decodes the query as a form, where a bare `+`
    /// reads as a space.
    static func claudeDesktopNewSession(prompt: String, folder: URL) -> SessionLink? {
        guard !prompt.isEmpty,
              prompt.count <= newSessionPromptLimit,
              prompt.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }),
              folder.isFileURL,
              folder.path.hasPrefix("/"),
              let query = formEncoded(prompt),
              let path = formEncoded(folder.path)
        else { return nil }

        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "folder", value: path),
        ]
        guard let url = components.url else { return nil }
        return SessionLink(
            url: url,
            bundleIdentifier: claudeDesktopBundleIdentifier,
            appName: "Claude"
        )
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func formEncoded(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}

extension SessionLink {
    /// The app to open the link in: `host` when it is a running copy of the link's app, else
    /// another running copy, else the installed one. Nil when the app is not on this Mac.
    @MainActor
    func applicationURL(hostedBy host: SessionHost? = nil) -> URL? {
        if let host,
           let app = NSRunningApplication(processIdentifier: host.processIdentifier),
           !app.isTerminated,
           app.bundleIdentifier == bundleIdentifier,
           let bundleURL = app.bundleURL {
            return bundleURL
        }
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }
        return running?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Opens the link in the app at `bundleURL`, so another app registered for the same URL
    /// scheme never receives it. `onFailure` runs on the main actor when the open fails.
    @MainActor
    func open(
        at bundleURL: URL,
        category: AppLogCategory,
        onFailure: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // LaunchServices calls back off the main thread, so the handler is declared nonisolated.
        // The error is logged by domain and code: its description can quote the link, whose
        // query may hold what the person typed.
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { _, error in
            guard let error = error as NSError? else { return }
            AppLog.error(category, "session link open failed: \(error.domain) \(error.code)")
            Task { @MainActor in onFailure() }
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: bundleURL,
            configuration: configuration,
            completionHandler: completion
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
