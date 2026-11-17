import Foundation

/// Finds a sign-in code a site emailed, by asking a minimal agent run to read the user's mail.
///
/// The run holds Gmail's read tools and nothing else, and answers with digits. Only a whole
/// answer of 4 to 8 digits is taken as a code, so whatever an email says to the run, the most
/// it can do is make a sign-in fail. A first answer of `NONE` means the email may not have
/// arrived yet, so the lookup waits and asks once more.
struct EmailedCodeLookup: Sendable {
    /// How long to wait before asking again after `NONE`.
    static let retryDelay: Duration = .seconds(20)

    /// Runs the lookup with the given arguments and returns the run's answer; nil when the run
    /// failed.
    let run: @Sendable (_ arguments: [String]) async -> String?
    let pause: @Sendable (_ duration: Duration) async -> Void

    init(
        run: @escaping @Sendable (_ arguments: [String]) async -> String?,
        pause: @escaping @Sendable (_ duration: Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.run = run
        self.pause = pause
    }

    func code(
        sender: String,
        since: Date,
        access: ProVisorAccess,
        connectorHold: String? = nil
    ) async -> String? {
        guard let arguments = ProVisorCommand.emailedCodeArguments(
            sender: sender,
            since: since,
            access: access,
            connectorHold: connectorHold
        ),
            let first = await run(arguments)
        else { return nil }
        if let code = ProVisorCommand.emailedCode(from: first) { return code }
        guard ProVisorCommand.emailedCodeIsAbsent(in: first) else { return nil }

        await pause(Self.retryDelay)
        guard !Task.isCancelled, let second = await run(arguments) else { return nil }
        return ProVisorCommand.emailedCode(from: second)
    }
}
