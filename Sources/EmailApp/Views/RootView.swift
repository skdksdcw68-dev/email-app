import SwiftUI

struct RootView: View {
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

#Preview("Connected") {
    RootView().environment(MailStore.connected())
}

#Preview("Not connected") {
    RootView().environment(MailStore())
}
