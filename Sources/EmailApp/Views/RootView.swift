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
struct MainTabView: View {
    private enum AppTab: Hashable { case mail, settings }

    @State private var selection: AppTab = .mail

    var body: some View {
        TabView(selection: $selection) {
            MailTabView()
                .tabItem { Label("Mail", systemImage: "tray.fill") }
                .tag(AppTab.mail)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
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
