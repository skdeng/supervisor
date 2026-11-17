import Foundation
import Security

/// Whether a process is the signed agent CLI. The bridge serves a run only under that
/// process: its installed path is writable by anything running as the user, and a replaced
/// binary would otherwise be trusted as the root of every tool call.
enum AgentExecutableTrust {
    /// The agent CLI's signing identity: its bundle identifier, a certificate chain to Apple, and
    /// the vendor's team. This is the one place the CLI's vendor is named.
    static let requirement =
        #"identifier "com.anthropic.claude-code" and anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

    private nonisolated(unsafe) static let compiledRequirement: SecRequirement? = {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess
        else { return nil }
        return compiled
    }()

    /// Whether the running process `pid` satisfies the requirement.
    static func isTrusted(process pid: pid_t) -> Bool {
        guard pid > 1, let compiledRequirement else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid: pid as NSNumber] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let guest
        else { return false }
        return SecCodeCheckValidity(guest, [], compiledRequirement) == errSecSuccess
    }

    /// Whether the file at `url` satisfies the requirement, judged on the file the path
    /// resolves to.
    static func isTrusted(executable url: URL) -> Bool {
        guard let compiledRequirement else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            url.resolvingSymlinksInPath() as CFURL, [], &code
        ) == errSecSuccess, let code
        else { return false }
        return SecStaticCodeCheckValidity(code, [], compiledRequirement) == errSecSuccess
    }
}
