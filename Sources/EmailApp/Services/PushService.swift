import Foundation
import UIKit
import UserNotifications

/// Push notifications, from the phone's side.
///
/// Three jobs: ask for permission, hand the device token to the backend so
/// something can reach this phone, and tell Gmail to start publishing when
/// mail arrives.
///
/// Gmail's part expires. `users.watch` lasts seven days and then stops
/// silently, which is the classic way an email app's notifications die
/// without anybody noticing, so it is renewed on every launch. Renewing
/// early is free; renewing late means a week of no notifications.
@MainActor
@Observable
final class PushService: NSObject {

    /// The Pub/Sub topic Gmail publishes to, in the project that owns the
    /// OAuth client. Not a secret: it names a noticeboard only Google can
    /// post to and only this project's subscription can read.
    static let topic = "projects/maily-507113/topics/maily-gmail"

    private(set) var isAuthorized = false
    private(set) var lastError: String?

    /// The token APNs handed this install, once it has.
    private(set) var token: String?

    /// When a push last woke the app, and what happened.
    ///
    /// Diagnostics, shown in Settings. Without it "no notification" has four
    /// possible causes that all look identical from the outside: permission,
    /// the token, Pub/Sub, or the app finding nothing new to announce. This
    /// separates the first two from the last two.
    private(set) var lastPushAt: Date?
    private(set) var lastPushResult: String?

    func noteWoken(found: Int) {
        lastPushAt = .now
        lastPushResult = found == 0 ? "Nothing new" : "\(found) new"
    }

    /// Gmail republishes the same notification for a while, and the app is
    /// woken for each. This is the last history id acted on, so the same
    /// arrival is not fetched three times.
    private var lastHandled: [MailboxID: String] = [:]

    // MARK: - Permission

    /// Asks once. iOS only shows the prompt the first time; after that this
    /// reports what was decided, which is what the settings screen needs.
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            isAuthorized = granted
            guard granted else { return }
            // Registering is what produces the token, and it has to happen on
            // the main thread.
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Ask, then start Gmail publishing. The whole sequence, in the order it
    /// has to happen.
    ///
    /// Watching starts even if they decline the alerts: a silent push still
    /// wakes the app and brings the mail in, which is worth having on its own.
    /// Only the banner needs permission.
    func enable(topic: String, for accounts: [MailAccount]) async {
        await requestPermission()
        await startWatchingAll(topic: topic, accounts: accounts)
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if isAuthorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    // MARK: - The token

    /// Called from the app delegate when APNs answers, and again whenever the
    /// set of mailboxes changes.
    ///
    /// **A row per mailbox, not per active mailbox.** This took the active
    /// account before, and APNs hands a token over roughly once per install
    /// — so whichever mailbox happened to be in front at that moment was the
    /// only one that ever got a row, and every account added afterwards
    /// received nothing. The failure was silence, which is why it survived
    /// this long.
    func register(deviceToken data: Data, for accounts: [MailAccount]) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        token = hex
        register(for: accounts)
    }

    /// Re-registers with the token already held. Called when a mailbox is
    /// added, because by then APNs has long since handed its token over and
    /// will not do it again.
    func register(for accounts: [MailAccount]) {
        guard let hex = token else { return }

        // Read on this side of the hop. Everything the upload needs is a
        // plain value, so the detached task carries values rather than
        // reaching back into an actor it is not on.
        let rows = accounts.filter(\.canPush).map {
            (address: $0.address, mailbox: $0.id.rawValue, provider: $0.provider.rawValue)
        }
        guard !rows.isEmpty else { return }

        let environment = Self.environment
        let bundle = Bundle.main.bundleIdentifier ?? ""

        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let payload = rows.map {
                DeviceRow(
                    token: hex,
                    user_id: userID,
                    address: $0.address,
                    provider: $0.provider,
                    mailbox_id: $0.mailbox,
                    environment: environment,
                    bundle_id: bundle,
                    updated_at: .now
                )
            }
            // On the pair, not the token. Merging on the token alone is what
            // made a second mailbox overwrite the first instead of joining it.
            try? await Backend.upsert("devices", payload, onConflict: "token,address")
        }
    }

    /// Drops one mailbox's row, leaving the others. Called when a mailbox is
    /// disconnected — without it the phone keeps being woken for an account
    /// the app no longer has.
    func forget(_ account: MailAccount) {
        guard let hex = token else { return }
        let address = account.address
        Task.detached(priority: .background) {
            try? await Backend.deleteDevice(token: hex, address: address)
        }
    }

    private struct DeviceRow: Encodable {
        let token: String
        let user_id: UUID
        let address: String
        let provider: String
        let mailbox_id: String
        let environment: String
        let bundle_id: String
        let updated_at: Date
    }

    /// A build from Xcode gets a sandbox token; anything through TestFlight or
    /// the App Store gets a production one. The server has to know which,
    /// because APNs has a different host for each and the wrong one fails as
    /// though the token were bad.
    /// Nonisolated: it is a compile-time constant, and anything that needs it
    /// is on its way off the main actor by definition.
    nonisolated private static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    // MARK: - Telling Gmail to publish

    /// Starts, or renews, Gmail's watch on this mailbox.
    ///
    /// Safe to call on every launch: Gmail treats a repeat call as a renewal
    /// rather than an error, and the seven day expiry is the whole reason to.
    func startWatching(topic: String, for account: MailAccount?) async {
        guard !topic.isEmpty, let account, account.canPush else { return }
        do {
            let backend = GmailBackend(account: account)
            let registration = try await backend.startPush(to: .pubSub(topic: topic))
            watching[account.id] = .now

            // Gmail hands back where the mailbox stands, and the app used to
            // throw it away. It is the right starting cursor for a mailbox
            // that has only just been watched -- without it the first notice
            // after connecting has nothing to compare against and announces
            // nothing.
            if let checkpoint = registration.checkpoint {
                let suite = MailboxScope.defaults(for: account.id)
                if suite.string(forKey: "mail.historyId") == nil {
                    suite.set(checkpoint.token, forKey: "mail.historyId")
                }
            }
        } catch {
            // Not surfaced. Notifications quietly not starting is bad, but a
            // banner about Pub/Sub on somebody's inbox is worse, and the
            // retry is the next launch.
            lastError = error.localizedDescription
        }
    }

    /// Every mailbox that can be watched, not just the one in front of you.
    ///
    /// Gmail's watch expires in seven days and renews by being called again,
    /// which the app did on every launch — for the active mailbox only. So
    /// every other account went quiet after a week, and silently, because a
    /// failure here is deliberately not surfaced.
    func startWatchingAll(topic: String, accounts: [MailAccount]) async {
        for account in accounts where account.canPush {
            await startWatching(topic: topic, for: account)
        }
    }

    /// When each mailbox's watch was last established.
    ///
    /// Kept so a lapse is detectable at all. There was no record of this
    /// before, so a watch that stopped being renewed looked exactly like a
    /// mailbox with no new mail.
    private(set) var watching: [MailboxID: Date] = [:]

    /// True when this history id has already been dealt with **for this
    /// mailbox**.
    ///
    /// One slot was wrong in both directions. Gmail history ids are
    /// per-mailbox monotonic sequences from independent namespaces, so two
    /// mailboxes interleaving defeated the dedup entirely — and a notice for
    /// B whose id happened to match A's last was swallowed as a repeat.
    func isRepeat(of historyID: String?, for mailbox: MailboxID?) -> Bool {
        guard let historyID, let mailbox else { return false }
        defer { lastHandled[mailbox] = historyID }
        return lastHandled[mailbox] == historyID
    }
}

extension PushService: UNUserNotificationCenterDelegate {
    /// Show it even while the app is open. An email arriving while somebody
    /// is reading a different one is still news.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
