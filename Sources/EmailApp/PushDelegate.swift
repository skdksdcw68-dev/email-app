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
        Self.push?.register(deviceToken: deviceToken, gmailAddress: Self.mail?.account?.address)
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
        // Read here and passed on as a string. The dictionary is not
        // something worth carrying any further than this line.
        await handle(historyID: userInfo["historyId"] as? String)
    }

    private func handle(historyID: String?) async -> UIBackgroundFetchResult {
        if Self.push?.isRepeat(of: historyID) == true {
            Self.push?.noteWoken(found: 0)
            return .noData
        }
        guard let mail = Self.mail else { return .noData }

        let arrived = await mail.catchUp()
        // Recorded whether or not anything came of it. "A push arrived and
        // there was nothing new" and "no push ever arrived" are different
        // problems with the same symptom, and this is what tells them apart.
        Self.push?.noteWoken(found: arrived.count)

        guard !arrived.isEmpty else { return .noData }

        await Self.announce(arrived)
        return .newData
    }

    /// Puts what arrived on the lock screen, written from the message itself.
    ///
    /// The notification is composed here rather than on a server, which is
    /// the whole reason the push that woke this app is silent: the sender and
    /// the subject never had to leave the phone to end up on its own screen.
    private static func announce(_ messages: [Message]) async {
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
            if let summary = message.aiSummary, !summary.isEmpty {
                content.subtitle = summary
            }
            content.sound = .default
            content.threadIdentifier = message.threadID ?? "maily"
            content.userInfo = ["messageID": message.id.uuidString]

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
            content.title = "Maily"
            content.body = "\(messages.count - 3) more arrived."
            content.sound = nil
            try? await center.add(
                UNNotificationRequest(identifier: "maily.more", content: content, trigger: nil)
            )
        }
    }
}
