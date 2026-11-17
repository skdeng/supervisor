import Darwin
import Foundation
import Testing

@testable import SuperVisor

@Suite("Follow-up schedule")
struct FollowUpScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("The limits are a minute's delay, ten minutes between passes, and six a day")
    func limits() {
        #expect(FollowUpSchedule.delay == 60)
        #expect(FollowUpSchedule.minimumGap == 600)
        #expect(FollowUpSchedule.perDay == 6)
    }

    @Test("A first pass may start whenever one is owed")
    func firstPass() {
        #expect(FollowUpSchedule.mayStart(now: now, last: nil, startedToday: 0))
    }

    @Test("Two passes start at least ten minutes apart")
    func minimumGap() {
        for (seconds, allowed) in [
            (0.0, false), (1, false), (599, false), (599.9, false), (600, true), (601, true),
            (86_400, true),
        ] {
            #expect(
                FollowUpSchedule.mayStart(
                    now: now,
                    last: now.addingTimeInterval(-seconds),
                    startedToday: 1
                ) == allowed,
                "\(seconds) seconds after the last"
            )
        }
    }

    @Test("No more than six passes start in a day, however long ago the last one was")
    func perDay() {
        for started in 0...8 {
            #expect(
                FollowUpSchedule.mayStart(
                    now: now,
                    last: now.addingTimeInterval(-7_200),
                    startedToday: started
                ) == (started < 6),
                "\(started) started"
            )
        }
        #expect(!FollowUpSchedule.mayStart(now: now, last: nil, startedToday: 6))
    }

    @Test("A last start in the future, which a clock set back leaves, holds nothing up")
    func lastInTheFuture() {
        #expect(FollowUpSchedule.mayStart(now: now, last: now.addingTimeInterval(3_600), startedToday: 0))
        #expect(!FollowUpSchedule.mayStart(now: now, last: now.addingTimeInterval(3_600), startedToday: 6))
    }

    @Test("A pass owed after a sign-in waits five seconds and has its own six a day")
    func afterGrantLimits() {
        #expect(FollowUpSchedule.grantDelay == 5)
        #expect(FollowUpSchedule.grantsPerDay == 6)
    }

    @Test("A starting pass is charged to the sign-in count only while one is owed and that count has room")
    func charge() {
        for grants in 0...9 {
            #expect(
                FollowUpSchedule.charge(afterGrantOwed: true, grantsStartedToday: grants)
                    == (grants < 6 ? .afterGrant : .ordinary),
                "\(grants) sign-in passes started"
            )
            #expect(
                FollowUpSchedule.charge(afterGrantOwed: false, grantsStartedToday: grants) == .ordinary,
                "none owed, \(grants) sign-in passes started"
            )
        }
    }

    @Test("Which charge a pass that starts now takes, given what is owed and the day's two counts")
    func chargeToStart() {
        let recent = now.addingTimeInterval(-60)
        let old = now.addingTimeInterval(-3_600)
        // (owed after a sign-in, last start, ordinary today, sign-in passes today, expected)
        let table: [(Bool, Date?, Int, Int, FollowUpSchedule.Charge?)] = [
            (false, nil, 0, 0, .ordinary),
            (false, old, 5, 9, .ordinary),
            (false, recent, 1, 0, nil),
            (false, old, 6, 0, nil),
            (true, recent, 1, 0, .afterGrant),
            (true, recent, 6, 5, .afterGrant),
            (true, nil, 0, 0, .afterGrant),
            (true, old, 0, 6, .ordinary),
            (true, recent, 0, 6, nil),
            (true, old, 6, 6, nil),
            (true, old, 5, 7, .ordinary),
        ]
        for (owed, last, ordinary, grants, expected) in table {
            #expect(
                FollowUpSchedule.chargeToStart(
                    now: now,
                    last: last,
                    afterGrantOwed: owed,
                    startedToday: ordinary,
                    grantsStartedToday: grants
                ) == expected,
                "owed \(owed), last \(String(describing: last)), \(ordinary) ordinary, \(grants) sign-in"
            )
        }
    }

    @Test("A pass owed after a sign-in is held up by its own count and by nothing else")
    func afterGrantCap() {
        for started in 0...8 {
            #expect(
                FollowUpSchedule.mayStartAfterGrant(startedToday: started) == (started < 6),
                "\(started) started"
            )
        }
    }
}

@Suite("Follow-up next start")
struct FollowUpNextStartTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// 2026-11-15T17:12:00Z: 09:12 on Sunday in Los Angeles.
    private let now = Date(timeIntervalSince1970: 1_794_762_720)

    @Test("With nothing before it, a pass may start one delay from now")
    func firstPass() {
        #expect(
            FollowUpSchedule.nextStart(now: now, last: nil, startedToday: 0, calendar: calendar)
                == now.addingTimeInterval(60)
        )
    }

    @Test("A pass waits for the gap after the last one, and for the delay if that is later")
    func gapAfterLast() {
        for (minutesAgo, expected) in [(0.0, 600.0), (3, 420), (9, 60), (9.5, 60), (10, 60), (60, 60)] {
            let last = now.addingTimeInterval(-minutesAgo * 60)
            #expect(
                FollowUpSchedule.nextStart(now: now, last: last, startedToday: 1, calendar: calendar)
                    == now.addingTimeInterval(expected),
                "\(minutesAgo) minutes after the last"
            )
        }
    }

    @Test("A last start in the future is ignored")
    func lastInTheFuture() {
        #expect(
            FollowUpSchedule.nextStart(
                now: now,
                last: now.addingTimeInterval(7_200),
                startedToday: 1,
                calendar: calendar
            ) == now.addingTimeInterval(60)
        )
    }

    @Test("Once the day's passes are spent the next one waits for the next day plus the delay")
    func dayIsSpent() {
        // Midnight ending Sunday in Los Angeles is 08:00 UTC on the 16th.
        let nextMidnight = Date(timeIntervalSince1970: 1_794_762_720 + 14 * 3_600 + 48 * 60)

        for started in [6, 7, 20] {
            #expect(
                FollowUpSchedule.nextStart(now: now, last: nil, startedToday: started, calendar: calendar)
                    == nextMidnight.addingTimeInterval(60),
                "\(started) started"
            )
        }
        #expect(
            FollowUpSchedule.nextStart(now: now, last: nil, startedToday: 5, calendar: calendar)
                == now.addingTimeInterval(60)
        )
    }

    @Test("The day is the calendar's, so the same instant spends a different day elsewhere")
    func zoneDecidesTheDay() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // It is 02:12 on Monday in Tokyo, so the next day starts 21 hours 48 minutes later.
        let nextMidnight = now.addingTimeInterval(21 * 3_600 + 48 * 60)

        #expect(
            FollowUpSchedule.nextStart(now: now, last: nil, startedToday: 6, calendar: tokyo)
                == nextMidnight.addingTimeInterval(60)
        )
    }

    @Test("After a sign-in a pass starts five seconds on, whatever the gap or the ordinary count")
    func afterGrantSkipsDelayAndGap() {
        for (secondsAgo, ordinary) in [(0.0, 1), (30, 1), (599, 3), (86_400, 0), (0, 6), (60, 9)] {
            #expect(
                FollowUpSchedule.nextStartAfterGrant(
                    now: now,
                    last: now.addingTimeInterval(-secondsAgo),
                    startedToday: ordinary,
                    grantsStartedToday: 0,
                    calendar: calendar
                ) == now.addingTimeInterval(5),
                "\(secondsAgo) seconds after the last start, \(ordinary) ordinary today"
            )
        }
        #expect(
            FollowUpSchedule.nextStartAfterGrant(
                now: now, last: nil, startedToday: 0, grantsStartedToday: 5, calendar: calendar
            ) == now.addingTimeInterval(5)
        )
    }

    @Test("Past the day's sign-in passes the ordinary rules decide")
    func afterGrantFallsBack() {
        let recent = now.addingTimeInterval(-180)
        for grants in [6, 7, 20] {
            for (last, ordinary) in [(Date?.none, 0), (recent, 1), (recent, 6), (now.addingTimeInterval(7_200), 2)] {
                #expect(
                    FollowUpSchedule.nextStartAfterGrant(
                        now: now,
                        last: last,
                        startedToday: ordinary,
                        grantsStartedToday: grants,
                        calendar: calendar
                    ) == FollowUpSchedule.nextStart(
                        now: now,
                        last: last,
                        startedToday: ordinary,
                        calendar: calendar
                    ),
                    "\(grants) sign-in passes, \(ordinary) ordinary"
                )
            }
        }
        // 180 seconds after a start, the ordinary gap holds a pass for another 420.
        #expect(
            FollowUpSchedule.nextStartAfterGrant(
                now: now, last: recent, startedToday: 1, grantsStartedToday: 6, calendar: calendar
            ) == now.addingTimeInterval(420)
        )
    }

    @Test("The time it names is a time a pass may start, by the ledger's own count")
    func agreesWithMayStart() {
        var ledger = FollowUpLedger()
        var instant = now
        for _ in 0..<6 {
            ledger = ledger.recordingStart(now: instant, timeZone: calendar.timeZone)
            instant = instant.addingTimeInterval(700)
        }

        let start = FollowUpSchedule.nextStart(
            now: instant,
            last: ledger.last,
            startedToday: ledger.startedToday(now: instant, timeZone: calendar.timeZone),
            calendar: calendar
        )

        #expect(start > instant.addingTimeInterval(8 * 3_600))
        #expect(FollowUpSchedule.mayStart(
            now: start,
            last: ledger.last,
            startedToday: ledger.startedToday(now: start, timeZone: calendar.timeZone)
        ))
    }
}

@Suite("Local day")
struct LocalDayTests {
    @Test("A day is read from yyyy-MM-dd and nothing else, and only when it exists")
    func parsing() {
        #expect(LocalDay(parsing: "2026-11-16") == LocalDay(year: 2026, month: 11, day: 16))
        #expect(LocalDay(parsing: "2028-02-29") == LocalDay(year: 2028, month: 2, day: 29))
        for text in [
            "", "2026-11-16 ", " 2026-11-16", "2026-11-16\n", "2026-1-6", "26-11-16", "2026/11/16",
            "2026-13-01", "2026-00-10", "2026-11-00", "2026-11-31", "2027-02-29", "tomorrow",
            "2026-11-16T09:00", "١٤٤٧-٠١-٠١",
        ] {
            #expect(LocalDay(parsing: text) == nil, "\(text.debugDescription)")
        }
    }

    @Test("Days order by year, then month, then day")
    func ordering() {
        #expect(LocalDay(year: 2026, month: 11, day: 16) < LocalDay(year: 2026, month: 11, day: 17))
        #expect(LocalDay(year: 2026, month: 11, day: 30) < LocalDay(year: 2026, month: 12, day: 1))
        #expect(LocalDay(year: 2026, month: 12, day: 31) < LocalDay(year: 2027, month: 1, day: 1))
        #expect(!(LocalDay(year: 2026, month: 11, day: 16) < LocalDay(year: 2026, month: 11, day: 16)))
    }

    @Test("The day of an instant is the day in the given zone")
    func fromDate() {
        // 2026-11-15T17:12:00Z.
        let instant = Date(timeIntervalSince1970: 1_794_762_720)

        #expect(LocalDay(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
            == LocalDay(year: 2026, month: 11, day: 15))
        #expect(LocalDay(instant, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
            == LocalDay(year: 2026, month: 11, day: 16))
    }
}

@Suite("Follow-up ledger")
struct FollowUpLedgerTests {
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    /// 2026-11-15T17:12:00Z: Sunday morning in Los Angeles, Monday 02:12 in Tokyo.
    private let instant = Date(timeIntervalSince1970: 1_794_762_720)

    @Test("A new ledger has started nothing")
    func empty() {
        let ledger = FollowUpLedger()

        #expect(ledger.last == nil)
        #expect(ledger.startedToday(now: instant, timeZone: losAngeles) == 0)
    }

    @Test("Starts count within a day and begin again on the next")
    func countsPerLocalDay() {
        var ledger = FollowUpLedger()
        for minute in 0..<3 {
            ledger = ledger.recordingStart(now: instant.addingTimeInterval(TimeInterval(minute) * 700), timeZone: losAngeles)
        }

        #expect(ledger.startedToday(now: instant.addingTimeInterval(3_600), timeZone: losAngeles) == 3)
        #expect(ledger.last == instant.addingTimeInterval(1_400))

        let nextDay = instant.addingTimeInterval(86_400)
        #expect(ledger.startedToday(now: nextDay, timeZone: losAngeles) == 0)
        let restarted = ledger.recordingStart(now: nextDay, timeZone: losAngeles)
        #expect(restarted.startedToday(now: nextDay, timeZone: losAngeles) == 1)
        #expect(restarted.last == nextDay)
    }

    @Test("The day is the user's, not UTC's")
    func zoneDecidesTheDay() {
        let ledger = FollowUpLedger().recordingStart(now: instant, timeZone: losAngeles)

        // Fourteen hours later it is 23:12 on Sunday in Los Angeles, and already Monday in Tokyo.
        let later = instant.addingTimeInterval(14 * 3_600)
        #expect(ledger.startedToday(now: later, timeZone: losAngeles) == 1)
        #expect(ledger.startedToday(now: later, timeZone: tokyo) == 0)
        // Fifteen hours later it is Monday there too.
        #expect(ledger.startedToday(now: instant.addingTimeInterval(15 * 3_600), timeZone: losAngeles) == 0)
    }

    @Test("A ledger is kept across launches in the defaults it is saved to")
    func persistence() throws {
        let suite = "follow-up-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(FollowUpLedger(defaults: defaults) == FollowUpLedger())

        let ledger = FollowUpLedger()
            .recordingStart(now: instant, timeZone: losAngeles)
            .recordingStart(now: instant.addingTimeInterval(900), timeZone: losAngeles)
        ledger.save(to: defaults)

        let restored = FollowUpLedger(defaults: defaults)
        #expect(restored == ledger)
        #expect(restored.startedToday(now: instant, timeZone: losAngeles) == 2)
        #expect(restored.last == instant.addingTimeInterval(900))
    }

    @Test("Passes owed after a sign-in are counted apart from the others, and either moves the last start")
    func grantStartsAreCountedApart() {
        var ledger = FollowUpLedger()
        for minute in 0..<3 {
            ledger = ledger.recordingGrantStart(
                now: instant.addingTimeInterval(TimeInterval(minute) * 60),
                timeZone: losAngeles
            )
        }

        #expect(ledger.grantStartedToday(now: instant.addingTimeInterval(3_600), timeZone: losAngeles) == 3)
        #expect(ledger.startedToday(now: instant.addingTimeInterval(3_600), timeZone: losAngeles) == 0)
        #expect(ledger.last == instant.addingTimeInterval(120))

        let ordinary = ledger.recordingStart(now: instant.addingTimeInterval(900), timeZone: losAngeles)
        #expect(ordinary.startedToday(now: instant.addingTimeInterval(900), timeZone: losAngeles) == 1)
        #expect(ordinary.grantStartedToday(now: instant.addingTimeInterval(900), timeZone: losAngeles) == 3)
        #expect(ordinary.last == instant.addingTimeInterval(900))

        let sibling = ordinary.recordingGrantStart(now: instant.addingTimeInterval(960), timeZone: losAngeles)
        #expect(sibling.grantStartedToday(now: instant.addingTimeInterval(960), timeZone: losAngeles) == 4)
        #expect(sibling.startedToday(now: instant.addingTimeInterval(960), timeZone: losAngeles) == 1)
    }

    @Test("The sign-in count begins again on the next local day")
    func grantCountRestartsDaily() {
        let ledger = FollowUpLedger()
            .recordingGrantStart(now: instant, timeZone: losAngeles)
            .recordingGrantStart(now: instant.addingTimeInterval(60), timeZone: losAngeles)

        // Fourteen hours later it is still Sunday in Los Angeles, and already Monday in Tokyo.
        let later = instant.addingTimeInterval(14 * 3_600)
        #expect(ledger.grantStartedToday(now: later, timeZone: losAngeles) == 2)
        #expect(ledger.grantStartedToday(now: later, timeZone: tokyo) == 0)

        let nextDay = instant.addingTimeInterval(86_400)
        #expect(ledger.grantStartedToday(now: nextDay, timeZone: losAngeles) == 0)
        let restarted = ledger.recordingGrantStart(now: nextDay, timeZone: losAngeles)
        #expect(restarted.grantStartedToday(now: nextDay, timeZone: losAngeles) == 1)
    }

    @Test("Both counts are kept across launches, under keys of their own")
    func grantPersistence() throws {
        let suite = "follow-up-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let ledger = FollowUpLedger()
            .recordingStart(now: instant, timeZone: losAngeles)
            .recordingGrantStart(now: instant.addingTimeInterval(30), timeZone: losAngeles)
            .recordingGrantStart(now: instant.addingTimeInterval(90), timeZone: losAngeles)
        ledger.save(to: defaults)

        let restored = FollowUpLedger(defaults: defaults)
        #expect(restored == ledger)
        #expect(restored.startedToday(now: instant, timeZone: losAngeles) == 1)
        #expect(restored.grantStartedToday(now: instant, timeZone: losAngeles) == 2)
        #expect(restored.last == instant.addingTimeInterval(90))
        #expect(defaults.integer(forKey: "provisor.grantFollowUpCount") == 2)
        #expect(defaults.string(forKey: "provisor.grantFollowUpDay") == FollowUpLedger.day(of: instant, in: losAngeles))
    }

    @Test("A stored sign-in count that is negative reads as none")
    func hostileGrantDefaults() throws {
        let suite = "follow-up-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-3, forKey: "provisor.grantFollowUpCount")
        defaults.set(FollowUpLedger.day(of: instant, in: losAngeles), forKey: "provisor.grantFollowUpDay")

        #expect(FollowUpLedger(defaults: defaults).grantStartedToday(now: instant, timeZone: losAngeles) == 0)
    }

    @Test("A stored count that is negative reads as none")
    func hostileDefaults() throws {
        let suite = "follow-up-ledger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-40, forKey: "provisor.followUpCount")
        defaults.set(FollowUpLedger.day(of: instant, in: losAngeles), forKey: "provisor.followUpDay")

        #expect(FollowUpLedger(defaults: defaults).startedToday(now: instant, timeZone: losAngeles) == 0)
    }
}

@Suite("Due follow-up notes")
final class FollowUpNotesTests {
    private let folder: URL
    private let today = LocalDay(year: 2026, month: 11, day: 16)

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("followups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        try write(name, Data(contents.utf8))
    }

    @discardableResult
    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func isDue(_ contents: String) throws -> Bool {
        FollowUpNotes.isDue(try write("a.md", contents), on: today, readable: { _ in true })
    }

    private func isDue(head: [UInt8]) -> Bool {
        FollowUpNotes.isDue(head: Data(head), on: today, readable: { _ in true })
    }

    // MARK: The first line

    @Test("A note whose first line is Status: open is due, with its later lines left unread")
    func openNotes() throws {
        for contents in [
            "Status: open\nCheck that the card on file is the Amex.",
            "Status: open",
            "Status: open\r\nrest",
            "Status: open   \nrest",
            "\tStatus: open\t\nrest",
            "  Status: open\nrest",
            "Status: open\n" + String(repeating: "detail ", count: 5_000),
        ] {
            #expect(try isDue(contents), "\(contents.prefix(30).debugDescription)")
        }
    }

    @Test("Any other first line is not due, whatever comes after it")
    func notOpenNotes() throws {
        for contents in [
            "Status: settled\nStatus: open",
            "Status: settled\nCheck from: 2026-01-01",
            "Status: asked\n",
            "Status: opened\n",
            "Status: OPEN\n",
            "status: open\n",
            "Status:open\n",
            "Status: open now\n",
            "# Status: open\n",
            "\nStatus: open\n",
            "Notes\nStatus: open\n",
            "",
            "\n",
            String(repeating: "x", count: FollowUpNotes.headBytes + 4) + "\n",
            // A first line longer than what is read cannot be the status line.
            String(repeating: " ", count: FollowUpNotes.headBytes + 4) + "Status: open\n",
        ] {
            #expect(try !isDue(contents), "\(contents.prefix(30).debugDescription)")
        }
    }

    // MARK: The check date

    @Test("An open note with no second line, or one that is not a date, is due")
    func missingOrUnreadableDate() throws {
        for contents in [
            "Status: open",
            "Status: open\n",
            "Status: open\n\nCheck from: 2099-01-01",
            "Status: open\nWhat to check: the card",
            "Status: open\nCheck from:",
            "Status: open\nCheck from: ",
            "Status: open\nCheck from: soon",
            "Status: open\nCheck from: 2099-13-45",
            "Status: open\nCheck from: 2099-02-30",
            "Status: open\nCheck from: 11/16/2099",
            "Status: open\nCheck from 2099-01-01",
            "Status: open\ncheck from: 2099-01-01",
            "Status: open\nCheck from: 2099-01-01 or later",
            "Status: open\n\u{1B}[0mCheck from: 2099-01-01",
        ] {
            #expect(try isDue(contents), "\(contents.debugDescription)")
        }
    }

    @Test("A date after today holds the note back, and today or an earlier day does not")
    func datedNotes() throws {
        for (date, due) in [
            ("2026-11-17", false), ("2026-12-01", false), ("2027-01-01", false), ("2099-12-31", false),
            ("2026-11-16", true), ("2026-11-15", true), ("2026-01-01", true), ("2025-12-31", true),
            ("2026-10-31", true),
        ] {
            #expect(try isDue("Status: open\nCheck from: \(date)\nWhat to check.") == due, "\(date)")
        }
    }

    @Test("The date may be indented, spaced after the colon or not, and end the line any way")
    func dateSpelling() throws {
        for contents in [
            "Status: open\nCheck from:2099-01-01",
            "Status: open\nCheck from:   2099-01-01   ",
            "Status: open\r\n\tCheck from: 2099-01-01\r\nrest",
            "Status: open\rCheck from: 2099-01-01\rrest",
            "Status: open\n  Check from: 2099-01-01",
        ] {
            #expect(try !isDue(contents), "\(contents.debugDescription)")
        }
    }

    @Test("A leading byte-order mark is not part of the first line")
    func byteOrderMark() {
        let mark: [UInt8] = [0xEF, 0xBB, 0xBF]

        #expect(isDue(head: mark + Array("Status: open\nCheck from: 2026-11-16\n".utf8)))
        #expect(isDue(head: mark + Array("Status: open".utf8)))
        #expect(!isDue(head: mark + Array("Status: open\nCheck from: 2026-11-17\n".utf8)))
        #expect(!isDue(head: mark + Array("Status: settled\n".utf8)))
        // Only the very first scalar is a mark.
        #expect(!isDue(head: mark + mark + Array("Status: open\n".utf8)))
    }

    @Test("Only the first bytes are read, so a date cut off by them reads as no date")
    func headIsBounded() throws {
        // The first line fills the read, leaving nothing of the second.
        let long = "Status: open" + String(repeating: " ", count: FollowUpNotes.headBytes - 12)
        #expect(long.utf8.count == FollowUpNotes.headBytes)
        #expect(try isDue(long + "\nCheck from: 2099-01-01\n"))

        // The second line begins in the read and is cut inside its date, so it is not a date.
        let cut = "Status: open\n" + String(repeating: " ", count: FollowUpNotes.headBytes - 27) + "Check from: 2099-01-01"
        #expect(try isDue(cut))
        // With less before it, the whole date is read and holds the note back.
        let whole = "Status: open\n" + String(repeating: " ", count: 200) + "Check from: 2099-01-01"
        #expect(try !isDue(whole))
    }

    // MARK: A note that waits on a site

    private func isDue(_ contents: String, readable: @escaping (String) -> Bool) throws -> Bool {
        FollowUpNotes.isDue(try write("a.md", contents), on: today, readable: readable)
    }

    private let waiting = "Status: open\nCheck from: 2026-11-16\nWaits on: example.com\nCheck the receipt."

    @Test("A note that waits on a site is due while the site can be read, and not while it cannot")
    func waitsOnReadability() throws {
        var asked: [String] = []

        #expect(try isDue(waiting, readable: { asked.append($0); return true }))
        #expect(try !isDue(waiting, readable: { asked.append($0); return false }))
        #expect(asked == ["example.com", "example.com"])
    }

    @Test("A note's date still holds it back when the site it waits on can be read")
    func dateStillApplies() throws {
        #expect(try !isDue(
            "Status: open\nCheck from: 2026-11-17\nWaits on: example.com",
            readable: { _ in true }
        ))
        #expect(try !isDue("Status: settled\nCheck from: 2026-11-16\nWaits on: example.com", readable: { _ in true }))
    }

    @Test("A note without the line is due as before, and readability is never asked")
    func noWaitsOnLine() throws {
        for contents in [
            "Status: open",
            "Status: open\nCheck from: 2026-11-16",
            "Status: open\nCheck from: 2026-11-16\nCheck the receipt.",
            "Status: open\nCheck from: 2026-11-16\n\nWaits on: example.com",
            "Status: open\nWaits on: example.com",
            "Status: open\nCheck from: 2026-11-16\nnotes\nWaits on: example.com",
        ] {
            var asked = false
            #expect(try isDue(contents, readable: { _ in asked = true; return false }), "\(contents.debugDescription)")
            #expect(!asked, "\(contents.debugDescription)")
        }
    }

    @Test("A value that is not a lowercase host name is no line at all, so the note is due")
    func invalidHostIsIgnored() throws {
        for value in [
            "", "   ", "Example.com", "EXAMPLE.COM", "example", "example..com", "-example.com", "example-.com",
            "exa mple.com", "https://example.com", "example.com/account", "example.com:443", "example.com.",
            "user@example.com", "exampl\u{0435}.com", "\u{FF45}xample.com", "example.com, other.example.org",
            "127.0.0.1", String(repeating: "a", count: 254) + ".com",
        ] {
            #expect(try isDue("Status: open\nCheck from: 2026-11-16\nWaits on: \(value)", readable: { _ in false }), "\(value.debugDescription)")
        }
    }

    @Test("The host may be spaced after the colon or not, indented, and end the line any way")
    func waitsOnSpelling() throws {
        for contents in [
            "Status: open\nCheck from: 2026-11-16\nWaits on:example.com",
            "Status: open\nCheck from: 2026-11-16\nWaits on:   example.com   ",
            "Status: open\r\nCheck from: 2026-11-16\r\n\tWaits on: example.com\r\nrest",
            "Status: open\rCheck from: 2026-11-16\rWaits on: example.com\rrest",
            "Status: open\nCheck from: 2026-11-16\nWaits on: example.com",
        ] {
            #expect(try !isDue(contents, readable: { _ in false }), "\(contents.debugDescription)")
            #expect(try isDue(contents, readable: { _ in true }), "\(contents.debugDescription)")
        }
    }

    @Test("A third line is read even when the second is not a date, and the longest host name still fits the read")
    func waitsOnRegardlessOfTheSecondLine() throws {
        #expect(try !isDue("Status: open\nsoon\nWaits on: example.com", readable: { _ in false }))

        let longest = [String(repeating: "a", count: 63), String(repeating: "b", count: 63),
                       String(repeating: "c", count: 63), String(repeating: "d", count: 61)].joined(separator: ".")
        #expect(longest.utf8.count == 253)
        #expect(SiteHost.isValid(longest))
        var asked: [String] = []
        #expect(try !isDue(
            "Status: open\nCheck from: 2026-11-16\nWaits on: \(longest)\nrest",
            readable: { asked.append($0); return false }
        ))
        #expect(asked == [longest])
    }

    @Test("The folder holds a due note unless every note that is due waits on a site that cannot be read")
    func folderLookupWithReadability() throws {
        try write("a.md", waiting)
        #expect(FollowUpNotes.hasDueNote(in: folder, on: today, readable: { $0 == "example.com" }))
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in false }))

        try write("b.md", "Status: open\nCheck from: 2026-11-16\nWaits on: other.example.org")
        #expect(FollowUpNotes.hasDueNote(in: folder, on: today, readable: { $0 == "other.example.org" }))
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in false }))

        try write("c.md", "Status: open\nCheck from: 2026-11-16\nCheck the receipt.")
        #expect(FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in false }))
    }

    @Test("A site can be read when it is granted, not flagged, and not awaiting the person")
    func siteReadability() {
        func record(_ id: String, needsPerson: Bool = false) -> SiteRecord {
            var record = SiteRecord(id: id, name: id, added: Date(timeIntervalSince1970: 1_700_000_000))
            record.needsPerson = needsPerson
            return record
        }
        let granted = [record("example.com"), record("flagged.example.org", needsPerson: true), record("awaited.example.net")]
        let awaiting: Set<String> = ["awaited.example.net"]

        #expect(FollowUpNotes.isReadable("example.com", granted: granted, awaiting: awaiting))
        #expect(!FollowUpNotes.isReadable("flagged.example.org", granted: granted, awaiting: awaiting))
        #expect(!FollowUpNotes.isReadable("awaited.example.net", granted: granted, awaiting: awaiting))
        #expect(!FollowUpNotes.isReadable("unknown.example.io", granted: granted, awaiting: awaiting))
        #expect(!FollowUpNotes.isReadable("example.com", granted: [], awaiting: []))
        #expect(FollowUpNotes.isReadable("example.com", granted: granted, awaiting: ["other.example.io"]))
    }

    // MARK: Which files count

    @Test("Only a regular file named *.md counts")
    func fileNames() throws {
        for name in ["a.md", "2026-11-15-cancel-foo.md", "x.y.md"] {
            #expect(FollowUpNotes.isDue(try write(name, "Status: open\n"), on: today, readable: { _ in true }), "\(name)")
        }
        for name in ["a.txt", "a", "a.md.txt", "a.MD", "a.markdown", ".hidden"] {
            #expect(!FollowUpNotes.isDue(try write(name, "Status: open\n"), on: today, readable: { _ in true }), "\(name)")
        }
        #expect(!FollowUpNotes.isDue(folder.appendingPathComponent("missing.md"), on: today, readable: { _ in true }))
    }

    @Test("A symbolic link is never read, even to a due note")
    func symlink() throws {
        let target = try write("target.txt", "Status: open\n")
        let link = folder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(!FollowUpNotes.isDue(link, on: today, readable: { _ in true }))
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in true }))
    }

    @Test("A directory or a named pipe called *.md is not a note, and does not hold the look up", .timeLimit(.minutes(1)))
    func notRegularFiles() throws {
        let directory = folder.appendingPathComponent("dir.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pipe = folder.appendingPathComponent("pipe.md")
        #expect(mkfifo(pipe.path, 0o600) == 0)

        #expect(!FollowUpNotes.isDue(directory, on: today, readable: { _ in true }))
        #expect(!FollowUpNotes.isDue(pipe, on: today, readable: { _ in true }))
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in true }))
    }

    @Test("A note over 64 KiB is not read")
    func size() throws {
        let head = Data("Status: open\n".utf8)
        let limit = FollowUpNotes.maximumNoteBytes

        let atLimit = head + Data(repeating: UInt8(ascii: "a"), count: limit - head.count)
        let over = head + Data(repeating: UInt8(ascii: "a"), count: limit - head.count + 1)

        #expect(atLimit.count == limit)
        #expect(FollowUpNotes.isDue(try write("at.md", atLimit), on: today, readable: { _ in true }))
        #expect(!FollowUpNotes.isDue(try write("over.md", over), on: today, readable: { _ in true }))
    }

    @Test("The folder holds a due note when any one is due")
    func folderLookup() throws {
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in true }))
        #expect(!FollowUpNotes.hasDueNote(in: folder.appendingPathComponent("missing"), on: today, readable: { _ in true }))

        try write("a.md", "Status: settled\nevidence")
        try write("b.md", "Status: asked\n")
        try write("c.txt", "Status: open\n")
        try write("d.md", "Status: open\nCheck from: 2026-11-20\nNot yet.")
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in true }))

        try write("e.md", "Status: open\nCheck from: 2026-11-16\nCheck the receipt.")
        #expect(FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in true }))
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: LocalDay(year: 2026, month: 11, day: 15), readable: { _ in true }))
        #expect(FollowUpNotes.hasDueNote(in: folder, on: LocalDay(year: 2026, month: 11, day: 20), readable: { _ in true }))

        try write("e.md", "Status: settled\nSettled on 2026-11-20.")
        #expect(!FollowUpNotes.hasDueNote(in: folder, on: today, readable: { _ in true }))
    }
}
