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

        var errorDescription: String? {
            switch self {
            case .noPresenter: "Could not present the sign-in screen."
            case .missingIDToken: "The provider did not return an identity token."
            }
        }
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
}
