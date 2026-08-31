import SwiftUI
import GoogleSignIn

@main
struct EmailAppApp: App {
    /// Onboarding state persists, so a returning user launches straight into
    /// the app after the splash. The mail store starts empty until an inbox is
    /// connected.
    @State private var user = UserStore()
    @State private var mail = MailStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(user)
                .environment(mail)
                // Google redirects back through the reversed-client-id URL
                // scheme declared in Info.plist; the SDK completes the flow.
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                // Re-establish the Google session silently, so a cold launch
                // does not look like being signed out.
                .onAppear {
                    Task {
                        // Disk first, so mail is on screen before the network
                        // is even reached, then top it up.
                        await mail.loadArchive()
                        await mail.restore()
                    }
                }
        }
    }
}
