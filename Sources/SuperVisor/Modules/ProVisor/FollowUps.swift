import Darwin
import Foundation

/// When a follow-up pass may start: soon after a check is owed, and not so often that it spends
/// the user's quota.
///
/// A pass owed because the person just signed in to a site keeps to a schedule of its own
/// (`mayStartAfterGrant`, `nextStartAfterGrant`): it starts within seconds, since the check it
/// makes is the one that was waiting on that sign-in, and its daily count is kept apart from
/// the passes that notes owe.
enum FollowUpSchedule {
    /// The schedule a starting pass keeps to, and the daily count it is charged to.
    enum Charge: Equatable {
        /// The pass is owed for a sign-in, within that count's limit.
        case afterGrant
        /// Any other pass, or one owed for a sign-in once that count's limit is spent.
        case ordinary
    }

    /// The shortest wait before a pass owed now may start.
    static let delay: TimeInterval = 60
    /// The shortest time between the starts of two passes.
    static let minimumGap: TimeInterval = 10 * 60
    /// The most passes that start on one local day.
    static let perDay = 6
    /// The wait before a pass owed after a sign-in may start.
    static let grantDelay: TimeInterval = 5
    /// The most passes owed after a sign-in that start on one local day.
    static let grantsPerDay = 6

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

    /// How a pass is scheduled and counted: after a sign-in when one owes it and fewer than
    /// `grantsPerDay` such passes have started today, and as an ordinary pass otherwise.
    static func charge(afterGrantOwed: Bool, grantsStartedToday: Int) -> Charge {
        afterGrantOwed && mayStartAfterGrant(startedToday: grantsStartedToday) ? .afterGrant : .ordinary
    }

    /// The charge of a pass that starts at `now`, or nil when it may not start yet: a pass owed
    /// after a sign-in within its count starts at once, and any other waits for `mayStart`.
    /// `startedToday` counts the ordinary passes started today and `grantsStartedToday` those
    /// owed after a sign-in.
    static func chargeToStart(
        now: Date,
        last: Date?,
        afterGrantOwed: Bool,
        startedToday: Int,
        grantsStartedToday: Int
    ) -> Charge? {
        let charge = charge(afterGrantOwed: afterGrantOwed, grantsStartedToday: grantsStartedToday)
        guard charge == .afterGrant || mayStart(now: now, last: last, startedToday: startedToday) else {
            return nil
        }
        return charge
    }

    /// A pass owed after a sign-in may start while fewer than `grantsPerDay` such passes have
    /// started today. The gap between passes does not apply.
    static func mayStartAfterGrant(startedToday: Int) -> Bool {
        startedToday < grantsPerDay
    }

    /// The earliest time a pass owed after a sign-in from `now` may start: `grantDelay` after
    /// `now` while fewer than `grantsPerDay` such passes have started today, and otherwise the
    /// time `nextStart` gives a pass owed for any other reason. `grantsStartedToday` counts
    /// the passes started after a sign-in, `startedToday` the others.
    static func nextStartAfterGrant(
        now: Date,
        last: Date?,
        startedToday: Int,
        grantsStartedToday: Int,
        calendar: Calendar
    ) -> Date {
        guard mayStartAfterGrant(startedToday: grantsStartedToday) else {
            return nextStart(now: now, last: last, startedToday: startedToday, calendar: calendar)
        }
        return now.addingTimeInterval(grantDelay)
    }
}

/// Whether a follow-up pass is owed: for a note that is due, or once after the user signed in
/// to a site that something was waiting on, so the check waiting on that site is made with it.
/// The sites signed in to are held until a pass starts, which answers them all.
struct FollowUpDemand: Equatable {
    private var signedIn: Set<String> = []

    /// The ids of the sites signed in to since the last pass started, sorted.
    var justSignedIn: [String] { signedIn.sorted() }

    /// Whether a pass is owed for a sign-in, whatever the notes say.
    var isOwedAfterGrant: Bool { !signedIn.isEmpty }

    func isOwed(hasDueNote: Bool) -> Bool {
        hasDueNote || isOwedAfterGrant
    }

    mutating func requestAfterGrant(site id: String) {
        signedIn.insert(id)
    }

    /// A pass started and was told about the sites in `told`, which it answers. A site signed in
    /// to after that list was made stays owed.
    mutating func passStarted(told: [String]) {
        signedIn.subtract(told)
    }
}

/// Holds that keep follow-up passes from starting, counted, so that each holder lifts only its
/// own. A pass owed while any hold stands waits for the last to be lifted.
///
/// The sign-in window holds them while it offers to keep a password, and only then: keeping it
/// saves the site again, and a save closes every visit open on the site, which would cut off a
/// pass already reading it.
struct FollowUpHolds: Equatable {
    struct Token: Hashable, Sendable {
        fileprivate let id: Int
    }

    private var held: Set<Int> = []
    private var next = 0

    var isHeld: Bool { !held.isEmpty }

    mutating func take() -> Token {
        next += 1
        held.insert(next)
        return Token(id: next)
    }

    /// Lifts the hold `token` names, and returns whether that lifted the last one. A token
    /// already released, or released by `releaseAll`, lifts nothing.
    @discardableResult
    mutating func release(_ token: Token) -> Bool {
        guard held.remove(token.id) != nil else { return false }
        return held.isEmpty
    }

    /// Lifts every hold. Tokens taken before it lift nothing afterwards.
    mutating func releaseAll() {
        held.removeAll()
    }
}

/// What can hold follow-up passes back (`FollowUpHolds`).
@MainActor
protocol FollowUpHolding: AnyObject {
    func holdFollowUps() -> FollowUpHolds.Token
    func releaseFollowUps(_ token: FollowUpHolds.Token)
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

    /// The moment the day begins in `timeZone`.
    func start(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// How many follow-up passes started on the current local day, and when the last one did.
/// Passes owed after a sign-in are counted apart from those a note owes, and either kind moves
/// the time of the last start.
struct FollowUpLedger: Equatable {
    private(set) var last: Date?
    private var day: String?
    private var count = 0
    private var grantDay: String?
    private var grantCount = 0

    private enum Key {
        static let last = "provisor.lastFollowUpAt"
        static let day = "provisor.followUpDay"
        static let count = "provisor.followUpCount"
        static let grantDay = "provisor.grantFollowUpDay"
        static let grantCount = "provisor.grantFollowUpCount"
    }

    init() {}

    init(defaults: UserDefaults) {
        let stored = defaults.double(forKey: Key.last)
        last = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        day = defaults.string(forKey: Key.day)
        count = max(0, defaults.integer(forKey: Key.count))
        grantDay = defaults.string(forKey: Key.grantDay)
        grantCount = max(0, defaults.integer(forKey: Key.grantCount))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(last?.timeIntervalSince1970 ?? 0, forKey: Key.last)
        defaults.set(day, forKey: Key.day)
        defaults.set(count, forKey: Key.count)
        defaults.set(grantDay, forKey: Key.grantDay)
        defaults.set(grantCount, forKey: Key.grantCount)
    }

    func startedToday(now: Date, timeZone: TimeZone) -> Int {
        day == Self.day(of: now, in: timeZone) ? count : 0
    }

    /// How many passes owed after a sign-in started on the local day of `now`.
    func grantStartedToday(now: Date, timeZone: TimeZone) -> Int {
        grantDay == Self.day(of: now, in: timeZone) ? grantCount : 0
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

    /// The ledger after a pass owed after a sign-in starts at `now`. The first such start of a
    /// new day restarts that count.
    func recordingGrantStart(now: Date, timeZone: TimeZone) -> FollowUpLedger {
        var updated = self
        let today = Self.day(of: now, in: timeZone)
        if updated.grantDay != today {
            updated.grantDay = today
            updated.grantCount = 0
        }
        updated.grantCount += 1
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
/// A note is the agent's own file, so the app reads three things from its first lines: that the
/// first says `Status: open`, the date on the second, `Check from: yyyy-MM-dd`, the first day
/// the check can be made, and on the third, when the check needs a site's pages,
/// `Waits on: <host>`. Nothing else in a note is read, and nothing in it is acted on.
enum FollowUpNotes {
    static let openLine = "Status: open"
    static let checkFromPrefix = "Check from:"
    static let waitsOnPrefix = "Waits on:"
    /// A larger note is not read.
    static let maximumNoteBytes = 64 << 10
    /// How much of a note is read: all three lines have to fit, the third holding a host name
    /// of up to 253 bytes.
    static let headBytes = 512
    /// The most directory entries examined in one look.
    static let maximumEntries = 1_000

    /// Whether the site named by a note's `Waits on:` line can be read now: it is a granted
    /// site that is not flagged as needing the person and that no run was turned away from
    /// since they last signed in (`awaiting`).
    static func isReadable(_ host: String, granted: [SiteRecord], awaiting: Set<String>) -> Bool {
        guard let site = granted.first(where: { $0.id == host }) else { return false }
        return !site.needsPerson && !awaiting.contains(host)
    }

    /// Whether `folder` holds a note that is open and due on `today`. A note that waits on a
    /// site is due only while `readable` says the site can be read.
    static func hasDueNote(in folder: URL, on today: LocalDay, readable: (String) -> Bool) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.prefix(maximumEntries).contains {
            isDue(folder.appendingPathComponent($0, isDirectory: false), on: today, readable: readable)
        }
    }

    /// Whether the file at `url` is an open note that is due on `today`: a regular file, not a
    /// symbolic link, named `*.md`, no larger than `maximumNoteBytes`, whose beginning
    /// satisfies `isDue(head:on:readable:)`.
    static func isDue(_ url: URL, on today: LocalDay, readable: (String) -> Bool) -> Bool {
        guard let head = head(of: url) else { return false }
        return isDue(head: head, on: today, readable: readable)
    }

    /// Whether the first bytes of a note say it is open and due on `today`: after a leading
    /// byte-order mark, the first line is `Status: open` once trimmed, the second line is not a
    /// `Check from:` date after `today`, and a third line of `Waits on:` and a host name does
    /// not name a site that `readable` refuses. A second line that is missing, is something
    /// else, or holds a date that cannot be read leaves the note due, and so does a third line
    /// that is missing, is something else, or holds anything but a lowercase host name.
    static func isDue(head: Data, on today: LocalDay, readable: (String) -> Bool) -> Bool {
        let scalars = String(decoding: head, as: UTF8.self).unicodeScalars
        let text = scalars.first == "\u{FEFF}" ? String(scalars.dropFirst()) : String(scalars)
        let lines = text.split(maxSplits: 3, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == openLine
        else { return false }

        if lines.count > 1 {
            let second = lines[1].trimmingCharacters(in: .whitespaces)
            if second.hasPrefix(checkFromPrefix),
               let day = LocalDay(
                   parsing: second.dropFirst(checkFromPrefix.count).trimmingCharacters(in: .whitespaces)
               ),
               day > today {
                return false
            }
        }
        if lines.count > 2, let host = waitedOnHost(lines[2]) {
            return readable(host)
        }
        return true
    }

    /// The host a note's third line says it waits on: `Waits on:` and a name that is a valid
    /// host, in lowercase ASCII. Nil for any other line.
    private static func waitedOnHost(_ line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(waitsOnPrefix) else { return nil }
        let host = trimmed.dropFirst(waitsOnPrefix.count).trimmingCharacters(in: .whitespaces)
        return SiteHost.isValid(host) ? host : nil
    }

    /// The first `headBytes` of a note that is a regular file named `*.md`, not a symbolic
    /// link, and within `maximumNoteBytes`.
    static func head(of url: URL) -> Data? {
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
