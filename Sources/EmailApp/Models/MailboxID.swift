import Foundation
import CryptoKit

/// What names a mailbox, everywhere.
///
/// A directory name, a `UserDefaults` suite name, a Keychain attribute, a
/// column in Supabase. It has to be short, path-safe, stable for the life of
/// the mailbox, and carry no address in it -- a folder called
/// `abel@example.com` is somebody's email address written on the filesystem.
///
/// **Derived, not minted.** The obvious alternative is a fresh `UUID` stored
/// with the account, and the app has already been bitten by the version of
/// that which forgets to store it: the old `GmailAccount.id` defaulted to a
/// fresh `UUID()`, and both `restore()` and `connect()` built a *new* account
/// every launch -- so the id re-rolled every time and nothing could safely
/// key off it.
///
/// Deriving from `(provider, address)` removes that whole class of bug. It
/// also buys two things worth having:
///
///   - The push path gets an address and needs a mailbox. Derivation means no
///     lookup table, and no failure mode where the table is stale.
///   - Disconnect a mailbox and reconnect it, and it lands on the same id --
///     so read state, snoozes and classifications are still there.
struct MailboxID: Hashable, Codable, RawRepresentable, Sendable, CustomStringConvertible {
    let rawValue: String

    /// Only accepts what this type produces: sixteen lowercase hex characters.
    /// Anything else came from a corrupted registry or a hand-edited file, and
    /// letting it through would put arbitrary text into a filesystem path.
    init?(rawValue: String) {
        guard rawValue.count == 16,
              rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        self.rawValue = rawValue
    }

    private init(checked: String) { self.rawValue = checked }

    /// The first eight bytes of `SHA256("provider|address")`.
    ///
    /// Sixty-four bits is plenty here. The input space is not "every email
    /// address" -- it is the handful this one person has connected -- so a
    /// collision needs two of their own addresses to hash alike.
    static func derive(provider: MailProvider, address: String) -> MailboxID {
        let seed = "\(provider.rawValue)|\(canonical(address))"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return MailboxID(checked: hex)
    }

    /// One spelling of an address, so the same mailbox never derives two ids.
    ///
    /// Case and surrounding whitespace only. Deliberately *not* stripping
    /// Gmail's dots or `+tags`: those rules are Gmail's alone, they are not
    /// true of most servers, and applying them everywhere would fold two
    /// genuinely different IMAP mailboxes into one id.
    static func canonical(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var description: String { rawValue }
}
