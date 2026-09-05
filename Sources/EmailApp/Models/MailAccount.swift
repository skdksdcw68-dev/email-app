import Foundation
import SwiftUI

/// Where a mailbox lives, and therefore how the app talks to it.
enum MailProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// So a provider can drive a `sheet(item:)` directly -- the sheet is up
    /// exactly when one has been chosen, with no second flag to fall out of
    /// step with it.
    var id: String { rawValue }

    case gmail, microsoft, imap

    var title: String {
        switch self {
        case .gmail:     "Google"
        case .microsoft: "Microsoft"
        case .imap:      "Other email"
        }
    }

    /// What somebody would recognise it by, rather than the company name.
    var subtitle: String {
        switch self {
        case .gmail:     "Gmail or Google Workspace"
        case .microsoft: "Outlook, Hotmail or Microsoft 365"
        case .imap:      "Your own domain, through IMAP"
        }
    }

    /// The provider named inside a sentence, where `title` does not fit.
    ///
    /// "Nothing on Google is touched" reads; "Nothing on Other email is
    /// touched" does not, and that sentence is the one reassuring somebody
    /// their mail is safe.
    var inSentence: String {
        switch self {
        case .gmail:     "Google"
        case .microsoft: "Microsoft"
        case .imap:      "your mail server"
        }
    }
}

/// The colour a mailbox is marked with.
///
/// Named rather than stored as a colour, so it survives a change of palette
/// and encodes as a word. Six is enough to tell mailboxes apart at a glance
/// and few enough to fit one row of swatches.
enum MailboxTint: String, Codable, CaseIterable, Sendable {
    case blue, green, orange, purple, pink, teal

    var color: Color {
        switch self {
        case .blue:   .blue
        case .green:  .green
        case .orange: .orange
        case .purple: .purple
        case .pink:   .pink
        case .teal:   .teal
        }
    }

    /// The next colour nothing is using, so a second mailbox does not arrive
    /// wearing the first one's.
    static func next(after taken: [MailboxTint]) -> MailboxTint {
        allCases.first { !taken.contains($0) } ?? .blue
    }
}

/// How far back to pull when a mailbox is first connected.
///
/// A constant until now (`newer_than:3m`). Per-account because the right
/// answer differs: a Gmail account can take three months in a couple of
/// minutes, and a small IMAP server on a slow host cannot.
enum ImportWindow: String, Codable, CaseIterable, Sendable {
    case threeMonths, oneYear, everything

    var title: String {
        switch self {
        case .threeMonths: "Last 3 months"
        case .oneYear:     "Last year"
        case .everything:  "Everything"
        }
    }

    var detail: String {
        switch self {
        case .threeMonths: "Recommended. A few minutes."
        case .oneYear:     "Longer, and more of your phone."
        case .everything:  "Can take a while on a big mailbox."
        }
    }

    /// Nil means no limit.
    var months: Int? {
        switch self {
        case .threeMonths: 3
        case .oneYear:     12
        case .everything:  nil
        }
    }
}

/// How a connection is protected.
enum TransportSecurity: String, Codable, CaseIterable, Sendable {
    case tls, startTLS, none

    var title: String {
        switch self {
        case .tls:      "SSL/TLS"
        case .startTLS: "STARTTLS"
        case .none:     "None"
        }
    }
}

/// Where an IMAP mailbox actually is.
///
/// No password here. This whole struct is written to `UserDefaults` with the
/// rest of the account, and a password in `UserDefaults` is a password in a
/// plist. Secrets live in the Keychain, keyed by the mailbox id.
struct IMAPConfig: Codable, Hashable, Sendable {
    var imapHost: String
    var imapPort: Int = 993
    var smtpHost: String
    var smtpPort: Int = 587
    /// Often not the address -- plenty of hosts want the full address, plenty
    /// want the local part, and some want something else entirely.
    var username: String
    var imapSecurity: TransportSecurity = .tls
    var smtpSecurity: TransportSecurity = .startTLS
    /// Learned from the server's own `SIZE` in its EHLO reply. Nil until it
    /// has said, which is why the attachment limit has to be asked for rather
    /// than assumed.
    var maxOutboundBytes: Int?
}

/// Microsoft-specific bits, for later.
struct GraphConfig: Codable, Hashable, Sendable {
    /// `common` for personal accounts, a tenant id for a work one.
    var tenant: String = "common"
    /// The webhook subscription, so it can be renewed and torn down. Graph
    /// expires mail subscriptions in about three days.
    var subscriptionID: String?
    var subscriptionExpiry: Date?
}

/// One mailbox the app knows about.
///
/// Replaces `GmailAccount`, which was `{id, email, displayName, connectedAt}`
/// and had no room for a second provider or a second account.
///
/// Everything here is `Codable` and safe to keep in `UserDefaults` --
/// **deliberately, and it is a rule rather than a coincidence.** No token, no
/// password, no refresh token. Secrets go to the Keychain under `id`. If a
/// field ever wants to be secret, it belongs in `Keychain`, not here.
struct MailAccount: Identifiable, Hashable, Codable, Sendable {

    /// Whether the app can currently reach it.
    enum State: Codable, Hashable, Sendable {
        case ok
        /// The grant was revoked, the password changed, the token is dead.
        /// Carried rather than thrown away, because the alternative -- what
        /// the app does today -- is an inbox that is silently empty.
        case needsReauth(reason: String)
        /// Turned off without being removed. Nothing syncs, nothing is lost.
        case paused
    }

    let id: MailboxID
    let provider: MailProvider
    /// Canonical and lowercased. This is the identity: the id is derived from
    /// it, and push notices arrive carrying it.
    let address: String

    /// What the provider calls the person.
    var displayName: String

    /// Where the provider keeps their picture.
    ///
    /// The URL, not the bytes: this struct is JSON-encoded into
    /// `UserDefaults` on every registry write, and an image in there is
    /// kilobytes of base64 read and parsed on every launch whether or not
    /// anything draws it. `AvatarStore` holds the bytes as files.
    ///
    /// ⚠️ Optional and expected to stay nil for IMAP, which has no such
    /// concept -- a mail server knows a password, not a face.
    var photoURL: URL?
    /// What the person calls the mailbox. "Work". Beats `displayName`
    /// everywhere it is shown, because two Gmail accounts have the same
    /// display name and different jobs.
    var nickname: String?
    var tint: MailboxTint

    var connectedAt: Date
    /// Drives "last used" as the default-mailbox rule.
    var lastActiveAt: Date

    var state: State = .ok
    var importWindow: ImportWindow = .threeMonths
    /// Notify for this mailbox. The first thing anybody with two mailboxes
    /// wants is mail from one and silence from the other.
    var notifies: Bool = true

    var server: IMAPConfig?
    var tenant: GraphConfig?

    init(
        provider: MailProvider,
        address: String,
        displayName: String,
        photoURL: URL? = nil,
        nickname: String? = nil,
        tint: MailboxTint = .blue,
        connectedAt: Date = .now,
        lastActiveAt: Date = .now,
        state: State = .ok,
        importWindow: ImportWindow = .threeMonths,
        notifies: Bool = true,
        server: IMAPConfig? = nil,
        tenant: GraphConfig? = nil
    ) {
        let canonical = MailboxID.canonical(address)
        self.id = MailboxID.derive(provider: provider, address: canonical)
        self.provider = provider
        self.address = canonical
        self.displayName = displayName
        self.photoURL = photoURL
        self.nickname = nickname
        self.tint = tint
        self.connectedAt = connectedAt
        self.lastActiveAt = lastActiveAt
        self.state = state
        self.importWindow = importWindow
        self.notifies = notifies
        self.server = server
        self.tenant = tenant
    }

    // MARK: - Reading

    /// What to call it on screen: what they named it, else who it belongs to.
    var title: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return displayName.isEmpty ? address : displayName
    }

    /// Moved from `GmailAccount`, unchanged.
    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        if letters.isEmpty { return String(address.prefix(1)).uppercased() }
        return String(letters).uppercased()
    }

    var needsAttention: Bool {
        if case .needsReauth = state { return true }
        return false
    }

    var isPaused: Bool { state == .paused }

    /// Whether the provider can wake the phone on its own. Gmail has Pub/Sub
    /// and Graph has webhooks; IMAP has a socket it cannot hold open in the
    /// background, so it falls back to periodic refresh.
    var canPush: Bool { provider != .imap }

    /// For the avatar, which draws from a `Contact`.
    var contact: Contact {
        Contact(name: displayName.isEmpty ? address : displayName, address: address)
    }
}
