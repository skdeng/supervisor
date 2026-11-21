import Foundation

/// Reads a person's Instagram chats out of the GraphQL response texts their inbox page received.
///
/// The page's queries, and the paths of the records in their answers, vary, so records are found
/// by shape wherever they sit: a chat record carries a `thread_key`, and a message list without
/// one carries `slide_messages.edges`. Every value is page-controlled, so shapes are checked,
/// sizes are bounded, and nothing here traps on odd input.
enum InstagramInboxParser {
    struct Report: Equatable, Sendable {
        /// JSON documents that parsed.
        var documents = 0
        /// Response texts with no parsable document.
        var unreadableResponses = 0
        /// Distinct chat records carrying an acceptable thread key.
        var threadsListed = 0
        /// Listed chats dropped because their folder is missing or not accepted.
        var threadsOutsideFolders = 0
        /// Message lists that matched no kept chat.
        var detailsUnmatched = 0
        /// Messages in the returned threads.
        var messages = 0
        /// The walk reached `maximumVisitedNodes` and stopped, so later responses went unread.
        var stoppedEarly = false
    }

    static let acceptedFolders: Set<String> = ["PRIMARY", "GENERAL"]
    static let maximumThreads = 50
    static let maximumMessagesPerThread = 50

    /// Nesting levels walked below a document's root.
    static let maximumDepth = 40
    /// Values visited across the whole parse, message edges included.
    static let maximumVisitedNodes = 400_000
    /// Users, read receipts, and learned user names kept per chat record or per parse.
    static let maximumListedEntries = 200
    static let maximumKnownUsers = 50_000

    /// The chats found in `responses`, newest activity first, and what the parse saw.
    static func parse(
        _ responses: [String],
        now: Date
    ) -> (threads: [DirectMessageThread], report: Report) {
        var collector = Collector(window: TimeWindow(now: now))
        var documentCount = 0
        var unreadable = 0
        for response in responses {
            let documents = ResponseText.documents(in: response)
            if documents.isEmpty {
                unreadable += 1
                continue
            }
            documentCount += documents.count
            for document in documents {
                collector.walk(document, depth: 0)
            }
        }
        var result = collector.finish()
        result.report.documents = documentCount
        result.report.unreadableResponses = unreadable
        return result
    }
}

// MARK: - Response text

private enum ResponseText {
    static let guardPrefix = "for (;;);"

    /// The JSON documents in a response: the whole text as one document, else each non-empty
    /// line as its own (deferred responses arrive as several newline-separated objects).
    static func documents(in response: String) -> [Any] {
        let text = withoutGuardPrefix(response)
        if let whole = document(text) { return [whole] }
        return text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { document(withoutGuardPrefix(String(String.UnicodeScalarView($0)))) }
    }

    private static func withoutGuardPrefix(_ text: String) -> String {
        let trimmed = text.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix(guardPrefix) else { return text }
        return String(trimmed.dropFirst(guardPrefix.count))
    }

    private static func document(_ text: String) -> Any? {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return nil }
        return parsed is [String: Any] || parsed is [Any] ? parsed : nil
    }
}

// MARK: - Values

/// Typed reads of values whose JSON type is the page's to choose.
private enum Field {
    /// The text of an id given as a non-empty string or an integer number.
    static func identifierText(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            return text.isEmpty ? nil : text
        case let number as NSNumber:
            guard !isBoolean(number), !CFNumberIsFloatType(number as CFNumber) else { return nil }
            return number.stringValue
        default:
            return nil
        }
    }

    /// An id passing `isAcceptableID`.
    static func id(_ value: Any?) -> String? {
        guard let text = identifierText(value), isAcceptableID(text) else { return nil }
        return text
    }

    /// 1 to 128 ASCII letters, digits, and the characters `:_.=-$`. An id is only ever compared
    /// and stored, so the set is the characters the source's ids are known to use.
    static func isAcceptableID(_ text: String) -> Bool {
        let bytes = text.utf8
        guard (1...128).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: ":"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "="),
                 UInt8(ascii: "-"), UInt8(ascii: "$"):
                true
            default:
                false
            }
        }
    }

    /// A JSON `true` or `false`; the numbers 0 and 1 are not booleans.
    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// A user name passing `DirectMessageThread.isUsername`.
    static func username(_ value: Any?) -> String? {
        guard let text = value as? String, text.utf8.count <= 30,
              DirectMessageThread.isUsername(text)
        else { return nil }
        return text
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// The span of milliseconds-since-1970 values a timestamp may take.
private struct TimeWindow {
    private static let earliestMilliseconds = 1_262_304_000_000.0
    private static let slackSeconds = 86_400.0

    private let latestMilliseconds: Double

    init(now: Date) {
        latestMilliseconds = (now.timeIntervalSince1970 + Self.slackSeconds) * 1_000
    }

    /// The date of a millisecond timestamp given as a number or a numeric string, when it lies
    /// from 2010-01-01 through one day past `now`.
    func date(_ value: Any?) -> Date? {
        let milliseconds: Double
        switch value {
        case let text as String:
            guard text.utf8.count <= 32,
                  let parsed = Double(text.trimmingCharacters(in: .whitespaces))
            else { return nil }
            milliseconds = parsed
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            milliseconds = number.doubleValue
        default:
            return nil
        }
        guard milliseconds >= Self.earliestMilliseconds, milliseconds <= latestMilliseconds else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

// MARK: - Drafts

private struct UserEntry {
    let ids: [String]
    let username: String?

    func matches(_ other: UserEntry) -> Bool {
        if ids.isEmpty || other.ids.isEmpty {
            return ids.isEmpty && other.ids.isEmpty && username == other.username
        }
        return !Set(ids).isDisjoint(with: other.ids)
    }
}

private struct Receipt {
    let participant: String
    var watermark: Date
}

/// A message as read, with its free text still raw: only the messages a chat keeps are cleaned.
private struct MessageDraft {
    let id: String
    let sent: Date
    var senderID: String?
    var texts: [String]
    var sharedTitles: [String]

    mutating func fill(from other: MessageDraft) {
        senderID = senderID ?? other.senderID
        if texts.isEmpty { texts = other.texts }
        if sharedTitles.isEmpty { sharedTitles = other.sharedTitles }
    }
}

private struct ChatDraft {
    let key: String
    var threadFBID: String?
    var folder: String?
    var isGroup: Bool?
    var title: String?
    var lastActivity: Date?
    var markedUnread: Bool?
    var users: [UserEntry] = []
    var receipts: [Receipt] = []
    var messages: [String: MessageDraft] = [:]

    /// Fills fields this draft lacks from `other`, and unions users, receipts, and messages.
    mutating func merge(_ other: ChatDraft) {
        threadFBID = threadFBID ?? other.threadFBID
        folder = folder ?? other.folder
        isGroup = isGroup ?? other.isGroup
        title = title ?? other.title
        lastActivity = lastActivity ?? other.lastActivity
        markedUnread = markedUnread ?? other.markedUnread
        for user in other.users where users.count < InstagramInboxParser.maximumListedEntries {
            if !users.contains(where: { $0.matches(user) }) { users.append(user) }
        }
        for receipt in other.receipts {
            if let index = receipts.firstIndex(where: { $0.participant == receipt.participant }) {
                receipts[index].watermark = max(receipts[index].watermark, receipt.watermark)
            } else if receipts.count < InstagramInboxParser.maximumListedEntries {
                receipts.append(receipt)
            }
        }
        add(other.messages.values)
    }

    mutating func add(_ incoming: some Sequence<MessageDraft>) {
        for message in incoming {
            if var existing = messages.removeValue(forKey: message.id) {
                existing.fill(from: message)
                messages[message.id] = existing
            } else {
                messages[message.id] = message
            }
        }
    }
}

/// A message list that carries no thread key of its own.
private struct DetailDraft {
    let chatID: String?
    let messages: [MessageDraft]
}

// MARK: - Collector

private struct Collector {
    let window: TimeWindow
    private var visited = 0
    private var chats: [String: ChatDraft] = [:]
    private var chatOrder: [String] = []
    private var details: [DetailDraft] = []
    private var viewerIDs = Set<String>()
    private var usernames: [String: String] = [:]
    private var unsentIDs = Set<String>()

    init(window: TimeWindow) {
        self.window = window
    }

    private var isExhausted: Bool {
        visited >= InstagramInboxParser.maximumVisitedNodes
    }

    /// Spends up to `wanted` visits and returns how many were available.
    private mutating func spend(_ wanted: Int) -> Int {
        let granted = max(0, min(wanted, InstagramInboxParser.maximumVisitedNodes - visited))
        visited += granted
        return granted
    }

    // MARK: Walking

    mutating func walk(_ value: Any, depth: Int) {
        guard depth <= InstagramInboxParser.maximumDepth, spend(1) == 1 else { return }
        if let record = Field.dictionary(value) {
            if let key = Field.identifierText(record["thread_key"]) {
                if Field.isAcceptableID(key) { absorbChat(record, key: key) }
                return
            }
            if let container = Field.dictionary(record["slide_messages"]),
               let edges = Field.array(container["edges"]) {
                absorbDetail(record, edges: edges)
                return
            }
            for name in record.keys.sorted() {
                guard !isExhausted else { return }
                if let child = record[name] { walk(child, depth: depth + 1) }
            }
        } else if let list = Field.array(value) {
            for element in list {
                guard !isExhausted else { return }
                walk(element, depth: depth + 1)
            }
        }
    }

    // MARK: Records

    private mutating func absorbChat(_ record: [String: Any], key: String) {
        learnViewer(Field.dictionary(record["viewer"]))
        var draft = ChatDraft(key: key)
        draft.threadFBID = Field.id(record["thread_fbid"])
        draft.folder = Self.folder(record["folder"])
        draft.isGroup = Field.bool(record["is_group"])
        draft.title = Field.string(record["thread_title"]).flatMap(Self.title)
        draft.lastActivity = window.date(record["last_activity_timestamp_ms"])
        draft.markedUnread = Field.bool(record["marked_as_unread"])
        draft.users = readUsers(record["users"])
        draft.receipts = readReceipts(record["slide_read_receipts"])
        if let container = Field.dictionary(record["slide_messages"]),
           let edges = Field.array(container["edges"]) {
            draft.add(readMessages(nodes(in: edges)))
        }
        if var existing = chats.removeValue(forKey: key) {
            existing.merge(draft)
            chats[key] = existing
        } else {
            chats[key] = draft
            chatOrder.append(key)
        }
    }

    private mutating func absorbDetail(_ record: [String: Any], edges: [Any]) {
        let listed = nodes(in: edges)
        let chatID = Field.id(record["thread_fbid"])
            ?? listed.lazy.compactMap { Field.id($0["thread_fbid"]) }.first
        details.append(DetailDraft(chatID: chatID, messages: readMessages(listed)))
    }

    private static func folder(_ value: Any?) -> String? {
        guard let text = Field.string(value), (1...64).contains(text.utf8.count) else { return nil }
        return text.uppercased()
    }

    private static func title(_ raw: String) -> String? {
        let cleaned = PageText.cleanLine(raw, limit: DirectMessageThread.titleLimit)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: People

    private mutating func learnViewer(_ viewer: [String: Any]?) {
        guard let viewer else { return }
        for value in [viewer["interop_messaging_user_fbid"], viewer["id"]] {
            if let id = Field.id(value) { viewerIDs.insert(id) }
        }
    }

    private mutating func learn(_ name: String, for ids: [String?]) {
        for case let id? in ids where usernames[id] == nil && usernames.count < InstagramInboxParser.maximumKnownUsers {
            usernames[id] = name
        }
    }

    private mutating func readUsers(_ value: Any?) -> [UserEntry] {
        guard let list = Field.array(value) else { return [] }
        let count = spend(min(list.count, InstagramInboxParser.maximumListedEntries))
        var entries: [UserEntry] = []
        for element in list.prefix(count) {
            guard let user = Field.dictionary(element) else { continue }
            let ids = [Field.id(user["interop_messaging_user_fbid"]), Field.id(user["id"])].compactMap { $0 }
            let name = Field.username(user["username"])
            guard !ids.isEmpty || name != nil else { continue }
            if let name { learn(name, for: ids) }
            entries.append(UserEntry(ids: ids, username: name))
        }
        return entries
    }

    private mutating func readReceipts(_ value: Any?) -> [Receipt] {
        guard let list = Field.array(value) else { return [] }
        let count = spend(min(list.count, InstagramInboxParser.maximumListedEntries))
        var receipts: [Receipt] = []
        for element in list.prefix(count) {
            guard let entry = Field.dictionary(element),
                  let participant = Field.id(entry["participant_fbid"]),
                  let watermark = window.date(entry["watermark_timestamp_ms"])
            else { continue }
            receipts.append(Receipt(participant: participant, watermark: watermark))
        }
        return receipts
    }

    // MARK: Messages

    /// The message nodes of an edge list, within what the visit budget allows.
    private mutating func nodes(in edges: [Any]) -> [[String: Any]] {
        let count = spend(edges.count)
        return edges.prefix(count).compactMap { Field.dictionary(Field.dictionary($0)?["node"]) }
    }

    private mutating func readMessages(_ nodes: [[String: Any]]) -> [MessageDraft] {
        nodes.compactMap { readMessage($0) }
    }

    private mutating func readMessage(_ node: [String: Any]) -> MessageDraft? {
        let rawID = ["id", "message_id"].lazy.compactMap { Field.identifierText(node[$0]) }.first
        guard let id = rawID, Field.isAcceptableID(id) else { return nil }
        if Self.isUnsent(node["tombstone_reason"]) {
            unsentIDs.insert(id)
            return nil
        }
        guard let sent = window.date(node["timestamp_ms"]) else { return nil }
        let senderID = Field.id(node["sender_fbid"])
        learnSender(of: node, senderID: senderID)

        let content = Field.dictionary(node["content"])
        let xma = Field.dictionary(content?["xma"])
        return MessageDraft(
            id: id,
            sent: sent,
            senderID: senderID,
            texts: [node["text_body"], content?["text_body"]].compactMap(Field.string),
            sharedTitles: [xma?["header_title_text"], xma?["xmaHeaderTitle"], content?["xma_text_body"]]
                .compactMap(Field.string)
        )
    }

    /// A tombstone reason that is present and not the empty string marks an unsent message.
    private static func isUnsent(_ reason: Any?) -> Bool {
        guard let reason, !(reason is NSNull) else { return false }
        return (reason as? String) != ""
    }

    private mutating func learnSender(of node: [String: Any], senderID: String?) {
        guard let sender = Field.dictionary(node["sender"]) else { return }
        let userDict = Field.dictionary(sender["user_dict"])
        guard let name = Field.username(userDict?["username"]) else { return }
        learn(name, for: [Field.id(userDict?["interop_messaging_user_fbid"]), Field.id(sender["id"]), senderID])
    }

    // MARK: Result

    func finish() -> (threads: [DirectMessageThread], report: InstagramInboxParser.Report) {
        var report = InstagramInboxParser.Report()
        report.threadsListed = chatOrder.count
        report.stoppedEarly = isExhausted

        var kept: [ChatDraft] = []
        for key in chatOrder {
            guard let chat = chats[key] else { continue }
            if let folder = chat.folder, InstagramInboxParser.acceptedFolders.contains(folder) {
                kept.append(chat)
            } else {
                report.threadsOutsideFolders += 1
            }
        }

        var indexByKey: [String: Int] = [:]
        var indexByFBID: [String: Int] = [:]
        for (index, chat) in kept.enumerated() {
            indexByKey[chat.key] = indexByKey[chat.key] ?? index
            if let fbid = chat.threadFBID { indexByFBID[fbid] = indexByFBID[fbid] ?? index }
        }
        for detail in details {
            guard let id = detail.chatID, let index = indexByKey[id] ?? indexByFBID[id] else {
                report.detailsUnmatched += 1
                continue
            }
            kept[index].add(detail.messages)
        }

        var threads = kept.map(thread)
        threads.sort {
            let (left, right) = ($0.recency ?? .distantPast, $1.recency ?? .distantPast)
            return left != right ? left > right : $0.id < $1.id
        }
        threads = Array(threads.prefix(InstagramInboxParser.maximumThreads))
        report.messages = threads.reduce(0) { $0 + $1.messages.count }
        return (threads, report)
    }

    private func thread(from chat: ChatDraft) -> DirectMessageThread {
        let newest = chat.messages.values
            .filter { !unsentIDs.contains($0.id) }
            .sorted { $0.sent != $1.sent ? $0.sent < $1.sent : $0.id < $1.id }
            .suffix(InstagramInboxParser.maximumMessagesPerThread)
        let messages = newest.map(message)
        let names = participantNames(of: chat)
        return DirectMessageThread(
            id: chat.key,
            title: chat.title,
            participants: names,
            isGroup: chat.isGroup ?? (names.count > 1),
            lastActivity: chat.lastActivity,
            isUnread: isUnread(chat, messages: messages),
            messages: messages
        )
    }

    private func message(from draft: MessageDraft) -> DirectMessage {
        DirectMessage(
            id: draft.id,
            sent: draft.sent,
            isFromViewer: draft.senderID.map { viewerIDs.contains($0) } ?? false,
            sender: draft.senderID.flatMap { usernames[$0] },
            text: draft.texts
                .lazy.map { PageText.clean($0, limit: DirectMessage.textLimit) }
                .first { !$0.isEmpty } ?? "",
            shared: draft.sharedTitles
                .lazy.map { PageText.cleanLine($0, limit: DirectMessage.sharedLimit) }
                .first { !$0.isEmpty }
        )
    }

    private func participantNames(of chat: ChatDraft) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for user in chat.users {
            guard let name = user.username,
                  !user.ids.contains(where: { viewerIDs.contains($0) }),
                  seen.insert(name).inserted
            else { continue }
            names.append(name)
            if names.count == DirectMessageThread.maximumParticipants { break }
        }
        return names
    }

    /// True when the chat is marked unread, or a message from someone else arrived after the
    /// viewer's read watermark; false when a viewer watermark covers every such message; nil
    /// when the source gave no viewer watermark.
    private func isUnread(_ chat: ChatDraft, messages: [DirectMessage]) -> Bool? {
        if chat.markedUnread == true { return true }
        let watermark = chat.receipts
            .filter { viewerIDs.contains($0.participant) }
            .map(\.watermark)
            .max()
        guard let watermark else { return nil }
        return messages.contains { !$0.isFromViewer && $0.sent > watermark }
    }
}
