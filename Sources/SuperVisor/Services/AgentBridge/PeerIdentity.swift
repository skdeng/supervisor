import Darwin
import Foundation
import Security

/// Who is on the other end of a connected Unix socket.
enum PeerIdentity {
    /// The process on the other end of a connected Unix socket, as the kernel recorded it when
    /// the connection was made. The token carries the process's version counter, so it names one
    /// process even if its pid is later reused.
    static func auditToken(of descriptor: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size)
        else { return nil }
        return token
    }

    /// The pid in `token`. `audit_token_to_pid` lives in libbsm, which this package does not
    /// link, so the pid is read from its slot (`val[5]`) in the token's documented layout.
    static func processIdentifier(of token: audit_token_t) -> pid_t {
        pid_t(truncatingIfNeeded: token.val.5)
    }

    /// Whether the process behind `token` is running code that satisfies this app's own
    /// designated requirement: the same signing identity, not merely the same name. False on
    /// any failure to establish that.
    static func satisfiesOwnRequirement(_ token: audit_token_t) -> Bool {
        guard let requirement = ownRequirement else { return false }

        var tokenCopy = token
        let tokenData = withUnsafeBytes(of: &tokenCopy) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest
        else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    /// Whether this process is still running the code its bundle holds on disk. A bundle
    /// rebuilt or replaced under a running app leaves the process valid by its signature and
    /// no longer the code on disk, which `SecCodeCheckValidity` reports as a failure. The
    /// bridge helper is started from the bundle on disk and makes this same check on the app
    /// before it sends anything, so while it fails no run can reach a tool.
    static func runningCodeIsIntact() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    /// What a bundle on disk is, to this app.
    enum BundleStatus: Equatable, Sendable {
        /// Whole, its nested code included, and signed to this app's own requirement.
        case valid
        /// Not a whole signed bundle: one a build has not finished assembling or signing.
        case incomplete
        /// Whole, and signed to some other requirement: another signer, or an ad-hoc build,
        /// whose requirement names one exact build.
        case otherSigner
    }

    static func bundleStatus(at url: URL) -> BundleStatus {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return .incomplete }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            return .incomplete
        }
        guard let requirement = ownRequirement,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
        else { return .otherSigner }
        return .valid
    }

    /// Touches `ownRequirement`, which is resolved on its first use in the process and never
    /// again. Called at launch, it makes that first use happen while the code on disk is still
    /// the code that was launched.
    static func resolveOwnRequirement() {
        _ = ownRequirement
    }

    /// This app's designated requirement as text, in the form `codesign -R` reads.
    static var ownRequirementText: String? {
        guard let requirement = ownRequirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else {
            return nil
        }
        return text as String
    }

    /// Resolved once. A `SecRequirement` is an immutable Core Foundation object, safe to share
    /// across threads. **It is read from the bundle on disk** (the running code's static code),
    /// so a first use after the bundle was replaced yields the replacement's requirement, not
    /// the launched app's; `resolveOwnRequirement` at launch closes that.
    private nonisolated(unsafe) static let ownRequirement: SecRequirement? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }()

    /// How many parents separate `process` from `ancestor`: 0 for the process itself, 1 for a
    /// direct child. Nil when `ancestor` is not within `maximumDepth` parents, or when
    /// `ancestorStarted` is given and the process found at `ancestor`'s pid started at another
    /// time, which marks a pid that was reused. Pids that cannot name a run's root (zero,
    /// negative, and launchd's 1) never match.
    static func depth(
        of process: pid_t,
        below ancestor: pid_t,
        maximumDepth: Int = 16,
        ancestorStarted: ProcessStartTime? = nil
    ) -> Int? {
        guard process > 0, ancestor > 1 else { return nil }
        var current = process
        var depth = 0
        while true {
            if current == ancestor {
                guard let ancestorStarted else { return depth }
                return ProcessAncestry.startTime(of: current) == ancestorStarted ? depth : nil
            }
            guard depth < maximumDepth,
                  let parent = ProcessAncestry.parentPID(of: current),
                  parent > 1
            else { return nil }
            current = parent
            depth += 1
        }
    }

    /// Whether `process` is `ancestor` or descends from it, within `maximumDepth` parents.
    static func descends(
        _ process: pid_t,
        from ancestor: pid_t,
        maximumDepth: Int = 16,
        ancestorStarted: ProcessStartTime? = nil
    ) -> Bool {
        depth(
            of: process,
            below: ancestor,
            maximumDepth: maximumDepth,
            ancestorStarted: ancestorStarted
        ) != nil
    }
}
