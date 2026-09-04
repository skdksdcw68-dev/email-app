import SwiftUI
import UIKit
import AuthenticationServices

/// Creating the Maily account, or signing back into an existing one.
///
/// This is the *app* account -- identity, subscription, AI preferences. It is
/// deliberately a separate step from connecting Gmail, which only grants
/// mailbox access. See `AppAccount`.
///
/// All three providers are real, and all three end at a Supabase session.
struct AccountView: View {
    enum Mode {
        case create, signIn

        var title: String {
            switch self {
            case .create: "Create your account"
            case .signIn: "Welcome back"
            }
        }

        var subtitle: String {
            switch self {
            case .create: "This saves your preferences and keeps your AI set up the way you like it."
            case .signIn: "Sign in to pick up where you left off."
            }
        }

        var verb: String {
            switch self {
            case .create: "Continue with"
            case .signIn: "Sign in with"
            }
        }
    }

    let mode: Mode

    @Environment(UserStore.self) private var user
    @Environment(\.colorScheme) private var colorScheme

    @State private var pending: AppAccount.Provider?
    @State private var authError: String?
    @State private var isShowingEmail = false
    /// The raw nonce for the in-flight Apple request; Supabase needs it to
    /// verify the hash Apple embedded in the identity token.
    @State private var appleNonce: String?

    private let buttonHeight: CGFloat = 52
    private let buttonRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text(mode.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(mode.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 11) {
                appleButton

                providerButton(.google, action: signInWithGoogle) { GoogleGlyph() }

                providerButton(.email, action: { isShowingEmail = true }) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.tint)
                        .frame(width: 19)
                }
            }
            .padding(.horizontal, 24)

            if let authError {
                Text(authError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 32)
            }

            Text("By continuing you agree to our Terms and Privacy Policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $isShowingEmail) {
            EmailAuthView(mode: mode)
                .closesOnlyOnPurpose()
        }
    }

    // MARK: - Apple

    /// Apple's own control, which their guidelines require -- it owns the
    /// sheet, the localisation and the light/dark treatment. Its default corner
    /// radius is tighter than the buttons beneath it, so it is clipped to match.
    private var appleButton: some View {
        SignInWithAppleButton(mode == .create ? .signUp : .signIn) { request in
            let nonce = AuthService.makeNonce()
            appleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            // Apple embeds this hash in the identity token; Supabase compares
            // it against the raw nonce we send. Without it a stolen token is
            // replayable.
            request.nonce = AuthService.sha256(nonce)
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                handleApple(authorization)
            case .failure(let error):
                // Cancelling is not an error worth showing.
                if (error as? ASAuthorizationError)?.code == .canceled { return }
                authError = error.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: buttonHeight)
        .clipShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
        .disabled(pending != nil)
    }

    private func handleApple(_ authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = appleNonce
        else {
            authError = "Apple did not return a usable identity token."
            return
        }

        // Apple sends the name only on the first authorization, so capture it
        // here rather than relying on Supabase metadata later.
        let name = credential.fullName
            .map { PersonNameComponentsFormatter().string(from: $0) }
            .flatMap { $0.isEmpty ? nil : $0 }

        authError = nil
        pending = .apple
        Task {
            do {
                let supabaseUser = try await AuthService.signInWithApple(idToken: idToken, nonce: nonce)
                user.completeSignIn(
                    userID: supabaseUser.id.uuidString,
                    email: supabaseUser.email ?? credential.email,
                    displayName: name ?? supabaseUser.displayNameFromMetadata,
                    provider: .apple
                )
            } catch {
                authError = error.localizedDescription
            }
            pending = nil
        }
    }

    // MARK: - Google

    private func signInWithGoogle() {
        authError = nil
        pending = .google
        Task {
            do {
                let supabaseUser = try await AuthService.signInWithGoogle()
                user.completeSignIn(
                    userID: supabaseUser.id.uuidString,
                    email: supabaseUser.email,
                    displayName: supabaseUser.displayNameFromMetadata,
                    provider: .google
                )
            } catch {
                // The SDK throws on a user-cancelled sheet too; that is not
                // worth a red error line.
                if !isCancellation(error) {
                    authError = error.localizedDescription
                }
            }
            pending = nil
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.google.GIDSignIn" && nsError.code == -5
    }

    // MARK: - Chrome

    private func providerButton<Glyph: View>(
        _ provider: AppAccount.Provider,
        action: @escaping () -> Void,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        Button(action: action) {
            Group {
                if pending == provider {
                    ProgressView()
                } else {
                    HStack(spacing: 11) {
                        glyph()
                        Text("\(mode.verb) \(provider.title)")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: buttonHeight)
            .background {
                RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: buttonRadius, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(pending != nil)
    }
}

#Preview("Create") {
    AccountView(mode: .create)
        .environment(UserStore(defaults: .previews, startAt: .createAccount))
}

#Preview("Sign in — dark") {
    AccountView(mode: .signIn)
        .environment(UserStore(defaults: .previews, startAt: .signIn))
        .preferredColorScheme(.dark)
}
