import SwiftUI

/// Drives the first-run flow:
///
///   splash -> welcome -> 8 questions -> create account -> connect inbox
///
/// A returning user taps "Sign in" on welcome and skips straight past the
/// questions -- they answered them the first time.
struct OnboardingFlowView: View {
    @Environment(UserStore.self) private var user

    var body: some View {
        if user.phase == .splash {
            // The splash is a brand moment: no chrome, no navigation bar.
            SplashView()
        } else {
            NavigationStack {
                content
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // The conditional lives inside the item, not around it:
                        // ToolbarItem's content is a plain @ViewBuilder, which
                        // handles `if` reliably.
                        ToolbarItem(placement: .topBarLeading) {
                            if user.canGoBack {
                                Button {
                                    user.back()
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .fontWeight(.semibold)
                                }
                                .accessibilityLabel("Back")
                            }
                        }
                    }
                    .animation(.snappy(duration: 0.25), value: user.phase)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch user.phase {
        case .welcome:
            WelcomeView()

        case .question(let index):
            // Guard the index: a persisted phase could outlive a question being
            // removed from the set.
            if index < user.questions.count {
                QuestionView(question: user.questions[index])
            } else {
                AccountView(mode: .create)
            }

        case .createAccount:
            AccountView(mode: .create)

        case .signIn:
            AccountView(mode: .signIn)

        case .connectInbox:
            ConnectInboxView()

        case .splash, .finished:
            // .splash is handled above; RootView swaps this view out on .finished.
            Color.clear
        }
    }
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

#Preview("Connect") {
    OnboardingFlowView()
        .environment(UserStore(defaults: .previews, startAt: .connectInbox))
        .environment(MailStore())
}
