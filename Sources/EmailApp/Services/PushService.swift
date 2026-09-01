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

    /// Gmail republishes the same notification for a while, and the app is
    /// woken for each. This is the last history id acted on, so the same
    /// arrival is not fetched three times.
    private var lastHandled: String?

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

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if isAuthorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    // MARK: - The token

    /// Called from the app delegate when APNs answers.
    func register(deviceToken data: Data, gmailAddress: String?) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        token = hex
        guard let gmailAddress, !gmailAddress.isEmpty else { return }

        // Read on this side of the hop. Everything the upload needs is a
        // plain value, so the detached task carries values rather than
        // reaching back into an actor it is not on.
        let address = gmailAddress.lowercased()
        let environment = Self.environment
        let bundle = Bundle.main.bundleIdentifier ?? ""

        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = DeviceRow(
                token: hex,
                user_id: userID,
                gmail_address: address,
                environment: environment,
                bundle_id: bundle,
                updated_at: .now
            )
            try? await Backend.upsert("devices", [row])
        }
    }

    private struct DeviceRow: Encodable {
        let token: String
        let user_id: UUID
        let gmail_address: String
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
    func startWatching(topic: String) async {
        guard !topic.isEmpty else { return }
        do {
            let accessToken = try await AuthService.currentGmailAccessToken()
            try await GmailService.watch(topic: topic, accessToken: accessToken)
        } catch {
            // Not surfaced. Notifications quietly not starting is bad, but a
            // banner about Pub/Sub on somebody's inbox is worse, and the
            // retry is the next launch.
            lastError = error.localizedDescription
        }
    }

    /// True when this history id has already been dealt with.
    func isRepeat(of historyID: String?) -> Bool {
        guard let historyID else { return false }
        defer { lastHandled = historyID }
        return lastHandled == historyID
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
