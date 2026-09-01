import SwiftUI
import GoogleSignIn

@main
struct EmailAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// Registering for push, receiving the token and being woken by one are
    /// all UIKit delegate callbacks with no SwiftUI equivalent.
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

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
    /// Files pulled out of messages, on tap and never before.
    @State private var attachments = AttachmentStore()
    /// Permission, the device token, and keeping Gmail's seven day watch
    /// from lapsing.
    @State private var push = PushService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(user)
                .environment(mail)
                .environment(chats)
                .environment(memory)
                .environment(searches)
                .environment(attachments)
                .environment(push)
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
                        // Where Gmail's log stands now, so the next catch-up
                        // knows what "new" means. Cheap, and only ever set
                        // once per connection.
                        if mail.syncCursor == nil { await mail.rememberCursor() }
                    }
                    // Whatever this account has that this phone does not.
                    // After the mail, because nothing on screen waits on it.
                    Task {
                        await chats.pull()
                        await memory.pull()
                        await searches.pull()
                    }
                    Analytics.record(.appOpened, ["mailbox": .bool(mail.isConnected)])

                    // The delegate is built by UIKit and cannot be handed
                    // dependencies, so it is given them here.
                    PushDelegate.mail = mail
                    PushDelegate.push = push

                    Task {
                        await push.refreshAuthorization()
                        // Gmail's watch lapses after seven days and then
                        // stops silently, which is how an email app's
                        // notifications die without anybody noticing.
                        // Renewing every launch is free.
                        if mail.isConnected { await push.startWatching(topic: PushService.topic) }
                    }
                }
                // Coming back to the app checks for new mail the cheap way:
                // one request that usually answers "nothing", instead of
                // listing the inbox and fetching twenty-five messages to
                // find that out.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await mail.catchUp() }
                }
        }
    }
}
