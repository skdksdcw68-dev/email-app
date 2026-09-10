import Foundation
import Security

/// The one thing the notification extension is allowed to know.
///
/// ## Why this exists
///
/// The push that wakes the phone carries a mailbox address and a history id
/// and nothing else -- deliberately, because Maily holds Gmail restricted
/// scopes and a server that reads mail is a server the security assessment
/// has to cover. So the lock screen said "New mail" and the address, which is
/// the least useful notification an email app can send.
///
/// A notification service extension fixes that without moving an inch on the
/// privacy position: it runs *on the phone*, in the moment between APNs
/// delivering the push and iOS drawing the banner, and it can rewrite what
/// the banner says. It fetches the message with the device's own credentials,
/// exactly as the app does. Nothing new leaves the phone and no server learns
/// anything it did not already know.
///
/// ## Why not just share the Keychain the app already has
///
/// `Keychain` stores secrets keyed by `MailboxID`, and the extension only
/// learns an *address* from the push. Mapping one to the other means reading
/// the account registry, which lives in `UserDefaults` suites that are not
/// shared with an extension -- and renaming those suites would orphan every
/// existing install's read state, snoozes and classifications.
///
/// So this is a second, purpose-made record: written alongside the real one,
/// keyed by the only thing the extension is given, holding only what a single
/// metadata fetch needs. Nothing existing moves, so nothing existing can be
/// lost, and if the record is missing the extension simply leaves the banner
/// as the server wrote it.
///
/// ⚠️ Shared by two targets. Keep it to Foundation and Security -- an app
/// extension gets a fraction of the memory an app does, and it must not drag
/// the Google or Supabase SDKs in behind it.
enum PushCredentials {

    /// What the extension needs and nothing else.
    ///
    /// Not the access token: those last an hour, and a record that is stale
    /// more often than it is fresh is worse than one that has to be exchanged
    /// every time. The refresh grant is the same secret the app already holds
    /// for this mailbox, in the same place, under the same protection class.
    struct Record: Codable {
        let refreshToken: String
        let clientID: String
        /// What to call this mailbox on a lock screen when there are several.
        /// Empty when there is only one, because naming the only mailbox
        /// somebody has is noise on every single banner.
        var mailboxName: String
    }

    private static let service = "com.abelamare.maily.push"

    /// 🔴 The team prefix is written out rather than read from the
    /// entitlement, because both targets have to agree on this string and a
    /// disagreement is invisible: the write succeeds, the read returns
    /// nothing, and the only symptom is a notification that never improves.
    ///
    /// `TDMFXRJYN7` is the team the app is signed by; see `project.yml`.
    private static let accessGroup = "TDMFXRJYN7.com.netro.maily.shared"

    // MARK: - Writing (the app)

    static func save(_ record: Record, for address: String) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        var query = base(address)

        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { return }

        query[kSecValueData as String] = data
        // After first unlock, for the same reason the app's own store uses it:
        // a push arrives while the phone is in somebody's pocket, and a
        // credential that can only be read while unlocked is a credential the
        // extension can never read when it matters.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Called when a mailbox is disconnected. A record left behind would let
    /// the extension keep refreshing a grant for a mailbox the person has
    /// removed.
    static func forget(_ address: String) {
        SecItemDelete(base(address) as CFDictionary)
    }

    // MARK: - Reading (the extension)

    static func read(_ address: String) -> Record? {
        var query = base(address)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    // MARK: -

    private static func base(_ address: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Lowercased on both sides. Gmail's Pub/Sub notice and the
            // address somebody typed can differ in case, and a Keychain
            // account attribute is compared byte for byte.
            kSecAttrAccount as String: address.lowercased(),
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
