import Foundation
import Security

/// Where the secrets go.
///
/// The app has never stored a credential of its own -- GoogleSignIn kept the
/// one token inside its own keychain and nothing else needed anything. That
/// stops working with more than one mailbox: the SDK holds a single session,
/// so the app has to hold the refresh tokens itself, and an IMAP mailbox has
/// a password that belongs nowhere else.
///
/// Nothing here is ever written to `UserDefaults` or to a JSON file.
/// `MailAccount` is deliberately free of secrets so it can be persisted
/// plainly; everything that must not be is in here, keyed by mailbox id.
enum Keychain {

    /// What a mailbox can have stored against it.
    enum Secret: String, CaseIterable {
        /// OAuth. Long-lived; the access token is derived from it and never
        /// stored, because a token that expires in an hour is not worth
        /// writing to disk.
        case refreshToken
        /// IMAP and SMTP. Often the same value, occasionally not -- some
        /// hosts issue separate app passwords for sending.
        case imapPassword
        case smtpPassword
    }

    private static let service = "com.abelamare.maily.mailbox"

    // MARK: - Reading and writing

    static func store(_ value: String, _ kind: Secret, for id: MailboxID) throws {
        let data = Data(value.utf8)
        var query = base(kind, id)

        // Update in place when it is already there. SecItemAdd on an existing
        // item fails with errSecDuplicateItem rather than replacing it, which
        // would silently keep the old token after a re-authentication.
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }

        query[kSecValueData as String] = data
        // After first unlock, NOT when unlocked.
        //
        // A silent push wakes the app to catch up on new mail while the phone
        // is in somebody's pocket. With `WhenUnlocked` the token read fails
        // there with errSecInteractionNotAllowed, so the refresh fails, so the
        // catch-up fails -- and the only symptom is that notifications work
        // when you are holding the phone and never when you are not.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    /// Nil when there is nothing stored, and also when the device is locked
    /// hard enough that it cannot be read. Callers treat both the same way:
    /// no credential, so no request.
    static func read(_ kind: Secret, for id: MailboxID) -> String? {
        var query = base(kind, id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ kind: Secret, for id: MailboxID) {
        SecItemDelete(base(kind, id) as CFDictionary)
    }

    /// Everything belonging to one mailbox. Called when it is removed -- a
    /// mailbox the person deleted should not leave a working credential
    /// behind.
    static func deleteAll(for id: MailboxID) {
        for kind in Secret.allCases { delete(kind, for: id) }
    }

    // MARK: - Plumbing

    private static func base(_ kind: Secret, _ id: MailboxID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(id.rawValue)#\(kind.rawValue)",
        ]
    }

    struct Failure: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String?
            return "The keychain refused that (\(status)). \(detail ?? "")"
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
