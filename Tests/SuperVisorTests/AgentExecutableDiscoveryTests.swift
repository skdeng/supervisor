import Foundation
import Testing

@testable import SuperVisor

/// The CLI's native installer places a symbolic link on the search path and keeps each
/// version's binary elsewhere, so discovery is exercised against real files and links.
@Suite("Agent CLI executable discovery")
struct AgentExecutableDiscoveryTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func makeFile(_ name: String, executable: Bool) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url.path
    }

    private func makeLink(_ name: String, to target: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        return path
    }

    @Test("An executable regular file is found")
    func findsExecutableFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try makeFile("claude", executable: true)

        #expect(AgentTaskService.firstExecutable(among: [binary])?.path == binary)
    }

    @Test("A symbolic link to an executable is found and returned as the link")
    func findsLinkToExecutable() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try makeFile("2.1.0", executable: true)
        let link = try makeLink("claude", to: binary)

        #expect(AgentTaskService.firstExecutable(among: [link])?.path == link)
    }

    @Test("A link reached through a second link is found")
    func findsChainedLink() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = try makeFile("2.1.0", executable: true)
        let inner = try makeLink("current", to: binary)
        let outer = try makeLink("claude", to: inner)

        #expect(AgentTaskService.firstExecutable(among: [outer])?.path == outer)
    }

    @Test("Candidates that cannot be launched are passed over for a later one that can")
    func skipsUnlaunchableCandidates() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("absent").path
        let dangling = try makeLink("dangling", to: missing)
        let plain = try makeFile("notes", executable: false)
        let linkToPlain = try makeLink("notes-link", to: plain)
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let linkToFolder = try makeLink("folder-link", to: folder.path)
        let binary = try makeFile("claude", executable: true)

        let unlaunchable = [missing, dangling, plain, linkToPlain, folder.path, linkToFolder]
        #expect(AgentTaskService.firstExecutable(among: unlaunchable) == nil)
        #expect(AgentTaskService.firstExecutable(among: unlaunchable + [binary])?.path == binary)
    }
}
