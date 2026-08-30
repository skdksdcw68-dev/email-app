import SwiftUI

@main
struct EmailAppApp: App {
    /// Onboarding state persists, so a returning user launches straight into
    /// the app. The mail store starts empty until an inbox is connected.
    @State private var user = UserStore()
    @State private var mail = MailStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(user)
                .environment(mail)
        }
    }
}
