import Foundation
import UserNotifications

/// Tells the person when Maily has answered something on their behalf.
///
/// Not optional, and deliberately not batched. The moment sending stops being
/// visible is the moment somebody stops knowing what their own address is
/// saying to people -- and that, not a bad reply, is what would actually make
/// this feature untrustworthy.
///
/// It carries who and what, never the reply. A notification on a lock screen
/// is the least private place in the app.
enum AutoReplyNotice {

    static func post(to recipient: String, subject: String) async {
        let centre = UNUserNotificationCenter.current()
        let settings = await centre.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
        else { return }

        let content = UNMutableNotificationContent()
        content.title = "Maily replied for you"
        let who = recipient.trimmingCharacters(in: .whitespaces)
        content.body = who.isEmpty
            ? "Re: \(subject)"
            : "To \(who) about \(subject)"
        content.sound = .default
        content.threadIdentifier = "auto-reply"

        // Straight away, and only once per reply.
        let request = UNNotificationRequest(
            identifier: "auto-reply-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await centre.add(request)
    }
}
