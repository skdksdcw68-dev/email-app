import SwiftUI
import UIKit
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

    /// Every button is this tall and this round, Apple's included, so the stack
    /// reads as one set rather than three unrelated controls.
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
                providerButton(.google) { GoogleGlyph() }
                providerButton(.email) {
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
    }

    /// Apple's own control, which their guidelines require -- it owns the
    /// sheet, the localisation and the light/dark treatment. Its default corner
    /// radius is much tighter than the buttons beneath it, so it is clipped to
    /// match rather than left looking like a different control.
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
        .frame(height: buttonHeight)
        .clipShape(RoundedRectangle(cornerRadius: buttonRadius, style: .continuous))
    }

    /// Google and email are still stubs. Google needs a Cloud project and an
    /// iOS OAuth client id; email needs a backend. Both go through
    /// `UserStore.createAccount`, so wiring either one up is a change in that
    /// method and nowhere else.
    private func providerButton<Glyph: View>(
        _ provider: AppAccount.Provider,
        @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        Button {
            pending = provider
            Task {
                await user.createAccount(with: provider)
                pending = nil
            }
        } label: {
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
