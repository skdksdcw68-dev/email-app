import Foundation
import Observation

/// The categories of the active mailbox: which exist, in what order, which
/// are shown, and what the AI is told about them.
///
/// Per mailbox, not per person. A support inbox has "Support requests" and a
/// personal one does not; the same address on another phone should have the
/// same list, which `SettingsSync` handles under its own scope.
///
/// Local storage is the truth on screen, the server a copy: written on every
/// change, pulled at launch, the same as every other setting.
@MainActor
@Observable
final class CategoryStore {

    static let shared = CategoryStore()

    private static let key = "categories.v1"

    /// How many already-sorted messages a new or reworded category is applied
    /// to on its own: the newest hundred, about half a cent. The rest of the
    /// mailbox waits for "Apply to all mail", which says what it costs.
    static let refreshDepth = 100

    /// What a new category costs to apply to one already-sorted message, in
    /// the operator's dollars. Only ever shown as a rounded figure next to
    /// the "Apply to all" button.
    static let costPerMessage = 0.00006

    /// Every write goes through `commit`, which also refreshes `snapshot`.
    private(set) var all: [Category] = []

    /// A plain copy of the list for the few places that run off the main
    /// actor and only need to look a name up -- the chat intent parser, an
    /// answer tile. Written whenever the list is, read anywhere.
    nonisolated(unsafe) private(set) static var snapshot: [Category] = []

    private func commit(_ list: [Category]) {
        all = list
        Self.snapshot = list
    }

    /// Set by "Apply to all mail" and cleared once nothing is left to apply.
    var appliesToAllMail = false

    private init() { load() }

    // MARK: - Reading

    var visible: [Category] { all.filter(\.isVisible) }
    var custom: [Category] { all.filter(\.isCustom) }

    func category(id: String) -> Category? {
        all.first { $0.id == id }
    }

    /// The category that wraps a built-in tag. Always exists: the ten are
    /// seeded and cannot be deleted, only hidden.
    func category(for tag: AITag) -> Category {
        category(id: tag.rawValue) ?? .builtIn(tag)
    }

    /// The category named somewhere in a lowercased phrase, longest name
    /// first so "support requests" is never swallowed by a shorter one. What
    /// lets "show me the support requests" work the day the category is made.
    func named(in text: String) -> Category? {
        Self.named(in: text, among: all)
    }

    /// The same, from the snapshot, for callers that are not on the main
    /// actor.
    nonisolated static func anyNamed(in text: String) -> Category? {
        named(in: text, among: snapshot)
    }

    nonisolated static func named(in text: String, among list: [Category]) -> Category? {
        let candidates = list
            .map { ($0, $0.name.lowercased()) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }
        return candidates.first { text.contains($0.1) }?.0
    }

    /// The person's names, for the chat digest.
    var names: AIService.CategoryNames {
        AIService.CategoryNames(
            builtIn: Dictionary(uniqueKeysWithValues: AITag.allCases.map { ($0, category(for: $0).name) }),
            custom: Dictionary(uniqueKeysWithValues: custom.map { ($0.id, $0.name) })
        )
    }

    // MARK: - What the model is told

    struct Guidance: Encodable {
        let id: String
        let name: String
        let what: String
    }

    /// The custom categories, as the classifier wants them.
    var customForModel: [Guidance] {
        custom.map { Guidance(id: $0.id, name: $0.name, what: $0.guidance) }
    }

    /// Notes on built-ins -- "newsletters from my bank are Important".
    var notesForModel: [Guidance] {
        all.filter { !$0.isCustom && $0.speaksToTheModel }
            .map { Guidance(id: $0.id, name: $0.name, what: $0.guidance) }
    }

    /// Everything the model is currently told, as id → revision. Stored
    /// beside a classification so a message sorted before a category
    /// existed, or under its old wording, can be found and sorted again.
    var revisionsForModel: [String: Int] {
        Dictionary(uniqueKeysWithValues: all.filter(\.speaksToTheModel).map { ($0.id, $0.revision) })
    }

    /// Whether a classification made with `seen` is behind what the model is
    /// told now.
    func isStale(_ seen: [String: Int]?) -> Bool {
        let current = revisionsForModel
        guard !current.isEmpty else { return false }
        let seen = seen ?? [:]
        return current.contains { id, revision in seen[id] != revision }
    }

    // MARK: - Writing

    func add(_ category: Category) {
        commit(all + [category])
        save()
    }

    /// Replaces a category. The revision moves only when what the model is
    /// told changes: renaming a colour costs nobody a re-read.
    func update(_ category: Category) {
        guard let index = all.firstIndex(where: { $0.id == category.id }) else { return }
        var updated = category
        let before = all[index]
        if before.name != updated.name || before.guidance != updated.guidance {
            updated.revision = before.revision + 1
        } else {
            updated.revision = before.revision
        }
        var list = all
        list[index] = updated
        commit(list)
        save()
    }

    /// Only a custom category can go. A built-in is hidden instead, because
    /// Auto-Reply and notifications still read its tag.
    func remove(id: String) {
        guard let category = category(id: id), category.isCustom else { return }
        commit(all.filter { $0.id != id })
        save()
    }

    func setVisible(_ id: String, _ visible: Bool) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        var list = all
        list[index].isVisible = visible
        commit(list)
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var list = all
        list.move(fromOffsets: source, toOffset: destination)
        commit(list)
        save()
    }

    // MARK: - Per mailbox

    /// Called when the active mailbox changes: the list belongs to the
    /// mailbox it was read from.
    func reload() {
        load()
    }

    /// Everything goes when the mailbox does. The seeded ten come back.
    func forgetAll() {
        MailboxScope.defaults.removeObject(forKey: Self.key)
        commit(Category.defaults)
        appliesToAllMail = false
    }

    private func load() {
        appliesToAllMail = false
        guard let data = MailboxScope.defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([Category].self, from: data)
        else {
            commit(Category.defaults)
            return
        }
        commit(Self.seeded(stored))
    }

    /// A stored list is trusted for order, names, colours and visibility, but
    /// any built-in it is missing -- a tag added in a later build -- is put
    /// back at the end, so a new kind of mail never has nowhere to show.
    private static func seeded(_ stored: [Category]) -> [Category] {
        var list = stored
        for tag in AITag.allCases where !list.contains(where: { $0.id == tag.rawValue }) {
            list.append(.builtIn(tag))
        }
        return list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) {
            MailboxScope.defaults.set(data, forKey: Self.key)
        }
        SettingsSync.notify(.categories)
    }

    // MARK: - Sync

    /// The whole list as one JSON string, for the settings row.
    var snapshotJSON: String? {
        guard let data = try? JSONEncoder().encode(all) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What another device saved. Replaces the list -- last write wins per
    /// mailbox, like the tone -- and does not push back up.
    func adopt(json: String) {
        guard let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode([Category].self, from: data)
        else { return }
        commit(Self.seeded(incoming))
        if let encoded = try? JSONEncoder().encode(all) {
            MailboxScope.defaults.set(encoded, forKey: Self.key)
        }
    }
}
