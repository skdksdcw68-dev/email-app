import SwiftUI
import AuthenticationServices

/// Creating the Maily account, or signing back into an existing one.
///
/// This is the *app* account -- identity, subscription, AI preferences. It is
/// deliberately a separate step from connecting Gmail, which only grants
/// mailbox access. See `AppAccount`.
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
    }

    let mode: Mode

    @Environment(UserStore.self) private var user
    @Environment(\.colorScheme) private var colorScheme

    @State private var isWorkingWithGoogle = false
    @State private var authError: String?

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

            VStack(spacing: 10) {
                appleButton
                googleButton
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
    }

    /// Apple's own button. Not a re-creation -- using `SignInWithAppleButton`
    /// is required by Apple's guidelines, and it handles the sheet, the
    /// localisation and the light/dark treatment itself.
    private var appleButton: some View {
        SignInWithAppleButton(mode == .create ? .signUp : .signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    authError = "Apple returned an unexpected credential."
                    return
                }
                authError = nil
                user.signInWithApple(
                    userID: credential.user,
                    email: credential.email,
                    fullName: credential.fullName
                )

            case .failure(let error):
                // Cancelling is not an error worth showing.
                if (error as? ASAuthorizationError)?.code == .canceled { return }
                authError = error.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
    }

    /// Still a stub: real Google sign-in needs a Google Cloud project and an
    /// iOS OAuth client ID, which do not exist yet. The inbox connection on the
    /// next screen is the step that actually needs Google.
    private var googleButton: some View {
        Button {
            isWorkingWithGoogle = true
            Task {
                await user.createAccount(with: .google)
                isWorkingWithGoogle = false
            }
        } label: {
            Group {
                if isWorkingWithGoogle {
                    ProgressView()
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "g.circle.fill")
                        Text(mode == .create ? "Continue with Google" : "Sign in with Google")
                            .fontWeight(.medium)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isWorkingWithGoogle)
    }
}

#Preview("Create") {
    AccountView(mode: .create)
        .environment(UserStore(defaults: .previews, startAt: .createAccount))
}

#Preview("Sign in") {
    AccountView(mode: .signIn)
        .environment(UserStore(defaults: .previews, startAt: .signIn))
}
