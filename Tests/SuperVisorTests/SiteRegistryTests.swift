import Foundation
import Testing

@testable import SuperVisor

@Suite("Site registry")
struct SiteRegistryTests {
    private func record(
        id: String = "example.com",
        name: String = "Example",
        lastSignedIn: Date? = nil
    ) -> SiteRecord {
        SiteRecord(
            id: id,
            name: name,
            added: Date(timeIntervalSince1970: 1_700_000_000),
            lastSignedIn: lastSignedIn
        )
    }

    private func numbered(_ index: Int) -> SiteRecord {
        record(id: "site\(index).example.org", name: "Site \(index)")
    }

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    // MARK: Hosts

    @Test(
        "Lowercase DNS names are hosts",
        arguments: [
            "example.com",
            "www.example.com",
            "a.b.c.example.co",
            "my-site.example.com",
            "x1.example.io",
            "1password.com",
            "a-b.cc",
            "xn--bcher-kva.example.com",
            "sub.example.museum",
        ]
    )
    func validHosts(_ host: String) {
        #expect(SiteHost.isValid(host))
    }

    @Test(
        "Anything else is not a host",
        arguments: [
            "",
            "example",
            "evil.com.",
            "EXAMPLE.com",
            "Example.com",
            "example.COM",
            "127.0.0.1",
            "[::1]",
            "::1",
            "exa mple.com",
            " example.com",
            "example.com ",
            "example.com\n",
            "a..b.com",
            ".example.com",
            "-a.com",
            "a-.com",
            "a.-b.com",
            "example.c",
            "example.com:443",
            "example.com/path",
            "user@example.com",
            "exa_mple.com",
            "example.c0m",
            "example.123",
            "exämple.com",
            "例え.jp",
            "example.com\u{0000}",
            String(repeating: "a", count: 64) + ".com",
            "example." + String(repeating: "a", count: 64),
        ]
    )
    func invalidHosts(_ host: String) {
        #expect(!SiteHost.isValid(host))
    }

    @Test("Label and total length limits are inclusive")
    func hostLengthLimits() {
        let label63 = String(repeating: "a", count: 63)
        #expect(SiteHost.isValid(label63 + ".com"))
        #expect(SiteHost.isValid("example." + label63))

        // 3 labels of 63 plus a 61-character tail, joined by dots, is 253 bytes.
        let at253 = [label63, label63, label63, String(repeating: "b", count: 61)].joined(separator: ".")
        #expect(at253.utf8.count == 253)
        #expect(SiteHost.isValid(at253))
        #expect(!SiteHost.isValid(at253 + "b"))
    }

    // MARK: Records

    @Test("A well-formed record is valid")
    func wellFormedRecord() {
        #expect(record().isValid)
        #expect(record(lastSignedIn: Date(timeIntervalSince1970: 1_700_003_600)).isValid)
    }

    @Test("The id must be a valid host")
    func idMustBeHost() {
        #expect(!record(id: "Example.com").isValid)
        #expect(!record(id: "example").isValid)
        #expect(!record(id: "").isValid)
        #expect(!record(id: "example.com:443").isValid)
    }

    @Test("A name is required and holds at most 60 characters once cleaned")
    func nameRules() {
        #expect(!record(name: "").isValid)
        #expect(!record(name: "   \n\t ").isValid)
        #expect(!record(name: "\u{1B}\u{07}").isValid)
        #expect(record(name: String(repeating: "n", count: 60)).isValid)
        #expect(!record(name: String(repeating: "n", count: 61)).isValid)
        // Whitespace is collapsed before the length is measured.
        #expect(record(name: "  " + String(repeating: "n", count: 60) + "   ").isValid)
    }

    // MARK: Files

    @Test("Saving and loading round-trips every field")
    func roundTrip() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let first = record(lastSignedIn: Date(timeIntervalSince1970: 1_700_003_600))
            let second = record(id: "bank.example.org", name: "Bank")

            try SiteRegistry.save([first, second], to: file)

            #expect(SiteRegistry.load(from: file) == [first, second])
        }
    }

    @Test("The file is pretty-printed JSON with sorted keys and ISO 8601 dates")
    func fileFormat() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try SiteRegistry.save([record(lastSignedIn: Date(timeIntervalSince1970: 1_700_003_600))], to: file)
            let text = try String(contentsOf: file, encoding: .utf8)

            #expect(text.contains("\n  {\n    \"added\" : \"2023-11-14T22:13:20Z\""))
            #expect(text.contains("\"lastSignedIn\" : \"2023-11-14T23:13:20Z\""))
            let keys = ["added", "id", "lastSignedIn", "name"]
            let positions = keys.map { text.range(of: "\"\($0)\" :")?.lowerBound }
            #expect(!positions.contains(nil))
            #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        }
    }

    @Test("The file holds nothing but the display fields")
    func fileHoldsNoDestinations() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try SiteRegistry.save([record()], to: file)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
            )

            #expect(Set(object[0].keys) == ["id", "name", "added"])
        }
    }

    @Test("A missing file is an empty list")
    func missingFile() throws {
        try withTemporaryDirectory { directory in
            #expect(SiteRegistry.load(from: directory.appendingPathComponent("absent.json")).isEmpty)
        }
    }

    @Test("An invalid entry is dropped and its valid neighbours survive")
    func invalidEntryDropped() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let good = record()
            let other = record(id: "other.example.org", name: "Other")
            let badID = record(id: "Plain.Example.net", name: "Plain")
            let badName = record(id: "named.example.net", name: "")
            try write([good, badID, badName, other], to: file)

            #expect(SiteRegistry.load(from: file) == [good, other])
        }
    }

    @Test("Of two entries with one id the first valid one wins")
    func duplicatesFirstWins() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let first = record(name: "First")
            let second = record(name: "Second")
            let invalidFirst = record(name: "")
            try write([first, second], to: file)
            #expect(SiteRegistry.load(from: file).map(\.name) == ["First"])

            // An invalid entry does not claim the id.
            try write([invalidFirst, second], to: file)
            #expect(SiteRegistry.load(from: file).map(\.name) == ["Second"])
        }
    }

    @Test("A file that does not decode as a whole is an empty list")
    func undecodableFile() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try Data("not json".utf8).write(to: file)
            #expect(SiteRegistry.load(from: file).isEmpty)

            // One entry missing a field makes the whole file unreadable.
            let valid = try JSONEncoder.unvalidated.encode([record()])
            var entries = try #require(JSONSerialization.jsonObject(with: valid) as? [[String: Any]])
            var broken = entries[0]
            broken["id"] = "second.example.org"
            broken["name"] = nil
            entries.append(broken)
            try JSONSerialization.data(withJSONObject: entries).write(to: file)
            #expect(SiteRegistry.load(from: file).isEmpty)

            // A date that is not ISO 8601 is also undecodable.
            entries = try #require(JSONSerialization.jsonObject(with: valid) as? [[String: Any]])
            entries[0]["added"] = "yesterday"
            try JSONSerialization.data(withJSONObject: entries).write(to: file)
            #expect(SiteRegistry.load(from: file).isEmpty)
        }
    }

    @Test("Fields that are not display fields are ignored on load")
    func unknownFieldsIgnored() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let valid = try JSONEncoder.unvalidated.encode([record()])
            var entries = try #require(JSONSerialization.jsonObject(with: valid) as? [[String: Any]])
            entries[0]["signInURL"] = "https://evil.example.net/login"
            entries[0]["fillHosts"] = ["evil.example.net"]
            try JSONSerialization.data(withJSONObject: entries).write(to: file)

            #expect(SiteRegistry.load(from: file) == [record()])
        }
    }

    @Test("A symlink is refused even when it points at a valid registry")
    func symlinkRefused() throws {
        try withTemporaryDirectory { directory in
            let real = directory.appendingPathComponent("real.json")
            let link = directory.appendingPathComponent("link.json")
            try SiteRegistry.save([record()], to: real)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            #expect(SiteRegistry.load(from: real).count == 1)
            #expect(SiteRegistry.load(from: link).isEmpty)
        }
    }

    @Test("A directory is not a registry")
    func directoryRefused() throws {
        try withTemporaryDirectory { directory in
            #expect(SiteRegistry.load(from: directory).isEmpty)
        }
    }

    @Test("A file over the size cap is refused")
    func oversizeRefused() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let valid = try JSONEncoder.unvalidated.encode([record()])
            try valid.write(to: file)
            #expect(SiteRegistry.load(from: file).count == 1)

            // Valid JSON, padded with whitespace past the cap.
            let padded = valid + Data(repeating: 0x20, count: SiteRegistry.maximumFileBytes)
            try padded.write(to: file)
            #expect(padded.count > SiteRegistry.maximumFileBytes)
            #expect(SiteRegistry.load(from: file).isEmpty)

            // Exactly at the cap is still read.
            let atCap = valid + Data(repeating: 0x20, count: SiteRegistry.maximumFileBytes - valid.count)
            try atCap.write(to: file)
            #expect(atCap.count == SiteRegistry.maximumFileBytes)
            #expect(SiteRegistry.load(from: file).count == 1)
        }
    }

    @Test("At most fifty records are loaded")
    func loadCapsTheList() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let many = (0..<(SiteRegistry.maximumSites + 5)).map(numbered)
            try write(many, to: file)

            let loaded = SiteRegistry.load(from: file)

            #expect(loaded.count == SiteRegistry.maximumSites)
            #expect(loaded.first?.id == many.first?.id)
            #expect(loaded.last?.id == many[SiteRegistry.maximumSites - 1].id)
        }
    }

    @Test("The saved file is readable by its owner alone, even over a looser existing file")
    func fileMode() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try SiteRegistry.save([record()], to: file)
            #expect(try mode(of: file) == 0o600)

            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(try mode(of: file) == 0o644)
            try SiteRegistry.save([record()], to: file)
            #expect(try mode(of: file) == 0o600)
        }
    }

    @Test("Saving leaves no temporary file behind and creates a missing folder")
    func saveLeavesOnlyTheFile() throws {
        try withTemporaryDirectory { directory in
            let folder = directory.appendingPathComponent("nested", isDirectory: true)
            let file = folder.appendingPathComponent("sites.json")
            try SiteRegistry.save([record()], to: file)
            try SiteRegistry.save([record(name: "Renamed")], to: file)

            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["sites.json"])
            #expect(SiteRegistry.load(from: file).map(\.name) == ["Renamed"])
        }
    }

    @Test("Saving replaces a symlink at the destination without writing through it")
    func saveDoesNotFollowSymlink() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.json")
            let link = directory.appendingPathComponent("sites.json")
            try Data("untouched".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            try SiteRegistry.save([record()], to: link)

            #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
            #expect(SiteRegistry.load(from: link).count == 1)
        }
    }

    @Test("Saving throws, and leaves the existing file as it was, when a record is invalid")
    func saveRejectsInvalidRecord() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try SiteRegistry.save([record()], to: file)
            let before = try Data(contentsOf: file)

            #expect(throws: SiteRegistry.SaveError.invalidSite) {
                try SiteRegistry.save([record(), record(id: "Other.example.org")], to: file)
            }
            #expect(throws: SiteRegistry.SaveError.invalidSite) {
                try SiteRegistry.save([record(), record(id: "other.example.org", name: " ")], to: file)
            }
            #expect(try Data(contentsOf: file) == before)
        }
    }

    @Test("Saving throws on more than fifty records and on a repeated id")
    func saveRejectsBadLists() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let fifty = (0..<SiteRegistry.maximumSites).map(numbered)

            try SiteRegistry.save(fifty, to: file)
            #expect(SiteRegistry.load(from: file).count == SiteRegistry.maximumSites)

            #expect(throws: SiteRegistry.SaveError.tooManySites) {
                try SiteRegistry.save(fifty + [numbered(SiteRegistry.maximumSites)], to: file)
            }
            #expect(throws: SiteRegistry.SaveError.duplicateSite) {
                try SiteRegistry.save([record(), record(name: "Again")], to: file)
            }
        }
    }

    @Test("Saving throws when the result would be a file loading refuses")
    func saveRejectsOversizedResult() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            // A character can carry any number of combining marks, so 60 characters can be
            // far more than 60 bytes.
            let heavy = String(repeating: "a" + String(repeating: "\u{0301}", count: 1_500), count: 60)
            #expect(heavy.count == 60)
            let records = (0..<2).map { record(id: "heavy\($0).example.org", name: heavy) }

            #expect(throws: SiteRegistry.SaveError.tooLarge) {
                try SiteRegistry.save(records, to: file)
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("A name is cleaned on the way in and out")
    func nameIsCleaned() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try SiteRegistry.save([record(name: "  My \n Bank\u{1B}[0m ")], to: file)

            #expect(SiteRegistry.load(from: file).first?.name == "My Bank[0m")

            // A file written by hand is cleaned the same way.
            try write([record(id: "hand.example.org", name: "  Hand \n Written\u{1B}[0m ")], to: file)
            #expect(SiteRegistry.load(from: file).first?.name == "Hand Written[0m")
        }
    }

    // MARK: Helpers

    private func write(_ records: [SiteRecord], to file: URL) throws {
        try JSONEncoder.unvalidated.encode(records).write(to: file)
    }

    private func mode(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private extension JSONEncoder {
    /// An encoder that writes records without validating them, so a test can put an invalid
    /// entry in a file that `SiteRegistry.save` would refuse to write.
    static var unvalidated: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
