import Foundation
import CryptoKit
import UIKit
import Supabase
import GoogleSignIn

/// Real authentication, through Supabase Auth.
///
/// All three providers end at the same place: a Supabase session. Apple and
/// Google both use native sign-in and hand Supabase the resulting ID token, so
/// neither opens a web view. Email uses Supabase's own password flow.
@MainActor
enum AuthService {

    // MARK: - Apple

    /// Apple's sign-in is replay-protected by a nonce: the app sends SHA256 of
    /// a random string in the request, Apple embeds that hash in the ID token,
    /// and Supabase is given the raw string to verify the two match. Skipping
    /// this makes a stolen token replayable.
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func signInWithApple(idToken: String, nonce: String) async throws -> User {
        let session = try await SupabaseClient.shared.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        return session.user
    }

    // MARK: - Google

    static func signInWithGoogle() async throws -> User {
        guard let presenter = rootViewController else {
            throw AuthError.noPresenter
        }

        // The SDK reads GIDClientID from Info.plist, so there is no client id
        // duplicated in code here.
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)

        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthError.missingIDToken
        }

        let session = try await SupabaseClient.shared.auth.signInWithIdToken(
            credentials: .init(
                provider: .google,
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        )
        return session.user
    }

    // MARK: - Gmail access

    /// A granted mailbox, separate from the Maily account. Signing into Maily
    /// with Google does *not* grant mailbox access -- that is a second, explicit
    /// consent with its own scopes, which is the whole point of keeping
    /// `AppAccount` and `MailAccount` apart.
    struct GmailSession {
        let email: String
        let displayName: String
        /// Their actual face, as Google holds it.
        ///
        /// 🔴 This was here all along and was being thrown away. `profile`
        /// carries the picture with the same `profile` scope that supplies the
        /// name -- no Contacts scope, no extra consent, nothing to ask for.
        /// The app was drawing a coloured letter next to a name it had taken
        /// from the very same object.
        ///
        /// ⚠️ Not the same question as a *sender's* avatar. `SenderAvatar`
        /// correctly says there is no photo to show for somebody who wrote to
        /// you, because that would need their Contacts entry. This is the
        /// person themselves, and they have already handed it over.
        let photoURL: URL?
        /// Whether this grant covers Google Contacts, which is what makes a
        /// *sender's* photograph possible. Optional by design -- see
        /// `GmailService.contactsScope`.
        let grantsContacts: Bool
        let accessToken: String
        /// The long-lived half. Kept in the Keychain under the mailbox id, so
        /// this app can refresh a mailbox the SDK is no longer holding -- see
        /// `TokenBroker` for why that matters.
        let refreshToken: String?
    }

    /// The size to ask Google for.
    ///
    /// Google crops and scales server-side from the `=sN-c` suffix, so asking
    /// for what is drawn costs a fraction of the bytes. The largest circle in
    /// the app is 64pt, which is 192px on a 3x screen; 256 covers it with room
    /// for a bigger one later and is still a few kilobytes.
    private static let photoPixels: UInt = 256

    static func connectGmail() async throws -> GmailSession {
        guard let presenter = rootViewController else { throw AuthError.noPresenter }

        // One code path whether or not a Google account is already signed in:
        // requesting the scopes here always produces a consent screen listing
        // exactly what Maily is asking for.
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: presenter,
            hint: nil,
            // Contacts is asked for here so there is one consent screen rather
            // than two -- but it is not checked for below, and declining it
            // only costs sender photographs.
            additionalScopes: GmailService.scopes + GmailService.optionalScopes
        )

        let granted = Set(result.user.grantedScopes ?? [])
        guard granted.isSuperset(of: Set(GmailService.scopes)) else {
            throw AuthError.scopesDeclined
        }
        guard let email = result.user.profile?.email else { throw AuthError.missingIDToken }

        return GmailSession(
            email: email,
            displayName: result.user.profile?.name ?? email,
            photoURL: result.user.profile?.imageURL(withDimension: Self.photoPixels),
            grantsContacts: granted.contains(GmailService.contactsScope),
            accessToken: result.user.accessToken.tokenString,
            refreshToken: result.user.refreshToken.tokenString
        )
    }

    /// Silently restores the previous Google sign-in, with no consent screen.
    /// Without this the app forgets the mailbox on every cold launch and the
    /// user has to reconnect each time they open it.
    static func restoreGmail() async -> GmailSession? {
        guard let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() else {
            return nil
        }
        // A restored session can come back without the Gmail scopes -- the
        // grant may have been revoked in the Google account settings.
        guard Set(user.grantedScopes ?? []).isSuperset(of: Set(GmailService.scopes)),
              let email = user.profile?.email
        else { return nil }

        try? await user.refreshTokensIfNeeded()
        return GmailSession(
            email: email,
            displayName: user.profile?.name ?? email,
            // Carried on the silent restore too, so a mailbox connected under
            // an older build picks its picture up on the next launch rather
            // than needing to be signed in again.
            photoURL: user.profile?.imageURL(withDimension: Self.photoPixels),
            grantsContacts: Set(user.grantedScopes ?? []).contains(GmailService.contactsScope),
            accessToken: user.accessToken.tokenString,
            refreshToken: user.refreshToken.tokenString
        )
    }

    /// Takes over a credential the SDK is currently holding.
    ///
    /// One job, once per mailbox: an install that connected under a build
    /// where GoogleSignIn kept the credential has nothing in the Keychain, and
    /// `TokenBroker` would otherwise conclude the mailbox needs connecting
    /// again. **Without this the upgrade signs everybody out.**
    ///
    /// Only answers for the account the SDK actually holds. `currentUser` is
    /// one session and it may not be the mailbox being asked about, and
    /// handing back another account's token would read the wrong mailbox --
    /// silently, and with entirely plausible-looking mail.
    struct AdoptedCredential {
        let accessToken: String
        let refreshToken: String
        let expires: Date
    }

    static func adoptSDKCredential(for account: MailAccount) async -> AdoptedCredential? {
        guard let user = GIDSignIn.sharedInstance.currentUser,
              let email = user.profile?.email,
              MailboxID.canonical(email) == account.address
        else { return nil }

        try? await user.refreshTokensIfNeeded()
        return AdoptedCredential(
            accessToken: user.accessToken.tokenString,
            refreshToken: user.refreshToken.tokenString,
            expires: user.accessToken.expirationDate ?? .now.addingTimeInterval(3000)
        )
    }

    // MARK: - Email

    static func signUpWithEmail(_ email: String, password: String) async throws -> User? {
        let response = try await SupabaseClient.shared.auth.signUp(email: email, password: password)
        // With email confirmation on, there is no session until the link is
        // opened -- the caller shows "check your inbox" rather than proceeding.
        return response.session?.user
    }

    static func signInWithEmail(_ email: String, password: String) async throws -> User {
        let session = try await SupabaseClient.shared.auth.signIn(email: email, password: password)
        return session.user
    }

    // MARK: - Session

    static func currentUser() async -> User? {
        try? await SupabaseClient.shared.auth.session.user
    }

    static func signOut() async {
        try? await SupabaseClient.shared.auth.signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    // MARK: - Helpers

    enum AuthError: LocalizedError {
        case noPresenter
        case missingIDToken
        case scopesDeclined
        case notConnected

        var errorDescription: String? {
            switch self {
            case .noPresenter: "Could not present the sign-in screen."
            case .missingIDToken: "The provider did not return an identity token."
            case .scopesDeclined: "Maily needs permission to read your mail and create drafts."
            case .notConnected: "No mailbox is connected."
            }
        }
    }

    /// Whether the Google session currently held covers Contacts.
    static var hasContactsAccess: Bool {
        guard let user = GIDSignIn.sharedInstance.currentUser else { return false }
        return Set(user.grantedScopes ?? []).contains(GmailService.contactsScope)
    }

    /// Asks for Contacts on top of a grant that already exists.
    ///
    /// 🔴 Incremental, not a re-sign-in. Everybody already using Maily granted
    /// their mail scopes under a build in which Contacts did not exist, and
    /// their grant can never contain it -- so without this the feature would
    /// only ever reach new accounts, and the existing ones would need to be
    /// disconnected and added again to get a photograph.
    ///
    /// `addScopes` widens the grant in place: the refresh token keeps working,
    /// the mailbox is not touched, and a refusal leaves everything exactly as
    /// it was.
    @discardableResult
    static func requestContactsAccess() async -> Bool {
        guard let presenter = rootViewController,
              let user = GIDSignIn.sharedInstance.currentUser
        else { return false }

        guard (try? await user.addScopes([GmailService.contactsScope], presenting: presenter)) != nil
        else { return false }

        return hasContactsAccess
    }

    /// The picture the signed-in provider currently holds, if any.
    ///
    /// Read from the live session rather than from anything stored, so it
    /// follows somebody changing their photo at Google. Nil for Apple and for
    /// email sign-in, which have none to give.
    static func currentProviderPhoto() async -> URL? {
        guard let session = try? await SupabaseClient.shared.auth.session else { return nil }
        return session.user.photoFromMetadata
    }

    private static var rootViewController: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    }
}

extension User {
    /// Supabase stores whatever the provider volunteered under user metadata.
    var displayNameFromMetadata: String? {
        for key in ["full_name", "name", "preferred_username"] {
            if let value = userMetadata[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    /// The picture the provider volunteered, if it did.
    ///
    /// Google writes `avatar_url` and `picture`; Apple writes neither, and
    /// email sign-in has nothing to write. Nil is the normal answer for two
    /// of the three providers, which is why nothing downstream may assume one
    /// exists.
    var photoFromMetadata: URL? {
        for key in ["avatar_url", "picture"] {
            if let value = userMetadata[key]?.stringValue,
               !value.isEmpty,
               let url = URL(string: value) {
                return url
            }
        }
        return nil
    }
}
