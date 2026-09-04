import Foundation

/// What somebody taught Maily, kept with the account rather than the phone.
///
/// Almost none of it was. A new phone started blank: the tone every draft is
/// written in reset to "match how I already write", every important and muted
/// sender was forgotten, and the eleven-question Auto-Reply setup had to be
/// answered again from nothing. Only chats, searches and memories followed the
/// person. Everything that shapes how the app behaves stayed on the device
/// that happened to be there when it was decided.
///
/// Modelled on `ChatHistory` and `AIMemory`: local storage stays the truth on
/// screen, the server is a copy, writes push, launch pulls.
@MainActor
@Observable
final class SettingsSync {

    /// The four documents. Separate rather than one blob because they are
    /// written at wildly different rates -- `people` changes every time
    /// somebody taps a star, `autoreply` during a setup flow and then almost
    /// never -- and because one blob means one conflict: changing a tone on
    /// the phone and starring a sender on the iPad would throw one away.
    enum Scope: String, CaseIterable {
        case app, people, onboarding, autoreply
    }

    /// One instance, reachable from anywhere.
    ///
    /// `PersonPreferences` is a static enum called from a dozen places, none
    /// of which hold a reference to anything -- so a sync that had to be
    /// passed down would mean threading it through every one of them. Handed
    /// its dependencies at launch instead, the same way `PushDelegate` is,
    /// and for the same reason.
    static let shared = SettingsSync()

    private weak var user: UserStore?
    private weak var autoReply: AutoReplyStore?

    /// Per scope, so a burst of stars does not also rewrite the Auto-Reply
    /// setup, and one slow push does not delay an unrelated one.
    private var pending: [Scope: Task<Void, Never>] = [:]

    /// Set while `pull()` is applying what came down, so writing the incoming
    /// values into the local stores does not immediately push them back up.
    private var isApplyingRemote = false

    private init() {}

    func attach(user: UserStore, autoReply: AutoReplyStore) {
        self.user = user
        self.autoReply = autoReply
    }

    // MARK: - Pushing

    /// Queues a scope to be sent, after a pause.
    ///
    /// 🔴 Debounced, and it has to be. `PersonPreferences.setImportant` fires
    /// once per tap, and somebody working down the People tab marks a dozen
    /// senders in as many seconds. One PATCH per tap is twelve round trips to
    /// send a set that only had to be sent once.
    /// The same, callable from anywhere.
    ///
    /// `AppSettings` and `PersonPreferences` are plain enums with no isolation
    /// -- written from views on the main actor and from mail-parsing tasks
    /// that are not -- so they cannot call a main-actor method directly. This
    /// hops for them, and means a store noting a change never has to think
    /// about which thread it is on.
    nonisolated static func notify(_ scope: Scope) {
        Task { @MainActor in shared.note(scope) }
    }

    func note(_ scope: Scope) {
        guard !isApplyingRemote else { return }

        pending[scope]?.cancel()
        pending[scope] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await self?.push(scope)
        }
    }

    /// Sends everything queued, now.
    ///
    /// Called when the app goes to the background: a debounce still waiting
    /// when the process is suspended is a change that was never saved.
    func flush() async {
        let scopes = Array(pending.keys)
        for scope in scopes { pending[scope]?.cancel() }
        pending.removeAll()
        for scope in scopes { await push(scope) }
    }

    /// 🔴 Cancels rather than flushes.
    ///
    /// `UserStore.signOut()` empties `answers` locally. A debounced push
    /// firing after that would send the emptied state up and destroy the
    /// account's settings on every other device -- signing out of one phone
    /// would wipe the iPad. Signing out is not an edit.
    ///
    /// Deliberately different from `AutoReplyStore.forgetSetup()` and
    /// `PersonPreferences.clearAll()`, which *are* edits somebody asked for
    /// and should propagate.
    func cancelPending() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func push(_ scope: Scope) async {
        guard let payload = snapshot(of: scope) else { return }

        let row = Row(
            user_id: nil,
            scope: scope.rawValue,
            payload: payload,
            updated_at: .now,
            device_id: Self.deviceID
        )
        try? await Backend.upsert("user_settings", [row])
    }

    // MARK: - Pulling

    /// Brings down what another device saved. Newer wins per scope, compared
    /// on `updated_at`, which mirrors what `ChatHistory.pull()` already does.
    func pull() async {
        guard await Backend.isSignedIn else { return }
        guard let rows: [Row] = try? await Backend.select(
            "user_settings", query: "select=*"
        ) else { return }

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        for row in rows {
            guard let scope = Scope(rawValue: row.scope) else { continue }
            apply(row.payload, to: scope)
        }
    }

    // MARK: - What each scope is

    private func snapshot(of scope: Scope) -> [String: AnyCodable]? {
        switch scope {
        case .app:
            return [
                "appearance": .init(AppSettings.appearance.rawValue),
                "tagsIncomingMail": .init(AppSettings.tagsIncomingMail),
                "writesSummaries": .init(AppSettings.writesSummaries),
                "customInstructions": .init(AppSettings.customInstructions),
                "remembersThings": .init(AppSettings.remembersThings),
                "notifiesNewMail": .init(AppSettings.notifiesNewMail),
                "notifiesAutoReply": .init(AppSettings.notifiesAutoReply),
                "notifiesOnlyImportant": .init(AppSettings.notifiesOnlyImportant),
                "syncsChats": .init(AppSettings.syncsChats),
                "sharesUsageData": .init(AppSettings.sharesUsageData),
            ]

        case .people:
            return [
                "important": .init(Array(PersonPreferences.important)),
                "muted": .init(Array(PersonPreferences.muted)),
            ]

        case .onboarding:
            return [
                "answers": .init((user?.answers ?? [:]).mapValues(Array.init)),
                "occupation": .init(user?.account?.occupation ?? ""),
            ]

        case .autoreply:
            guard let autoReply,
                  let data = try? JSONEncoder().encode(autoReply.config.syncable),
                  let json = String(data: data, encoding: .utf8)
            else { return nil }
            return ["config": .init(json)]
        }
    }

    private func apply(_ payload: [String: AnyCodable], to scope: Scope) {
        switch scope {
        case .app:
            if let value: String = payload["appearance"]?.value(),
               let appearance = AppSettings.Appearance(rawValue: value) {
                AppSettings.appearance = appearance
            }
            if let value: Bool = payload["tagsIncomingMail"]?.value() { AppSettings.tagsIncomingMail = value }
            if let value: Bool = payload["writesSummaries"]?.value() { AppSettings.writesSummaries = value }
            if let value: String = payload["customInstructions"]?.value() { AppSettings.customInstructions = value }
            if let value: Bool = payload["remembersThings"]?.value() { AppSettings.remembersThings = value }
            if let value: Bool = payload["notifiesNewMail"]?.value() { AppSettings.notifiesNewMail = value }
            if let value: Bool = payload["notifiesAutoReply"]?.value() { AppSettings.notifiesAutoReply = value }
            if let value: Bool = payload["notifiesOnlyImportant"]?.value() { AppSettings.notifiesOnlyImportant = value }
            if let value: Bool = payload["syncsChats"]?.value() { AppSettings.syncsChats = value }
            if let value: Bool = payload["sharesUsageData"]?.value() { AppSettings.sharesUsageData = value }

        case .people:
            // 🔴 Union, not replace, and this is the one place the merge rule
            // differs by scope.
            //
            // `important` and `muted` are sets somebody built by tapping, and
            // there is no case where a device *means* to unmark by omission --
            // it just has not heard about the others yet. Overwriting would
            // silently unstar everybody marked on another phone.
            //
            // ⚠️ The cost, stated rather than hidden: un-starring does not
            // propagate. Remove somebody here and the other device adds them
            // back on its next sync. Fixing that properly needs tombstones
            // (`{address, removedAt}`), which is where this turns into a CRDT.
            // Worth doing if it bites; not worth doing first.
            if let incoming: [String] = payload["important"]?.value() {
                PersonPreferences.merge(important: Set(incoming))
            }
            if let incoming: [String] = payload["muted"]?.value() {
                PersonPreferences.merge(muted: Set(incoming))
            }

        case .onboarding:
            if let raw: [String: [String]] = payload["answers"]?.value() {
                user?.replaceAnswers(raw.mapValues(Set.init))
            }
            if let occupation: String = payload["occupation"]?.value(), !occupation.isEmpty {
                user?.setOccupation(occupation)
            }

        case .autoreply:
            guard let json: String = payload["config"]?.value(),
                  let data = json.data(using: .utf8),
                  let incoming = try? JSONDecoder().decode(AutoReplyConfig.self, from: data)
            else { return }
            autoReply?.adoptSynced(incoming)
        }
    }

    // MARK: - Bits

    /// Which phone this is. Only ever used to work out later why two devices
    /// disagree -- never for deciding who wins.
    private static let deviceID: String = {
        let key = "settings.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private struct Row: Codable {
        var user_id: UUID?
        var scope: String
        var payload: [String: AnyCodable]
        var updated_at: Date
        var device_id: String
    }
}

/// A JSON value of a shape not known at compile time.
///
/// The four scopes hold different things and are stored in one `jsonb`
/// column, so the payload cannot be one Swift type. Small and deliberately
/// limited to what actually appears: strings, bools, numbers, and arrays and
/// dictionaries of those.
struct AnyCodable: Codable {
    private let stored: Any

    init(_ value: Any) { stored = value }

    func value<T>() -> T? { stored as? T }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { stored = value }
        else if let value = try? container.decode(Int.self) { stored = value }
        else if let value = try? container.decode(Double.self) { stored = value }
        else if let value = try? container.decode(String.self) { stored = value }
        else if let value = try? container.decode([String].self) { stored = value }
        else if let value = try? container.decode([String: [String]].self) { stored = value }
        else if let value = try? container.decode([String: String].self) { stored = value }
        else { stored = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch stored {
        case let value as Bool: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Double: try container.encode(value)
        case let value as String: try container.encode(value)
        case let value as [String]: try container.encode(value)
        case let value as [String: [String]]: try container.encode(value)
        case let value as [String: String]: try container.encode(value)
        default: try container.encodeNil()
        }
    }
}
