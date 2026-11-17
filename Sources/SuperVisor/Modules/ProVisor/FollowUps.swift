import Darwin
import Foundation

/// When a follow-up pass may start: soon after a check is owed, and not so often that it spends
/// the user's quota.
enum FollowUpSchedule {
    /// The shortest wait before a pass owed now may start.
    static let delay: TimeInterval = 60
    /// The shortest time between the starts of two passes.
    static let minimumGap: TimeInterval = 10 * 60
    /// The most passes that start on one local day.
    static let perDay = 6

    /// A pass may start when fewer than `perDay` have started today and `minimumGap` has passed
    /// since the last one. A last start in the future, which a clock set back leaves behind,
    /// never holds a pass up.
    static func mayStart(now: Date, last: Date?, startedToday: Int) -> Bool {
        guard startedToday < perDay else { return false }
        guard let last, last <= now else { return true }
        return now.timeIntervalSince(last) >= minimumGap
    }

    /// The earliest time a pass owed from `now` may start: `delay` after `now`, `minimumGap`
    /// after the last start, and, once `perDay` have started today, `delay` after the start of
    /// the next day in `calendar`.
    static func nextStart(
        now: Date,
        last: Date?,
        startedToday: Int,
        calendar: Calendar
    ) -> Date {
        var earliest = now.addingTimeInterval(delay)
        if let last, last <= now {
            earliest = max(earliest, last.addingTimeInterval(minimumGap))
        }
        if startedToday >= perDay,
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            earliest = max(earliest, tomorrow.addingTimeInterval(delay))
        }
        return earliest
    }
}

/// Whether a follow-up pass is owed: for a note that is due, or once after the user granted a
/// site a proposal asked for, so the check waiting on that site is made with it. One request
/// is held at a time, and starting a pass answers it.
struct FollowUpDemand: Equatable {
    private(set) var siteGranted = false

    func isOwed(hasDueNote: Bool) -> Bool {
        hasDueNote || siteGranted
    }

    mutating func requestAfterGrant() {
        siteGranted = true
    }

    mutating func passStarted() {
        siteGranted = false
    }
}

/// A calendar day in the user's time zone.
struct LocalDay: Comparable, Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `timeZone`.
    init(_ date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    /// The day written `yyyy-MM-dd`; nil when the text is anything else, or names a day that
    /// does not exist.
    init?(parsing text: String) {
        guard let match = text.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts),
              calendar.dateComponents([.year, .month, .day], from: date) == parts
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// How many follow-up passes started on the current local day, and when the last one did.
struct FollowUpLedger: Equatable {
    private(set) var last: Date?
    private var day: String?
    private var count = 0

    private enum Key {
        static let last = "provisor.lastFollowUpAt"
        static let day = "provisor.followUpDay"
        static let count = "provisor.followUpCount"
    }

    init() {}

    init(defaults: UserDefaults) {
        let stored = defaults.double(forKey: Key.last)
        last = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        day = defaults.string(forKey: Key.day)
        count = max(0, defaults.integer(forKey: Key.count))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(last?.timeIntervalSince1970 ?? 0, forKey: Key.last)
        defaults.set(day, forKey: Key.day)
        defaults.set(count, forKey: Key.count)
    }

    func startedToday(now: Date, timeZone: TimeZone) -> Int {
        day == Self.day(of: now, in: timeZone) ? count : 0
    }

    /// The ledger after a pass starts at `now`. The first start of a new day restarts the count.
    func recordingStart(now: Date, timeZone: TimeZone) -> FollowUpLedger {
        var updated = self
        let today = Self.day(of: now, in: timeZone)
        if updated.day != today {
            updated.day = today
            updated.count = 0
        }
        updated.count += 1
        updated.last = now
        return updated
    }

    /// `yyyy-MM-dd` for the calendar day `date` falls on in `timeZone`.
    static func day(of date: Date, in timeZone: TimeZone) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }
}

/// The notes in `followups/` that owe a check today.
///
/// A note is the agent's own file, so the app reads two things from its first lines: that the
/// first says `Status: open`, and the date on the second, `Check from: yyyy-MM-dd`, the first
/// day the check can be made. Nothing else in a note is read, and nothing in it is acted on.
enum FollowUpNotes {
    static let openLine = "Status: open"
    static let checkFromPrefix = "Check from:"
    /// A larger note is not read.
    static let maximumNoteBytes = 64 << 10
    /// How much of a note is read: both lines have to fit.
    static let headBytes = 256
    /// The most directory entries examined in one look.
    static let maximumEntries = 1_000

    /// Whether `folder` holds a note that is open and due on `today`.
    static func hasDueNote(in folder: URL, on today: LocalDay) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.prefix(maximumEntries).contains {
            isDue(folder.appendingPathComponent($0, isDirectory: false), on: today)
        }
    }

    /// Whether the file at `url` is an open note that is due on `today`: a regular file, not a
    /// symbolic link, named `*.md`, no larger than `maximumNoteBytes`, whose beginning
    /// satisfies `isDue(head:on:)`.
    static func isDue(_ url: URL, on today: LocalDay) -> Bool {
        guard let head = head(of: url) else { return false }
        return isDue(head: head, on: today)
    }

    /// Whether the first bytes of a note say it is open and due on `today`: after a leading
    /// byte-order mark, the first line is `Status: open` once trimmed, and the second line is
    /// not a `Check from:` date after `today`. A second line that is missing, is something
    /// else, or holds a date that cannot be read leaves the note due.
    static func isDue(head: Data, on today: LocalDay) -> Bool {
        let scalars = String(decoding: head, as: UTF8.self).unicodeScalars
        let text = scalars.first == "\u{FEFF}" ? String(scalars.dropFirst()) : String(scalars)
        let lines = text.split(maxSplits: 2, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == openLine
        else { return false }

        guard lines.count > 1 else { return true }
        let second = lines[1].trimmingCharacters(in: .whitespaces)
        guard second.hasPrefix(checkFromPrefix),
              let day = LocalDay(
                  parsing: second.dropFirst(checkFromPrefix.count).trimmingCharacters(in: .whitespaces)
              )
        else { return true }
        return day <= today
    }

    /// The first `headBytes` of a note that is a regular file named `*.md`, not a symbolic
    /// link, and within `maximumNoteBytes`.
    private static func head(of url: URL) -> Data? {
        guard url.pathExtension == "md" else { return nil }
        // O_NOFOLLOW refuses a symbolic link, and O_NONBLOCK keeps a named pipe from holding
        // the open.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumNoteBytes
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: headBytes)
        let count = read(descriptor, &buffer, buffer.count)
        return count > 0 ? Data(buffer[0..<count]) : nil
    }
}
