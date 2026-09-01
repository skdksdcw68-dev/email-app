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
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "settings.appearance") }
    }

    // MARK: - AI

    /// Whether the model gets to look at incoming mail at all. Off means the
    /// rules still tag it -- those are local and free -- but nothing is sent
    /// anywhere and nothing is charged.
    static var tagsIncomingMail: Bool {
        get { UserDefaults.standard.object(forKey: "settings.aiTagging") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.aiTagging") }
    }

    /// Whether opening a message asks for a summary of it.
    static var writesSummaries: Bool {
        get { UserDefaults.standard.object(forKey: "settings.aiSummaries") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.aiSummaries") }
    }

    /// Extra guidance handed to the model whenever it writes for the user.
    static var customInstructions: String {
        get { UserDefaults.standard.string(forKey: "settings.customInstructions") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "settings.customInstructions") }
    }

    // MARK: - Privacy

    /// Whether conversations with the assistant follow the account to another
    /// device. Off keeps them on this phone, where they used to live.
    static var syncsChats: Bool {
        get { UserDefaults.standard.object(forKey: "settings.syncsChats") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.syncsChats") }
    }

    /// Whether the app reports how it is used: which features get opened,
    /// how often an answer fails, how long one takes. Shape, never content --
    /// no email and nothing typed into the assistant is in it.
    static var sharesUsageData: Bool {
        get { UserDefaults.standard.object(forKey: "settings.usageData") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "settings.usageData") }
    }
}

extension Notification.Name {
    /// Posted when the appearance choice changes, so the root can re-apply it
    /// immediately rather than on the next launch.
    static let appearanceChanged = Notification.Name("maily.appearanceChanged")
}
