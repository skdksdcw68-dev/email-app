import SwiftUI

/// Comes before account creation on purpose: the user should understand what
/// Maily is before being asked to sign up for it. Returning users skip the
/// whole question run from here.
struct WelcomeView: View {
    @Environment(UserStore.self) private var user

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Text("Maily")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to Maily")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            Text("Your AI-powered email manager. It helps you understand, organize, and handle your inbox.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 32)

            Spacer()

            Button {
                user.startOnboarding()
            } label: {
                Text("Get started")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Button {
                user.goToSignIn()
            } label: {
                Text("Already have an account? **Sign in**")
                    .font(.subheadline)
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
    }
}

#Preview {
    WelcomeView().environment(UserStore(defaults: .previews, startAt: .welcome))
}
