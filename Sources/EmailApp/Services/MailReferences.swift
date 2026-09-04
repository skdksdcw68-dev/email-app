import Foundation

/// The handles a backend gives out, and takes back.
///
/// Every provider names things differently and the differences are not
/// cosmetic: Gmail hands a draft two ids that are not interchangeable, Graph
/// hands one, and IMAP hands a number that is only meaningful inside one
/// folder until the folder is rebuilt. Passing bare `String`s around means
/// every call site has to know which flavour it is holding, which is how a
/// draft id ends up in a message endpoint and returns a 404 nobody can
/// explain.

/// One message, as its provider names it.
struct MessageRef: Sendable, Hashable, Codable {
    let id: String
    /// The conversation it belongs to, where the provider has one.
    var thread: String?
}

/// One attachment, which always needs the message it hangs off.
///
/// Both Gmail and Graph identify a part only within its message, so the pair
/// travels together. `AttachmentStore` already does this by hand.
struct AttachmentRef: Sendable, Hashable {
    let messageID: String
    let attachmentID: String
}

struct ThreadRef: Sendable, Hashable {
    let id: String
}

/// A draft, and the reason this file exists.
///
/// Gmail gives a draft **two** ids: a draft id that only the `/drafts`
/// endpoints answer to, and a message id that everything else in the app
/// wants. Editing by the wrong one is a 404, and the app learned that the
/// hard way -- `saveDraft` stored the draft id in `remoteID` for weeks.
///
/// Graph has one id and leaves `secondary` nil. IMAP has a UID. Nothing
/// outside a backend should read the parts.
struct DraftRef: Sendable, Hashable, Codable {
    let provider: MailProvider
    /// What the draft endpoints answer to.
    let primary: String
    /// The message id, where the provider has a separate one.
    var secondary: String?
    var thread: String?

    /// What the rest of the app calls this message. Gmail's message id where
    /// there is one, else the only id there is.
    var messageID: String { secondary ?? primary }
}

/// What came back from a send.
struct SentReceipt: Sendable, Hashable {
    let id: String
    var thread: String?
}

// MARK: - Paging

struct PageRequest: Sendable {
    var query: MailQuery = .folder(.inbox)
    var limit: Int = 25
    /// Where the last page left off. Nil for the first.
    var cursor: String?
}

struct MessagePage: Sendable {
    let messages: [Message]
    /// Nil once there is no more.
    let cursor: String?
}

// MARK: - Keeping up

/// Where a mailbox had got to, in whatever form its provider counts.
///
/// Opaque on purpose. Gmail counts in `historyId`, Graph in an OData
/// `deltaLink` that is a whole URL, IMAP in `UIDVALIDITY:UIDNEXT`. The app
/// stores it, hands it back, and never looks inside.
struct SyncCheckpoint: Sendable, Hashable, Codable {
    let token: String

    init(_ token: String) { self.token = token }
}

/// What changed since a checkpoint.
struct ChangeSet: Sendable {
    var added: [MessageRef] = []
    var removed: [MessageRef] = []
    /// Where to resume from next time.
    var next: SyncCheckpoint?

    /// The checkpoint is too old to be answered and the only honest response
    /// is a full refresh.
    ///
    /// The one piece of sync that maps cleanly across all three providers:
    /// Gmail answers 404 once its week of history has passed, Graph answers
    /// 410 Gone with `resyncRequired`, and an IMAP server that has renumbered
    /// its folder reports a new `UIDVALIDITY`. Three mechanisms, one meaning.
    var isExpired = false
}

// MARK: - Push

/// Where a provider should send its notices.
enum PushDestination: Sendable {
    /// Gmail publishes to a Pub/Sub topic.
    case pubSub(topic: String)
    /// Graph posts to a URL, and wants to know when to stop.
    case webhook(URL, expires: Date)
}

/// A live subscription, and what is needed to end it.
///
/// Gmail has one watch per mailbox and no handle -- stopping is a bare call.
/// Graph gives a subscription id that must be deleted by id and renewed
/// before it lapses, in about three days rather than Gmail's seven.
struct PushRegistration: Sendable, Hashable, Codable {
    var id: String?
    var expires: Date?
    /// Where the provider says the mailbox stands right now.
    ///
    /// Gmail returns a `historyId` from `watch` and the app has been throwing
    /// it away. It is the correct starting cursor for a mailbox that has just
    /// been watched, and without it the first notice after connecting has
    /// nothing to compare against and announces nothing.
    var checkpoint: SyncCheckpoint?
}
