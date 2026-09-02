import SwiftUI
import GoogleSignIn
import UIKit

@main
struct EmailAppApp: App {

    init() {
        // The tab badge is drawn by UIKit, not SwiftUI, so its text cannot be
        // styled where it is set. The default size is heavy beside the tab
        // labels. Set through the appearance proxy instead, which the system
        // is free to ignore on a version that draws its own badge -- and
        // does no harm where it does.
        UITabBarItem.appearance().setBadgeTextAttributes(
            [.font: UIFont.systemFont(ofSize: 11, weight: .semibold)], for: .normal
        )
    }

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
    /// What Maily has been authorised to answer on the person's behalf.
    @State private var autoReply = AutoReplyStore()
    /// The replies Auto-Reply has written, and every decision behind them.
    @State private var autoReplyQueue = AutoReplyQueue()

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
                .environment(autoReply)
                .environment(autoReplyQueue)
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

                        // And whether the three months it claims to hold are
                        // actually here. Once a day, in the background.
                        await mail.verifyAgainstGmail()

                        // Then whatever Auto-Reply has been authorised to
                        // answer. After the mail is in, so it is looking at
                        // what actually arrived.
                        await mail.runAutoReply(
                            config: autoReply.config,
                            briefing: autoReply.briefing(),
                            queue: autoReplyQueue
                        )

                        // Asked here, after `restore()`, because there has to
                        // be a mailbox before "let Maily notify you" means
                        // anything. Asking at cold launch, before the account
                        // is back, is a prompt about nothing.
                        if mail.isConnected {
                            await push.enable(topic: PushService.topic)
                        }
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

                    Task { await push.refreshAuthorization() }
                }
                // Connecting a mailbox later is the other way in. Without
                // this, somebody who signs in on their second launch is never
                // asked at all.
                .onChange(of: mail.isConnected) { _, connected in
                    guard connected else { return }
                    Task { await push.enable(topic: PushService.topic) }
                }
                // Coming back to the app checks for new mail the cheap way:
                // one request that usually answers "nothing", instead of
                // listing the inbox and fetching twenty-five messages to
                // find that out.
                .onChange(of: scenePhase) { _, phase in
                    // Classifications are written a batch at a time rather
                    // than a message at a time, so leaving mid-pass would
                    // otherwise lose the last few and pay for them again.
                    if phase != .active { ClassificationCache.flush() }
                    guard phase == .active else { return }
                    Task {
                        await mail.catchUp()
                        await mail.runAutoReply(
                            config: autoReply.config,
                            briefing: autoReply.briefing(),
                            queue: autoReplyQueue
                        )
                    }
                }
        }
    }
}
