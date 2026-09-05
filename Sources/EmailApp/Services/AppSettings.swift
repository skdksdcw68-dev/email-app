import SwiftUI

/// Settings that actually change what the app does.
///
/// The AI switches on the You tab were previously `@State` on the view: they
/// moved, they looked live, and they were wired to nothing at all. Anything
/// offered as a setting here is read by the code that does the work.
enum AppSettings {
    // MARK: - Appearance

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }

        var title: String {
            switch self {
            case .system: "System"
            case .light:  "Light"
            case .dark:   "Dark"
            }
        }

        var symbol: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light:  "sun.max.fill"
            case .dark:   "moon.fill"
            }
        }

        /// `nil` follows the device, which is what "System" means.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light:  .light
            case .dark:   .dark
            }
        }
    }

    static var appearance: Appearance {
        get {
            UserDefaults.standard.string(forKey: "settings.appearance")
                .flatMap(Appearance.init(rawValue:)) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "settings.appearance"); SettingsSync.notify(.app) }
    }

    // MARK: - AI

    /// Whether the model gets to look at incoming mail at all. Off means the
    /// rules still tag it -- those are local and free -- but nothing is sent
    /// anywhere and nothing is charged.
    static var tagsIncomingMail: Bool {
        get { UserDefaults.standard.object(forKey: "settings.aiTagging") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.aiTagging"); SettingsSync.notify(.app) }
    }

    /// Whether opening a message asks for a summary of it.
    static var writesSummaries: Bool {
        get { UserDefaults.standard.object(forKey: "settings.aiSummaries") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.aiSummaries"); SettingsSync.notify(.app) }
    }

    // MARK: - Notifications
    //
    // Per type, because "notifications" is not one thing. Mail arriving is
    // constant and skippable; a reply Maily sent on somebody's behalf is
    // neither, and somebody who wants the second without the first had no way
    // to say so -- there was not a single switch on the notifications screen.

    /// A banner when new mail arrives.
    static var notifiesNewMail: Bool {
        get { UserDefaults.standard.object(forKey: "settings.notify.mail") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.notify.mail"); SettingsSync.notify(.app) }
    }

    /// A banner when Auto-Reply has sent something for you.
    ///
    /// Defaults on and should stay that way: `AutoReplyNotice` exists because
    /// mail going out under somebody's name without them seeing it first is
    /// the one thing in this app they must always be told about.
    static var notifiesAutoReply: Bool {
        get { UserDefaults.standard.object(forKey: "settings.notify.autoReply") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.notify.autoReply"); SettingsSync.notify(.app) }
    }

    /// Only mail Maily judged urgent or needing a reply.
    static var notifiesOnlyImportant: Bool {
        get { UserDefaults.standard.object(forKey: "settings.notify.importantOnly") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "settings.notify.importantOnly"); SettingsSync.notify(.app) }
    }

    /// Whether Maily keeps what it is told about the person.
    ///
    /// Off does not delete anything -- it stops what is stored being sent, and
    /// stops new things being added. Somebody turning this off for an
    /// afternoon should not come back to an empty page, and the difference
    /// between "paused" and "erased" is the whole reason there is also a
    /// Forget everything button.
    static var remembersThings: Bool {
        get { UserDefaults.standard.object(forKey: "settings.memory") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.memory"); SettingsSync.notify(.app) }
    }

    /// Extra guidance handed to the model whenever it writes for the user.
    ///
    /// **Per mailbox.** The voice is the thing most obviously tied to who is
    /// receiving the mail -- "sign off with just my first name" is right from
    /// a personal address and wrong from a company one. `MailboxScope.defaults`
    /// rather than `.standard`, so each address carries its own.
    static var customInstructions: String {
        get { MailboxScope.defaults.string(forKey: "settings.customInstructions") ?? "" }
        set {
            MailboxScope.defaults.set(newValue, forKey: "settings.customInstructions")
            SettingsSync.notify(.writing)
        }
    }

    /// The tone this mailbox writes in, as a `WritingTone` raw value.
    ///
    /// Nil until somebody sets one here, and the onboarding answer is what
    /// fills the gap -- so a newly connected mailbox starts in the voice they
    /// already chose rather than in a default nobody picked. `UserStore`
    /// resolves the two; this is only the override.
    static var mailboxTone: String? {
        get { MailboxScope.defaults.string(forKey: "settings.tone") }
        set {
            MailboxScope.defaults.set(newValue, forKey: "settings.tone")
            SettingsSync.notify(.writing)
        }
    }

    /// Whether the "AI search costs more" notice has been shown. It is worth
    /// saying once and never again: a warning on every search is a warning
    /// nobody reads.
    static var hasSeenAISearchNotice: Bool {
        get { UserDefaults.standard.bool(forKey: "settings.aiSearchNotice") }
        set { UserDefaults.standard.set(newValue, forKey: "settings.aiSearchNotice") }
    }

    // MARK: - Privacy

    /// Whether conversations with the assistant follow the account to another
    /// device. Off keeps them on this phone, where they used to live.
    static var syncsChats: Bool {
        get { UserDefaults.standard.object(forKey: "settings.syncsChats") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.syncsChats"); SettingsSync.notify(.app) }
    }

    /// Whether the app reports how it is used: which features get opened,
    /// how often an answer fails, how long one takes. Shape, never content --
    /// no email and nothing typed into the assistant is in it.
    static var sharesUsageData: Bool {
        get { UserDefaults.standard.object(forKey: "settings.usageData") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.usageData"); SettingsSync.notify(.app) }
    }
}

extension Notification.Name {
    /// Posted when the appearance choice changes, so the root can re-apply it
    /// immediately rather than on the next launch.
    static let appearanceChanged = Notification.Name("maily.appearanceChanged")
}
