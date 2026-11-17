import Foundation
import Testing

@testable import SuperVisor

@Suite("File actions")
struct FileActionServiceTests {
    /// The entry names of the archive at `url`, as `unzip` lists them.
    private func entries(of archive: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", archive.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.stopAndReap() }
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        #expect(process.waitForExit(timeout: 20))
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }

    @Test("Compressing files and a folder writes an archive with clean relative entries")
    func compressesWithTheFixedEnvironment() async throws {
        let folder = ScratchFolder()
        defer { folder.remove() }
        let directory = folder.url.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("inner"),
            withIntermediateDirectories: true
        )
        try Data("a".utf8).write(to: directory.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("inner/b.txt"))
        let loose = folder.url.appendingPathComponent("-loose.txt")
        try Data("c".utf8).write(to: loose)

        let archive = try await FileActionService.compress([directory, loose])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        #expect(try entries(of: archive) == [
            "-loose.txt", "docs/", "docs/a.txt", "docs/inner/", "docs/inner/b.txt",
        ])
    }
}
