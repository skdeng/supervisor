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

    @Test("The file holds nothing but the display fields and the attempt bookkeeping")
    func fileHoldsNoDestinations() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            try SiteRegistry.save([record()], to: file)
            let object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]]
            )

            #expect(Set(object[0].keys) == ["id", "name", "added", "attemptCount", "needsPerson"])
        }
    }

    @Test("A file written before the attempt keys existed loads with no attempts")
    func fileWithoutAttemptKeys() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            let entry: [String: Any] = [
                "id": "example.com",
                "name": "Example",
                "added": "2023-11-14T22:13:20Z",
                "lastSignedIn": "2023-11-14T23:13:20Z",
            ]
            try JSONSerialization.data(withJSONObject: [entry]).write(to: file)

            let loaded = try #require(SiteRegistry.load(from: file).first)

            #expect(loaded.attemptsDay == nil)
            #expect(loaded.attemptCount == 0)
            #expect(!loaded.needsPerson)
            #expect(loaded.lastSignedIn == Date(timeIntervalSince1970: 1_700_003_600))
        }
    }

    @Test("Attempt bookkeeping round-trips through the file")
    func attemptKeysRoundTrip() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            var marked = record()
            marked.attemptsDay = "2026-11-16"
            marked.attemptCount = 2
            marked.needsPerson = true

            try SiteRegistry.save([marked], to: file)

            #expect(SiteRegistry.load(from: file) == [marked])
        }
    }

    @Test("A stored attempt day that is not a date, and a count out of range, are brought back in range")
    func attemptKeysAreBounded() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("sites.json")
            var tampered = record()
            tampered.attemptsDay = "tomorrow\n"
            tampered.attemptCount = -4
            try write([tampered], to: file)
            var loaded = try #require(SiteRegistry.load(from: file).first)
            #expect(loaded.attemptsDay == nil)
            #expect(loaded.attemptCount == 0)

            tampered.attemptsDay = "2026-11-16"
            tampered.attemptCount = Int.max
            try write([tampered], to: file)
            loaded = try #require(SiteRegistry.load(from: file).first)
            #expect(loaded.attemptsDay == "2026-11-16")
            #expect(loaded.attemptCount == 1_000)
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

    // MARK: Attempts

    private func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier)! }

    /// 2026-11-16 at the given hour, UTC.
    private func utc(hour: Int, day: Int = 16) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026
        components.month = 11
        components.day = day
        components.hour = hour
        return components.date!
    }

    @Test("The day is the calendar day in the given time zone")
    func attemptDay() {
        // 23:30 in Los Angeles on the 15th is 07:30 UTC on the 16th.
        let instant = utc(hour: 7).addingTimeInterval(1_800)
        #expect(SignInAttempts.day(of: instant, in: zone("UTC")) == "2026-11-16")
        #expect(SignInAttempts.day(of: instant, in: zone("America/Los_Angeles")) == "2026-11-15")
        #expect(SignInAttempts.day(of: instant, in: zone("Pacific/Auckland")) == "2026-11-16")
    }

    @Test("A site with no attempts may be tried, and a failure or a success is counted")
    func attemptRecording() {
        let utcZone = zone("UTC")
        let fresh = record()
        #expect(SignInAttempts.mayAttempt(fresh, now: utc(hour: 9), timeZone: utcZone))

        let succeeded = SignInAttempts.recording(
            attemptOn: fresh,
            outcome: .succeeded,
            now: utc(hour: 9),
            timeZone: utcZone
        )
        #expect(succeeded.attemptsDay == "2026-11-16")
        #expect(succeeded.attemptCount == 1)
        #expect(succeeded.lastSignedIn == utc(hour: 9))
        #expect(!succeeded.needsPerson)

        let failed = SignInAttempts.recording(
            attemptOn: fresh,
            outcome: .needsPerson,
            now: utc(hour: 9),
            timeZone: utcZone
        )
        #expect(failed.attemptCount == 1)
        #expect(failed.needsPerson)
        #expect(failed.lastSignedIn == nil)
        #expect(!SignInAttempts.mayAttempt(failed, now: utc(hour: 9), timeZone: utcZone))
    }

    @Test("Three attempts are allowed a day and the fourth is refused")
    func attemptsPerDay() {
        let utcZone = zone("UTC")
        var site = record()
        for hour in [8, 9, 10] {
            #expect(SignInAttempts.mayAttempt(site, now: utc(hour: hour), timeZone: utcZone))
            site = SignInAttempts.recording(
                attemptOn: site,
                outcome: .succeeded,
                now: utc(hour: hour),
                timeZone: utcZone
            )
        }
        #expect(site.attemptCount == SignInAttempts.perDay)
        #expect(!SignInAttempts.mayAttempt(site, now: utc(hour: 11), timeZone: utcZone))
    }

    @Test("A new day starts the count again, by the calendar of the time zone")
    func attemptsResetOnANewDay() {
        let utcZone = zone("UTC")
        var site = record()
        for hour in [8, 9, 10] {
            site = SignInAttempts.recording(attemptOn: site, outcome: .succeeded, now: utc(hour: hour), timeZone: utcZone)
        }
        #expect(!SignInAttempts.mayAttempt(site, now: utc(hour: 23), timeZone: utcZone))
        #expect(SignInAttempts.mayAttempt(site, now: utc(hour: 0, day: 17), timeZone: utcZone))

        let next = SignInAttempts.recording(
            attemptOn: site,
            outcome: .succeeded,
            now: utc(hour: 0, day: 17),
            timeZone: utcZone
        )
        #expect(next.attemptsDay == "2026-11-17")
        #expect(next.attemptCount == 1)

        // Attempts at 05:00 to 07:00 UTC fall on the 15th in Los Angeles (21:00 to 23:00), so the
        // local day turns at 08:00 UTC, while the UTC day has hours to run.
        let losAngeles = zone("America/Los_Angeles")
        var local = record()
        var universal = record()
        for hour in [5, 6, 7] {
            local = SignInAttempts.recording(attemptOn: local, outcome: .succeeded, now: utc(hour: hour), timeZone: losAngeles)
            universal = SignInAttempts.recording(attemptOn: universal, outcome: .succeeded, now: utc(hour: hour), timeZone: utcZone)
        }
        let afterMidnightInLosAngeles = utc(hour: 8).addingTimeInterval(1_800)
        #expect(!SignInAttempts.mayAttempt(local, now: utc(hour: 7).addingTimeInterval(1_800), timeZone: losAngeles))
        #expect(SignInAttempts.mayAttempt(local, now: afterMidnightInLosAngeles, timeZone: losAngeles))
        #expect(!SignInAttempts.mayAttempt(universal, now: afterMidnightInLosAngeles, timeZone: utcZone))
    }

    @Test("A failure stops attempts on the same day and the next, until a person signs in")
    func failureStopsAttempts() {
        let utcZone = zone("UTC")
        let failed = SignInAttempts.recording(
            attemptOn: record(),
            outcome: .needsPerson,
            now: utc(hour: 9),
            timeZone: utcZone
        )

        #expect(!SignInAttempts.mayAttempt(failed, now: utc(hour: 9), timeZone: utcZone))
        #expect(!SignInAttempts.mayAttempt(failed, now: utc(hour: 9, day: 20), timeZone: utcZone))

        let signedIn = SignInAttempts.recordingPersonSignedIn(failed, now: utc(hour: 12))
        #expect(!signedIn.needsPerson)
        #expect(signedIn.attemptCount == 0)
        #expect(signedIn.lastSignedIn == utc(hour: 12))
        #expect(SignInAttempts.mayAttempt(signedIn, now: utc(hour: 12), timeZone: utcZone))
    }

    @Test("A failure that may not repeat uses up an attempt and does not set the flag")
    func transientFailure() {
        let utcZone = zone("UTC")
        var site = record()
        for hour in [8, 9, 10] {
            #expect(SignInAttempts.mayAttempt(site, now: utc(hour: hour), timeZone: utcZone))
            site = SignInAttempts.recording(
                attemptOn: site,
                outcome: .transientFailure,
                now: utc(hour: hour),
                timeZone: utcZone
            )
            #expect(!site.needsPerson)
            #expect(site.lastSignedIn == nil)
        }
        #expect(site.attemptCount == 3)
        #expect(!SignInAttempts.mayAttempt(site, now: utc(hour: 11), timeZone: utcZone))
        #expect(SignInAttempts.mayAttempt(site, now: utc(hour: 0, day: 17), timeZone: utcZone))
    }

    @Test("A transient failure leaves a flag that was already set, and a success clears it")
    func transientFailureKeepsTheFlag() {
        let utcZone = zone("UTC")
        var flagged = record()
        flagged.needsPerson = true

        let transient = SignInAttempts.recording(attemptOn: flagged, outcome: .transientFailure, now: utc(hour: 9), timeZone: utcZone)
        #expect(transient.needsPerson)

        let succeeded = SignInAttempts.recording(attemptOn: flagged, outcome: .succeeded, now: utc(hour: 9), timeZone: utcZone)
        #expect(!succeeded.needsPerson)
    }

    @Test("An attempt is counted before its outcome, settled after, and one cut short is taken back")
    func countedThenSettled() {
        let utcZone = zone("UTC")
        let before = record()

        let counted = SignInAttempts.beginning(attemptOn: before, now: utc(hour: 9), timeZone: utcZone)
        #expect(counted.attemptCount == 1)
        #expect(counted.attemptsDay == "2026-11-16")
        #expect(!counted.needsPerson)
        #expect(counted.lastSignedIn == nil)

        let failed = SignInAttempts.settling(counted, outcome: .needsPerson, now: utc(hour: 9))
        #expect(failed.attemptCount == 1)
        #expect(failed.needsPerson)
        let signedIn = SignInAttempts.settling(counted, outcome: .succeeded, now: utc(hour: 9))
        #expect(signedIn.attemptCount == 1)
        #expect(signedIn.lastSignedIn == utc(hour: 9))
        #expect(SignInAttempts.settling(counted, outcome: .transientFailure, now: utc(hour: 9)) == counted)
        // Counting then settling is recording.
        #expect(
            SignInAttempts.recording(attemptOn: before, outcome: .needsPerson, now: utc(hour: 9), timeZone: utcZone)
                == failed
        )

        let abandoned = SignInAttempts.abandoning(counted, restoring: before)
        #expect(abandoned == before)

        // An earlier attempt of the same day is kept when only the later one is taken back.
        let second = SignInAttempts.beginning(attemptOn: counted, now: utc(hour: 10), timeZone: utcZone)
        #expect(second.attemptCount == 2)
        #expect(SignInAttempts.abandoning(second, restoring: counted).attemptCount == 1)
        // The flag and sign-in time as they are now are not those of the record restored from.
        var flagged = second
        flagged.needsPerson = true
        let kept = SignInAttempts.abandoning(flagged, restoring: counted)
        #expect(kept.needsPerson)
        #expect(kept.attemptCount == 1)
    }

    @Test("A success after earlier failures clears the flag, and a person's sign-in clears the count")
    func successAndPersonClear() {
        let utcZone = zone("UTC")
        var flagged = record()
        flagged.needsPerson = true
        flagged.attemptsDay = "2026-11-16"
        flagged.attemptCount = 3

        let succeeded = SignInAttempts.recording(
            attemptOn: flagged,
            outcome: .succeeded,
            now: utc(hour: 9),
            timeZone: utcZone
        )
        #expect(!succeeded.needsPerson)

        let person = SignInAttempts.recordingPersonSignedIn(flagged, now: utc(hour: 9))
        #expect(!person.needsPerson)
        #expect(person.attemptCount == 0)
        #expect(SignInAttempts.mayAttempt(person, now: utc(hour: 9), timeZone: utcZone))
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
