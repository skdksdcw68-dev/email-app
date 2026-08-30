import SwiftUI

struct RootView: View {
    @Environment(UserStore.self) private var user

    var body: some View {
        Group {
            if user.phase == .finished {
                MainTabView()
            } else {
                OnboardingFlowView()
            }
        }
        .animation(.snappy(duration: 0.3), value: user.phase == .finished)
    }
}

/// The app proper, once onboarding is done.
///
/// Four tabs, and deliberately no "Home": the Inbox already holds the main
/// content, and Apple's guidance warns against a redundant Home tab beside it.
/// Search and Compose are actions inside the Inbox, not destinations worth one
/// of four slots -- and the AI tags are layers inside the Inbox rather than
/// tabs of their own.
///
///   Inbox  = what needs attention
///   AI     = what Maily can do
///   People = who matters
///   You    = how Maily works
struct MainTabView: View {
    private enum AppTab: Hashable { case inbox, ai, people, you }

    @Environment(MailStore.self) private var mail
    @State private var selection: AppTab = .inbox

    var body: some View {
        TabView(selection: $selection) {
            InboxTabView()
                .tabItem { Label("Inbox", systemImage: "tray.full.fill") }
                // Unread count, the way every mail app marks the tab.
                // .badge renders nothing at zero, so no empty bubble.
                .badge(mail.unreadCount(in: .inbox))
                .tag(AppTab.inbox)

            AIView()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(AppTab.ai)

            PeopleView()
                .tabItem { Label("People", systemImage: "person.2.fill") }
                .tag(AppTab.people)

            YouView()
                .tabItem { Label("You", systemImage: "person.crop.circle.fill") }
                .tag(AppTab.you)
        }
    }
}

#Preview("Onboarding") {
    RootView()
        .environment(UserStore(defaults: .previews, startAt: .splash))
        .environment(MailStore())
}

#Preview("Signed in") {
    RootView()
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(MailStore.connected())
}
