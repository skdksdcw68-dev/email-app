import UIKit
import UserNotifications

/// The three callbacks SwiftUI has no equivalent for.
///
/// Registering for push, receiving the device token, and being woken by a
/// silent push are all `UIApplicationDelegate` methods with no SwiftUI
/// counterpart, so there is an app delegate. It holds no state of its own;
/// everything it learns goes straight to the stores.
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate {

    /// Set by the app at launch, because a delegate is constructed by UIKit
    /// and cannot take dependencies in its initialiser.
    static weak var mail: MailStore?
    static var push: PushService?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        // Every mailbox, not the active one. APNs hands a token over about
        // once per install, so registering only what was in front at that
        // moment is why a second account never received anything.
        Self.push?.register(
            deviceToken: deviceToken,
            for: Self.mail?.registry.accounts ?? []
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Nothing to show. A simulator has no push, and a real failure is
        // fixed by launching again rather than by anything the reader can do.
    }

    /// Woken by a notification, visible or silent.
    ///
    /// Gmail's payload carries a history id and nothing else, so the work is
    /// the same either way: catch up, and let whatever arrived appear. iOS
    /// gives roughly thirty seconds, which is ample for one history call and
    /// a message or two.
    ///
    /// Reporting `.newData` versus `.noData` honestly matters: iOS uses it to
    /// decide how generous to be with future wake-ups, and an app that always
    /// claims new data gets throttled.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // Read here and passed on as plain values. The dictionary is not
        // something worth carrying any further than this line.
        await handle(
            historyID: userInfo["historyId"] as? String,
            address: userInfo["address"] as? String
        )
    }

    /// Which mailbox this notice is about.
    ///
    /// `address` is absent from the payload the deployed function sends
    /// today, and the fallback is the active mailbox — which is exactly what
    /// the app did before. That is what lets this ship *before* the function
    /// changes: there is no moment where a deployed function is sending
    /// something the installed app cannot read, or the reverse.
    private func handle(historyID: String?, address: String?) async -> UIBackgroundFetchResult {
        guard let mail = Self.mail else { return .noData }

        let account = address.flatMap { mail.registry.account(forAddress: $0) } ?? mail.account
        guard let account else { return .noData }

        if Self.push?.isRepeat(of: historyID, for: account.id) == true {
            Self.push?.noteWoken(found: 0)
            return .noData
        }

        // The mailbox in front of the person goes through the store, which
        // has its mail loaded and its caches warm. Any other one must not:
        // `MailStore` is bound to the active mailbox and every scoped store
        // it touches is pointed at that mailbox's suite.
        let arrived: [Message]
        if account.id == mail.account?.id {
            arrived = await mail.catchUp()
        } else {
            arrived = await BackgroundCatchUp.run(for: account)
        }

        // Recorded whether or not anything came of it. "A push arrived and
        // there was nothing new" and "no push ever arrived" are different
        // problems with the same symptom, and this is what tells them apart.
        Self.push?.noteWoken(found: arrived.count)

        guard !arrived.isEmpty else { return .noData }

        await Self.announce(arrived, from: account, amongSeveral: mail.registry.hasSeveral)
        return .newData
    }

    /// Puts what arrived on the lock screen, written from the message itself.
    ///
    /// The notification is composed here rather than on a server, which is
    /// the whole reason the push that woke this app is silent: the sender and
    /// the subject never had to leave the phone to end up on its own screen.
    /// `amongSeveral` decides whether the mailbox is named. With one
    /// connected, saying which mailbox it came from is noise on every single
    /// banner; with two, leaving it out means a work email and a personal one
    /// look identical on a lock screen.
    private static func announce(
        _ messages: [Message],
        from account: MailAccount,
        amongSeveral: Bool
    ) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional else { return }

        // Three at most. Six arriving at once is a summary, not six banners.
        for message in messages.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = message.sender.name.isEmpty
                ? message.sender.address
                : message.sender.name
            content.body = message.subject.isEmpty ? "(No subject)" : message.subject

            // The mailbox wins the subtitle when there is a choice to make.
            // Which account this landed in changes what somebody does about
            // it far more than a one-line summary does.
            if amongSeveral {
                content.subtitle = account.title
            } else if let summary = message.aiSummary, !summary.isEmpty {
                content.subtitle = summary
            }

            content.sound = .default
            // Threaded per mailbox as well as per conversation, so two
            // accounts in the same thread do not stack into one another.
            content.threadIdentifier = "\(account.id.rawValue).\(message.threadID ?? "maily")"
            content.userInfo = [
                "messageID": message.id.uuidString,
                "mailbox": account.id.rawValue,
            ]

            try? await center.add(
                UNNotificationRequest(
                    identifier: message.remoteID ?? message.id.uuidString,
                    content: content,
                    trigger: nil
                )
            )
        }

        if messages.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = amongSeveral ? account.title : "Maily"
            content.body = "\(messages.count - 3) more arrived."
            content.sound = nil
            content.userInfo = ["mailbox": account.id.rawValue]
            try? await center.add(
                // Per mailbox. A fixed identifier meant two accounts'
                // overflow banners replaced each other, so the second one to
                // arrive was the only one anybody saw.
                UNNotificationRequest(
                    identifier: "maily.more.\(account.id.rawValue)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}
