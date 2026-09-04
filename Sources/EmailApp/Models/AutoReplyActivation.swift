import Foundation

/// Whether Auto-Reply is armed **on this mailbox**.
///
/// The setup is shared and should be: how somebody writes, what their work
/// is, what they will never let a machine say on their behalf — none of that
/// changes because they connected a second address, and asking eleven
/// questions again per mailbox would be a good way to have the feature
/// switched off for good.
///
/// Being *armed* is the opposite. It is a decision about one specific address
/// and the people who write to it. Left in the shared config, connecting a
/// work account to an app where Auto-Reply was already on would arm an agent
/// to answer mail from an address nobody ever consented to — silently, on the
/// first sync, in a voice tuned for a different audience. That is the worst
/// thing this feature could do, so the three fields that decide it live here,
/// in the mailbox's own suite.
struct AutoReplyActivation: Codable, Equatable {
    /// Switched on for this mailbox.
    var isOn = false
    /// Drafting or sending, for this mailbox. A mailbox that is trusted to
    /// send is not every mailbox.
    var mode: AutoReplyConfig.RunMode = .draft
    /// The moment it started watching *this* mailbox.
    ///
    /// Per-mailbox for the same reason it exists at all: a newly connected
    /// account has three months of backlog, and arming against a shared date
    /// from months ago would work through every one of them.
    var watchingSince: Date?

    static let off = AutoReplyActivation()

    // MARK: - Storage

    private static let key = "autoreply.activation"

    /// Read from the active mailbox's suite. Off is the right default for a
    /// mailbox that has never been asked about.
    static var current: AutoReplyActivation {
        get {
            guard let data = MailboxScope.defaults.data(forKey: key),
                  let stored = try? JSONDecoder().decode(AutoReplyActivation.self, from: data)
            else { return .off }
            return stored
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            MailboxScope.defaults.set(data, forKey: key)
        }
    }

    /// What the old shared config held, moved into this mailbox's suite.
    /// Called once by the migration; see `MailboxMigration`.
    static func adopt(isOn: Bool, mode: AutoReplyConfig.RunMode, watchingSince: Date?, into defaults: UserDefaults) {
        let activation = AutoReplyActivation(isOn: isOn, mode: mode, watchingSince: watchingSince)
        guard let data = try? JSONEncoder().encode(activation) else { return }
        defaults.set(data, forKey: key)
    }
}
