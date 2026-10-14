import Foundation

/// The Claude Code sign-in as it sits in the login Keychain: the OAuth access token plus the
/// two facts that decide whether a usage read with it is worth sending.
struct ClaudeOAuthCredential: Equatable {
    let accessToken: String
    /// Access-token expiry, absent when the stored record carries none.
    let expiresAt: Date?
    let scopes: [String]

    /// The scope the usage endpoint requires. A sign-in granted before Claude Code requested it
    /// answers 403 until the user signs in again.
    static let profileScope = "user:profile"
    /// Claude Code treats a token as expired this long before its stated expiry. Matching it
    /// keeps the two from disagreeing about whether a request is worth sending.
    static let expiryBuffer: TimeInterval = 5 * 60
    private static let maxTokenLength = 8_192

    /// Parses the JSON Claude Code stores under its Keychain item or credentials file:
    /// `{"claudeAiOauth": {"accessToken", "expiresAt" (epoch milliseconds), "scopes", …}}`.
    /// Only those three fields are read. The refresh token beside them is never read: using it
    /// would rotate the tokens out from under Claude Code. The token must be printable ASCII
    /// with no whitespace, since it goes into a header verbatim and the plain-file store is
    /// writable by anything running as the user.
    static func parse(_ data: Data) -> ClaudeOAuthCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let oauth = payload["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              !accessToken.isEmpty,
              accessToken.count <= Self.maxTokenLength,
              accessToken.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F })
        else { return nil }

        var expiresAt: Date?
        if let milliseconds = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           milliseconds.isFinite, milliseconds > 0 {
            expiresAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        let scopes = (oauth["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ClaudeOAuthCredential(accessToken: accessToken, expiresAt: expiresAt, scopes: scopes)
    }

    var hasProfileScope: Bool { scopes.contains(Self.profileScope) }

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(Self.expiryBuffer) >= expiresAt
    }
}

extension UsageTickerWindow {
    /// The Claude quota windows in display order, keyed as both the usage endpoint and the
    /// statusline's `rate_limits` object name them.
    static let claudeWindowKeys: [(key: String, label: String)] = [
        ("five_hour", "5h"),
        ("seven_day", "7d"),
        ("seven_day_opus", "Opus"),
        ("seven_day_sonnet", "Sonnet"),
    ]
}

/// Reads the signed-in Claude account's plan-quota windows from the endpoint Claude Code's
/// `/usage` command reads, authenticated with the OAuth token Claude Code keeps in the login
/// Keychain.
///
/// This is the one quota source that works however Claude Code is hosted. A terminal session's
/// statusline carries the same numbers, but a session driven by the desktop app or any other
/// SDK client runs the CLI headless and never renders one. The Keychain item is read through
/// `/usr/bin/security`, the tool Claude Code stores it with, so the item's access list already
/// admits the read without a prompt. The token lives only in the request it authenticates: it
/// is never logged, the refresh token stored beside it is never read, and the request goes
/// through an ephemeral session — the shared session's disk cache would otherwise persist the
/// request, `Authorization` header included, because the response carries no cache directive —
/// that also refuses redirects, so the header can never follow one to another host.
///
/// One read is in flight at a time; a request made while one is out is answered by it.
@MainActor
final class ClaudeUsageClient {
    typealias CredentialReader = @Sendable () async -> Data?
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    var onSnapshot: (([UsageTickerWindow]) -> Void)?
    /// Called with a short, token-free reason when a read cannot produce a snapshot.
    var onUnavailable: ((String) -> Void)?

    static let defaultEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated static let keychainService = "Claude Code-credentials"
    nonisolated static let defaultCredentialFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    /// The beta header that admits an OAuth bearer token on the API host.
    private static let oauthBetaHeader = "oauth-2025-04-20"
    nonisolated private static let requestTimeout: TimeInterval = 10
    private static let maxResponseBytes = 1 << 20
    nonisolated private static let maxCredentialBytes = 1 << 16
    /// `security` blocks on a Keychain dialog the user has not answered; a read that long is
    /// abandoned so the row can try again later.
    nonisolated private static let keychainReadTimeout: TimeInterval = 10

    private let endpoint: URL
    private let readCredential: CredentialReader
    private let transport: Transport
    private var inFlight: Task<Void, Never>?
    /// Identifies the read `inFlight` holds, so a read cancelled by `stop()` that finishes late
    /// never clears the handle of the read that replaced it.
    private var readGeneration = 0

    init(
        endpoint: URL = ClaudeUsageClient.defaultEndpoint,
        readCredential: @escaping CredentialReader = { await ClaudeUsageClient.readStoredCredential() },
        transport: @escaping Transport = ClaudeUsageClient.ephemeralTransport()
    ) {
        self.endpoint = endpoint
        self.readCredential = readCredential
        self.transport = transport
    }

    func requestSnapshot() {
        guard inFlight == nil else { return }
        readGeneration &+= 1
        let generation = readGeneration
        inFlight = Task { [weak self] in
            guard let self else { return }
            await self.performRead()
            if self.readGeneration == generation {
                self.inFlight = nil
            }
        }
    }

    func stop() {
        inFlight?.cancel()
        inFlight = nil
        readGeneration &+= 1
    }

    private func performRead() async {
        guard let data = await readCredential() else {
            report("no stored sign-in")
            return
        }
        guard !Task.isCancelled else { return }
        guard let credential = ClaudeOAuthCredential.parse(data) else {
            report("stored sign-in unreadable")
            return
        }
        guard credential.hasProfileScope else {
            report("sign-in lacks the profile scope")
            return
        }
        guard !credential.isExpired() else {
            report("sign-in token expired")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await transport(request)
        } catch {
            guard !Task.isCancelled else { return }
            report("request failed: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        guard let http = response as? HTTPURLResponse else {
            report("non-HTTP response")
            return
        }
        guard http.statusCode == 200 else {
            report("http \(http.statusCode)")
            return
        }
        guard body.count <= Self.maxResponseBytes else {
            report("oversized response")
            return
        }
        let windows = Self.windows(from: body)
        guard !windows.isEmpty else {
            report("no usable windows in response")
            return
        }
        onSnapshot?(windows)
    }

    private func report(_ reason: String) {
        onUnavailable?(reason)
    }

    // MARK: - Transport

    /// A session that keeps nothing on disk — no cache, cookies, or credential store — and
    /// refuses to follow redirects.
    nonisolated static func ephemeralTransport() -> Transport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        let session = URLSession(
            configuration: configuration,
            delegate: RedirectRefusal(),
            delegateQueue: nil
        )
        return { request in try await session.data(for: request) }
    }

    private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
        nonisolated func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    // MARK: - Response

    /// Parses the usage endpoint's body: one object per window, each carrying `utilization` as
    /// a 0–100 percentage and `resets_at` as an ISO 8601 timestamp; windows the plan lacks are
    /// `null`. Any other shape yields no windows.
    nonisolated static func windows(from data: Data) -> [UsageTickerWindow] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { return [] }

        return UsageTickerWindow.claudeWindowKeys.compactMap { key, label in
            guard let entry = payload[key] as? [String: Any],
                  let used = (entry["utilization"] as? NSNumber)?.doubleValue,
                  used.isFinite,
                  let resetsText = entry["resets_at"] as? String,
                  let resetsAt = parseTimestamp(resetsText)
            else { return nil }
            return UsageTickerWindow(
                label: label,
                usedPercentage: min(max(used, 0), 100),
                resetsAt: resetsAt
            )
        }
    }

    /// The endpoint writes microsecond fractions with a `+00:00` offset; Claude Code's own
    /// types only promise ISO 8601, so a `Z` suffix and a whole-second time parse too.
    nonisolated static func parseTimestamp(_ text: String) -> Date? {
        let fractional = Date.ISO8601FormatStyle()
            .year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: true)
            .timeZone(separator: .colon)
        if let date = try? fractional.parse(text) { return date }

        let whole = Date.ISO8601FormatStyle()
            .year().month().day()
            .dateTimeSeparator(.standard)
            .time(includingFractionalSeconds: false)
            .timeZone(separator: .colon)
        if let date = try? whole.parse(text) { return date }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - Stored sign-in

    /// The credential JSON as Claude Code stored it: the Keychain item first, then the
    /// plain-file store Claude Code falls back to when the Keychain is unavailable to it.
    nonisolated static func readStoredCredential() async -> Data? {
        if let data = await readKeychainItem() { return data }
        guard !Task.isCancelled else { return nil }
        return readCredentialFile()
    }

    /// Runs `security` without blocking a cooperative thread: its exit resumes a
    /// continuation, a watchdog terminates it at `keychainReadTimeout`, and cancelling the
    /// surrounding task terminates it immediately.
    nonisolated private static func readKeychainItem() async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-a", NSUserName(),
            "-w",
            "-s", keychainService,
        ]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let box = ProcessBox(process)
        let exitStatus: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resume = OnceResume(continuation)
                process.terminationHandler = { process in
                    resume.resume(with: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    resume.resume(with: nil)
                    return
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + keychainReadTimeout
                ) {
                    box.terminate()
                }
            }
        } onCancel: {
            box.terminate()
        }

        guard exitStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty, data.count <= maxCredentialBytes else { return nil }
        return data
    }

    /// `Process` is not `Sendable`; the watchdog and cancellation closures reach it only to
    /// terminate it, which is safe from any thread.
    private final class ProcessBox: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    /// Resumes a continuation at most once: the termination handler and a launch failure
    /// both reach for it.
    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Int32?, Never>?
        init(_ continuation: CheckedContinuation<Int32?, Never>) {
            self.continuation = continuation
        }
        func resume(with status: Int32?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: status)
        }
    }

    nonisolated private static func readCredentialFile() -> Data? {
        guard let data = try? Data(contentsOf: defaultCredentialFileURL),
              !data.isEmpty,
              data.count <= maxCredentialBytes
        else { return nil }
        return data
    }
}
