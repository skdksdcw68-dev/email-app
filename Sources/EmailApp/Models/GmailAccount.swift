import Foundation

/// The connected Google account.
///
/// Today this is filled in by `MailStore.connect()` with a stub. When real
/// sign-in lands, this is what the OAuth flow produces -- nothing else in the
/// app needs to change.
struct GmailAccount: Identifiable, Hashable, Codable {
    var id = UUID()
    var email: String
    var displayName: String
    var connectedAt: Date

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
