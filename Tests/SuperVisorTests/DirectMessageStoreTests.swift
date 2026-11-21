import Foundation
import Testing

@testable import SuperVisor

@Suite("Direct message store")
struct DirectMessageStoreTests {
    /// A store whose directory does not exist yet, inside a scratch folder the test removes.
    private struct Fixture {
        let folder = ScratchFolder()
        var directory: URL { folder.url.appendingPathComponent("dm", isDirectory: true) }
        var store: DirectMessageStore { DirectMessageStore(directory: directory) }

        func contents() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        }

        func mode(of url: URL) -> Int? {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.posixPermissions] as? NSNumber)?.intValue
        }
    }

    private static func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(1_789_000_000 + seconds))
    }

    private static func snapshot(
        source: String = "instagram",
        threads: Int = 2,
        messages: Int = 3,
        text: String = "hello"
    ) -> DirectMessageSnapshot {
        DirectMessageSnapshot(
            source: source,
            syncedAt: date(5_000),
            threads: (0..<threads).map { index in
                DirectMessageThread(
                    id: "thread-\(index)",
                    title: index.isMultiple(of: 2) ? "Chat \(index)" : nil,
                    participants: ["maya.chen", "sam_ortiz"],
                    isGroup: index.isMultiple(of: 2),
                    lastActivity: date(index),
                    isUnread: index.isMultiple(of: 3) ? nil : true,
                    messages: (0..<messages).map { number in
                        DirectMessage(
                            id: "m-\(index)-\(number)",
                            sent: date(number),
                            isFromViewer: number.isMultiple(of: 2),
                            sender: number.isMultiple(of: 2) ? nil : "maya.chen",
                            text: text,
                            shared: number == 1 ? "A reel" : nil
                        )
                    }
                )
            }
        )
    }

    // MARK: Round trip

    @Test("A snapshot reads back as written")
    func roundTrip() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        let snapshot = Self.snapshot()

        try fixture.store.write(snapshot)

        #expect(fixture.store.read(source: "instagram") == snapshot.trimmed())
        #expect(fixture.store.read(source: "instagram")?.threads.count == 2)
    }

    @Test("Writing again replaces the earlier snapshot")
    func overwrite() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try fixture.store.write(Self.snapshot(threads: 3))
        let replacement = Self.snapshot(threads: 1, text: "second")

        try fixture.store.write(replacement)

        #expect(fixture.store.read(source: "instagram") == replacement.trimmed())
        #expect(fixture.contents() == ["instagram.json"])
    }

    @Test("Each source has a file of its own")
    func sourcesAreIndependent() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        let first = Self.snapshot(source: "instagram", threads: 1)
        let second = Self.snapshot(source: "other-source", threads: 2)

        try fixture.store.write(first)
        try fixture.store.write(second)

        #expect(fixture.store.read(source: "instagram") == first.trimmed())
        #expect(fixture.store.read(source: "other-source") == second.trimmed())
    }

    @Test("The directory is created with mode 0700 and the file written with mode 0600")
    func modes() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }

        try fixture.store.write(Self.snapshot())
        let file = try #require(fixture.store.url(for: "instagram"))

        #expect(fixture.mode(of: fixture.directory) == 0o700)
        #expect(fixture.mode(of: file) == 0o600)

        try fixture.store.write(Self.snapshot(threads: 1))
        #expect(fixture.mode(of: file) == 0o600)
    }

    // MARK: Trimming

    @Test("A snapshot of 30 chats with 30 messages each is kept as the 20 newest chats with their 20 newest messages")
    func trimming() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        let large = Self.snapshot(threads: 30, messages: 30)

        try fixture.store.write(large)

        let stored = try #require(fixture.store.read(source: "instagram"))
        #expect(stored.threads.map(\.id) == (10..<30).reversed().map { "thread-\($0)" })
        for thread in stored.threads {
            #expect(thread.messages.map(\.id) == (10..<30).map { "m-\(thread.id.dropFirst(7))-\($0)" })
        }

        let file = try #require(fixture.store.url(for: "instagram"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode(DirectMessageSnapshot.self, from: Data(contentsOf: file))
        #expect(onDisk.threads.count == DirectMessageSnapshot.maximumThreads)
        #expect(onDisk.threads.allSatisfy { $0.messages.count == DirectMessageSnapshot.maximumMessagesPerThread })
    }

    @Test("A file holding more than the kept size is trimmed when read")
    func readTrims() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let file = try #require(fixture.store.url(for: "instagram"))
        try encoder.encode(Self.snapshot(threads: 25, messages: 25)).write(to: file)

        let stored = try #require(fixture.store.read(source: "instagram"))

        #expect(stored.threads.count == 20)
        #expect(stored.threads.allSatisfy { $0.messages.count == 20 })
    }

    // MARK: Refusals on read

    @Test("A missing file, a directory, and undecodable bytes read as nil")
    func unreadableFiles() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        #expect(fixture.store.read(source: "instagram") == nil)

        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let file = try #require(fixture.store.url(for: "instagram"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(fixture.store.read(source: "instagram") == nil)

        try FileManager.default.removeItem(at: file)
        try Data("not json".utf8).write(to: file)
        #expect(fixture.store.read(source: "instagram") == nil)

        try Data("{\"source\":\"instagram\"}".utf8).write(to: file)
        #expect(fixture.store.read(source: "instagram") == nil)
    }

    @Test("A symlink at the file's path reads as nil")
    func symlinkRefused() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try fixture.store.write(Self.snapshot())
        let file = try #require(fixture.store.url(for: "instagram"))
        let target = fixture.folder.url.appendingPathComponent("real.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        #expect(fixture.store.read(source: "instagram") == nil)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: target, to: file)
        #expect(fixture.store.read(source: "instagram") != nil)
    }

    @Test("A file over the size cap reads as nil, and one exactly at it reads")
    func sizeCap() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try fixture.store.write(Self.snapshot())
        let file = try #require(fixture.store.url(for: "instagram"))
        var padded = try Data(contentsOf: file)
        let valid = padded.count
        padded.append(Data(repeating: UInt8(ascii: " "), count: DirectMessageStore.maximumFileBytes - valid))

        try padded.write(to: file)
        #expect(padded.count == DirectMessageStore.maximumFileBytes)
        #expect(fixture.store.read(source: "instagram") != nil)

        padded.append(UInt8(ascii: " "))
        try padded.write(to: file)
        #expect(fixture.store.read(source: "instagram") == nil)

        try Data(repeating: 0, count: DirectMessageStore.maximumFileBytes * 2).write(to: file)
        #expect(fixture.store.read(source: "instagram") == nil)
    }

    @Test("A file whose snapshot names a different source reads as nil")
    func sourceMismatch() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try fixture.store.write(Self.snapshot(source: "instagram"))
        let file = try #require(fixture.store.url(for: "instagram"))
        let other = try #require(fixture.store.url(for: "messenger"))
        try FileManager.default.copyItem(at: file, to: other)

        #expect(fixture.store.read(source: "messenger") == nil)
        #expect(fixture.store.read(source: "instagram") != nil)
    }

    // MARK: Source ids

    @Test("A source id that is not lowercase letters, digits, and hyphens has no file and cannot be written")
    func invalidSourceIDs() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        let escaped = fixture.folder.url.appendingPathComponent("x.json")
        try Data("keep".utf8).write(to: escaped)
        let names = [
            "", "Instagram", "../x", "a/b", "a.b", "a b", "a\nb", "ins\u{E9}", String(repeating: "a", count: 33)
        ]

        for name in names {
            #expect(fixture.store.url(for: name) == nil)
            #expect(fixture.store.read(source: name) == nil)
            #expect(throws: DirectMessageStore.WriteError.invalidSource) {
                try fixture.store.write(Self.snapshot(source: name))
            }
            fixture.store.remove(source: name)
        }

        #expect(fixture.contents().isEmpty)
        #expect(try String(contentsOf: escaped, encoding: .utf8) == "keep")
        #expect(fixture.store.url(for: String(repeating: "a", count: 32)) != nil)
        #expect(fixture.store.url(for: "insta-gram-2")?.lastPathComponent == "insta-gram-2.json")
    }

    // MARK: Remove

    @Test("Remove deletes the file, tolerates a missing one, and leaves a directory alone")
    func remove() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try fixture.store.write(Self.snapshot())
        let file = try #require(fixture.store.url(for: "instagram"))

        fixture.store.remove(source: "instagram")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(fixture.store.read(source: "instagram") == nil)
        fixture.store.remove(source: "instagram")

        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("inside".utf8).write(to: file.appendingPathComponent("keep.txt"))
        fixture.store.remove(source: "instagram")
        #expect(FileManager.default.fileExists(atPath: file.appendingPathComponent("keep.txt").path))
    }

    // MARK: Failed writes

    @Test("A write that cannot rename into place throws and leaves no temporary file")
    func failedRenameLeavesNoTemporaryFile() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        let occupied = fixture.directory.appendingPathComponent("instagram.json", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: occupied.appendingPathComponent("keep.txt"))

        #expect(throws: (any Error).self) {
            try fixture.store.write(Self.snapshot())
        }

        #expect(fixture.contents() == ["instagram.json"])
        #expect(FileManager.default.fileExists(atPath: occupied.appendingPathComponent("keep.txt").path))
    }

    @Test("A write whose directory path is held by a regular file throws and leaves no temporary file")
    func occupiedDirectoryPath() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        try Data("in the way".utf8).write(to: fixture.directory)

        #expect(throws: (any Error).self) {
            try fixture.store.write(Self.snapshot())
        }

        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.url.path)
        #expect(siblings == ["dm"])
        #expect(try String(contentsOf: fixture.directory, encoding: .utf8) == "in the way")
    }

    @Test("An encoded snapshot over the size cap throws and leaves the earlier file untouched")
    func tooLarge() throws {
        let fixture = Fixture()
        defer { fixture.folder.remove() }
        let earlier = Self.snapshot()
        try fixture.store.write(earlier)
        let hugeText = String(repeating: "x", count: 12_000)
        let huge = Self.snapshot(threads: 20, messages: 20, text: hugeText)

        #expect(throws: DirectMessageStore.WriteError.tooLarge) {
            try fixture.store.write(huge)
        }

        #expect(fixture.store.read(source: "instagram") == earlier.trimmed())
        #expect(fixture.contents() == ["instagram.json"])
    }
}
