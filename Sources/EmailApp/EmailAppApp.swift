import SwiftUI
import GoogleSignIn

@main
struct EmailAppApp: App {
    /// Onboarding state persists, so a returning user launches straight into
    /// the app after the splash. The mail store starts empty until an inbox is
    /// connected.
    @State private var user = UserStore()
    @State private var mail = MailStore()
    /// Past conversations with Maily. Kept on this device and mirrored to the
    /// account, so they follow it to another phone. Clears itself, on both,
    /// when the mailbox is disconnected.
    @State private var chats = ChatHistory()
    /// What Maily has been told to remember about the person.
    @State private var memory = AIMemory()
    /// What they have looked for, so looking again is one tap.
    @State private var searches = SearchHistory()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(user)
                .environment(mail)
                .environment(chats)
                .environment(memory)
                .environment(searches)
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
                    // Whatever this account has that this phone does not.
                    // After the mail, because nothing on screen waits on it.
                    Task {
                        await chats.pull()
                        await memory.pull()
                        await searches.pull()
                    }
                    Analytics.record(.appOpened, ["mailbox": .bool(mail.isConnected)])
                }
        }
    }
}
