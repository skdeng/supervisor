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

    /// Resolved once. A `SecRequirement` is an immutable Core Foundation object, safe to share
    /// across threads.
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
