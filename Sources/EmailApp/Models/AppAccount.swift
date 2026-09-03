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

    /// What they do, in their own words. "Freelance iOS developer", "Runs a
    /// bakery", "Second-year law student".
    ///
    /// Not decoration. It is the single most useful sentence about somebody
    /// when the assistant is judging what matters in their inbox and how to
    /// write on their behalf, and it is one line rather than the eleven
    /// questions Auto-Reply asks. Optional: an empty one is simply not sent.
    var occupation: String? = nil

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}
