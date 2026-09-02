import SwiftUI

struct RootView: View {
    @State private var appearance = AppSettings.appearance

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
        // Applied here so the choice reaches every screen, sheets included.
        .preferredColorScheme(appearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .appearanceChanged)) { _ in
            appearance = AppSettings.appearance
        }
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
                // .badge renders nothing at an empty string, so no bubble at
                // zero -- and nothing past 99, because a four-digit bubble
                // is a smear, not a number.
                .badge(unreadBadge)
                .tag(AppTab.inbox)

            AITabView()
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

    /// A dictionary lookup, not a count of the mailbox.
    ///
    /// This sits in the tab container's body, so it is read on every tab
    /// switch and after every classified email -- and it used to filter and
    /// sort every message held to get the number, which is most of why
    /// moving between tabs stuttered. `MailboxIndex` keeps it now.
    private var unreadBadge: String {
        let count = mail.unreadCount(in: .inbox)
        if count == 0 { return "" }
        return count > 99 ? "99+" : "\(count)"
    }
}

#Preview("Onboarding") {
    RootView()
        .environment(UserStore(defaults: .previews, startAt: .splash))
        .environment(MailStore())
        .environment(SearchHistory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-searches.json")))
}

#Preview("Signed in") {
    RootView()
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(MailStore.connected())
        .environment(SearchHistory(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-searches.json")))
}
