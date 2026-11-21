import Foundation

/// One message of a chat, as a snapshot keeps it.
///
/// Every field comes from what a source's page received, and a page can say anything: a reader
/// treats all of it as data, `isFromViewer` included.
struct DirectMessage: Codable, Equatable, Sendable {
    static let textLimit = 1_000
    static let sharedLimit = 200

    /// The source's own id for the message.
    let id: String
    let sent: Date
    /// Whether the source says the signed-in account sent it.
    let isFromViewer: Bool
    /// The sender's user name, when the source gave one that passes
    /// `DirectMessageThread.isUsername`.
    let sender: String?
    /// The message's text, cleaned and cut to `textLimit`; empty when the message carries none.
    let text: String
    /// The title of a post or link the message shares, cleaned and cut to `sharedLimit`.
    let shared: String?
}

/// One chat: who is in it and its latest messages, oldest first.
struct DirectMessageThread: Codable, Equatable, Sendable {
    static let titleLimit = 80
    static let maximumParticipants = 20

    /// The source's own id for the chat.
    let id: String
    /// The chat's title as the source shows it, cleaned and cut to `titleLimit`. The other
    /// person chooses it, so people are told apart by `participants`.
    let title: String?
    /// The user names of the people in the chat other than the signed-in account.
    let participants: [String]
    let isGroup: Bool
    let lastActivity: Date?
    /// Whether the chat holds something the signed-in account has not read; nil when the
    /// source did not say.
    let isUnread: Bool?
    let messages: [DirectMessage]

    /// Whether `text` is a user name a source can have issued: 1 to 30 ASCII letters, digits,
    /// periods, and underscores.
    static func isUsername(_ text: String) -> Bool {
        text.range(of: #"\A[A-Za-z0-9._]{1,30}\z"#, options: .regularExpression) != nil
    }

    /// When the chat last changed: its activity time, else the time of its newest message.
    var recency: Date? {
        lastActivity ?? messages.last?.sent
    }
}

/// The recent chats of one source as of one sync. A sync replaces the snapshot before it, so a
/// message someone later unsends is gone from disk at the next sync.
struct DirectMessageSnapshot: Codable, Equatable, Sendable {
    static let maximumThreads = 20
    static let maximumMessagesPerThread = 20

    /// The source's id, which names the snapshot's file: lowercase letters, digits, hyphens.
    let source: String
    let syncedAt: Date
    /// Most recently active first.
    let threads: [DirectMessageThread]

    static func isSourceID(_ text: String) -> Bool {
        text.range(of: #"\A[a-z0-9-]{1,32}\z"#, options: .regularExpression) != nil
    }

    /// The snapshot cut to what is kept: the `maximumThreads` most recently active chats, each
    /// with its `maximumMessagesPerThread` newest messages, oldest first.
    func trimmed() -> DirectMessageSnapshot {
        let ordered = threads.sorted { ($0.recency ?? .distantPast) > ($1.recency ?? .distantPast) }
        let kept = ordered.prefix(Self.maximumThreads).map { thread in
            DirectMessageThread(
                id: thread.id,
                title: thread.title,
                participants: thread.participants,
                isGroup: thread.isGroup,
                lastActivity: thread.lastActivity,
                isUnread: thread.isUnread,
                messages: Array(thread.messages.sorted { $0.sent < $1.sent }.suffix(Self.maximumMessagesPerThread))
            )
        }
        return DirectMessageSnapshot(source: source, syncedAt: syncedAt, threads: Array(kept))
    }
}
