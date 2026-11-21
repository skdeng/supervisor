import Foundation

/// A service whose chats the app copies by loading the service's own inbox page signed in as
/// the person and listening to what that page receives.
struct DirectMessageSource: Sendable {
    typealias Parse = @Sendable (_ responses: [String], _ now: Date) -> (
        threads: [DirectMessageThread], report: InstagramInboxParser.Report
    )

    /// Names the snapshot's file and the source's stored state.
    let id: String
    /// What the person calls the service.
    let name: String
    /// The hosts the hidden browser may load a main frame from.
    let hosts: Set<String>
    let inboxURL: URL
    /// Where the person starts when they sign in.
    let signInURL: URL
    /// A page whose path starts with one of these asks for a sign-in.
    let signInPathPrefixes: [String]
    let capture: PageCapture
    /// The requests the hidden browser never makes, as a WebKit content rule list.
    let blockedRequests: String
    /// The data store the source's session lives in, which is its own: a site's cookies are
    /// deleted by registrable domain when the site is removed, and a store shared with the
    /// granted sites would sign this source out with them.
    let storeIdentifier: UUID
    /// Turns the responses the page received into chats.
    let parse: Parse

    /// Instagram's web inbox.
    ///
    /// The page reads chats with operations whose names end in `Query` and changes things with
    /// others, so only the former are sent. Its realtime connection, which is what shows an
    /// account as active, is a socket; the rules also name the address it connects to and the
    /// addresses that mark a chat seen.
    static let instagram = DirectMessageSource(
        id: "instagram",
        name: "Instagram",
        hosts: ["www.instagram.com"],
        inboxURL: URL(string: "https://www.instagram.com/direct/inbox/")!,
        signInURL: URL(string: "https://www.instagram.com/accounts/login/")!,
        signInPathPrefixes: ["/accounts/login", "/challenge"],
        capture: PageCapture(
            host: "www.instagram.com",
            urlPattern: #"^https://www\.instagram\.com/(api/graphql|graphql/query)"#,
            markers: ["slide_messages", "thread_key"],
            operationField: "fb_api_req_friendly_name",
            sentOperationSuffix: "Query",
            blocksSockets: true
        ),
        blockedRequests: #"""
            [
              {"trigger": {"url-filter": ".*", "resource-type": ["websocket"]}, "action": {"type": "block"}},
              {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
              {"trigger": {"url-filter": "^https?://[^/]*edge-chat\\."}, "action": {"type": "block"}},
              {"trigger": {"url-filter": "^https?://[^/]+/api/v1/direct_v2/.*seen"}, "action": {"type": "block"}}
            ]
            """#,
        storeIdentifier: UUID(uuidString: "7E0B6C41-3D9A-4B52-A6F8-1C4E9D2A5B70")!,
        parse: { responses, now in InstagramInboxParser.parse(responses, now: now) }
    )
}
