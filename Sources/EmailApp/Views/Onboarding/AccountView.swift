import SwiftUI

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

    /// Which provider is mid-flight, so only that button shows a spinner.
    @State private var pending: AppAccount.Provider?

    /// A struct rather than a tuple: Swift key paths cannot address tuple
    /// elements, so `ForEach(_, id: \.0)` does not compile.
    private struct ProviderOption: Identifiable {
        let provider: AppAccount.Provider
        let symbol: String
        var id: String { provider.rawValue }
    }

    private let providers: [ProviderOption] = [
        .init(provider: .apple, symbol: "apple.logo"),
        .init(provider: .google, symbol: "g.circle.fill"),
        .init(provider: .email, symbol: "envelope.fill"),
    ]

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
                ForEach(providers) { option in
                    Button {
                        pending = option.provider
                        Task {
                            await user.createAccount(with: option.provider)
                            pending = nil
                        }
                    } label: {
                        // The spinner replaces the label in place, on the button
                        // that was actually tapped. No ellipsis, and no second
                        // spinner floating underneath the stack.
                        Group {
                            if pending == option.provider {
                                ProgressView()
                            } else {
                                HStack(spacing: 10) {
                                    Image(systemName: option.symbol)
                                    Text("\(mode.verb) \(option.provider.title)")
                                        .fontWeight(.medium)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(pending != nil)
                }
            }
            .padding(.horizontal, 24)

            Text("By continuing you agree to our Terms and Privacy Policy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 20)
                .padding(.horizontal, 32)
                .padding(.bottom, 8)
        }
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
