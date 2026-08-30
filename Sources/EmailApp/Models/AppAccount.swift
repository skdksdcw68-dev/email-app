import Foundation

/// The Maily account itself: who the customer is.
///
/// Deliberately separate from `GmailAccount`. This one identifies the person,
/// carries their subscription and their AI preferences, and survives them
/// disconnecting or switching inboxes. `GmailAccount` is only a grant of
/// access to one mailbox. A user could eventually connect several.
struct AppAccount: Identifiable, Hashable, Codable {
    enum Provider: String, Codable {
        case apple, google, email

        var title: String {
            switch self {
            case .apple: "Apple"
            case .google: "Google"
            case .email: "Email"
            }
        }
    }

    var id = UUID()
    var email: String
    var displayName: String
    var provider: Provider
    var createdAt: Date
    /// The provider's own stable identifier for this user -- Apple's
    /// `ASAuthorizationAppleIDCredential.user`, for example. Apple hands back
    /// the name and email only on the very first authorization, so this is the
    /// only field guaranteed to arrive on every subsequent sign-in.
    var externalID: String? = nil

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
