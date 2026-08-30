import SwiftUI
import UIKit

/// Drives the first-run flow:
///
///   splash -> welcome -> 8 questions -> create account -> connect inbox
///
/// A returning user taps "Sign in" on welcome and skips straight past the
/// questions -- they answered them the first time.
struct OnboardingFlowView: View {
    @Environment(UserStore.self) private var user

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .transition(.opacity)

            if user.canGoBack {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { user.back() }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .padding(.leading, 16)
                .accessibilityLabel("Back")
            }
        }
        .animation(.snappy(duration: 0.25), value: user.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch user.phase {
        case .splash:
            SplashView()

        case .welcome:
            WelcomeView()
                .padding(.top, 44)

        case .question(let index):
            // Guard the index: a persisted phase could outlive a question being
            // removed from the set.
            if index < user.questions.count {
                QuestionView(question: user.questions[index])
                    .padding(.top, 44)
            } else {
                AccountView(mode: .create).padding(.top, 44)
            }

        case .createAccount:
            AccountView(mode: .create)
                .padding(.top, 44)

        case .signIn:
            AccountView(mode: .signIn)
                .padding(.top, 44)

        case .connectInbox:
            ConnectInboxView()

        case .finished:
            // RootView swaps this whole view out; nothing should render here.
            Color.clear
        }
    }
}

#Preview("Splash") {
    OnboardingFlowView()
        .environment(UserStore(defaults: .previews, startAt: .splash))
        .environment(MailStore())
}

#Preview("Welcome") {
    OnboardingFlowView()
        .environment(UserStore(defaults: .previews, startAt: .welcome))
        .environment(MailStore())
}

#Preview("Question") {
    OnboardingFlowView()
        .environment(UserStore(defaults: .previews, startAt: .question(0)))
        .environment(MailStore())
}
