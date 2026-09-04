import Foundation
import Observation

/// What the assistant has been told to remember.
///
/// "I sign off as Abel." "Keep replies to three lines." "Yohannes is my
/// accountant." "I'm travelling until the 12th." Small facts a person should
/// not have to repeat, and the difference between an assistant that knows
/// them and one that meets them again every morning.
///
/// Typed, because they are not all the same kind of thing. A preference
/// holds until it is changed; a situation ends, and an assistant still
/// writing "I'm away this week" in October is worse than one that never
/// knew. The model decides which kind it is and when it ends, at the moment
/// the person says it; the app only keeps the answer and stops applying it
/// on the day.
///
/// Kept on the phone and mirrored to the account, so they follow it to a new
/// device. Read on every question, which is why there is a cap: fifty facts
/// is more than anyone will set and still small enough to send whole.
@Observable
@MainActor
final class AIMemory {

    /// What sort of thing was said, which decides how it is read back.
    enum Kind: String, Codable, CaseIterable {
        /// How they like things done. "Keep replies short."
        case preference
        /// A standing fact about them. "I'm a freelance designer."
        case aboutMe = "about_me"
        /// Who somebody is to them. "Yohannes is my accountant."
        case person
        /// True for a while. "Travelling until the 12th." Usually has an end.
        case situation

        var title: String {
            switch self {
            case .preference: "How you like things"
            case .aboutMe: "About you"
            case .person: "People"
            case .situation: "Right now"
            }
        }

        /// The heading the model reads it under.
        var promptHeading: String {
            switch self {
            case .preference: "How they like things done:"
            case .aboutMe: "About them:"
            case .person: "People in their life:"
            case .situation: "Their situation at the moment:"
            }
        }
    }

    struct Fact: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var kind: Kind = .preference
        /// The last day it applies. Nil means until they say otherwise.
        var until: Date? = nil
        var createdAt: Date = .now

        /// Past its day. Kept, so they can see it in Settings and so a
        /// re-sync does not bring it back as new, but no longer sent.
        func isExpired(now: Date = .now) -> Bool {
            guard let until else { return false }
            return Calendar.current.startOfDay(for: until) < Calendar.current.startOfDay(for: now)
        }

        init(id: UUID = UUID(), text: String, kind: Kind = .preference, until: Date? = nil, createdAt: Date = .now) {
            self.id = id
            self.text = text
            self.kind = kind
            self.until = until
            self.createdAt = createdAt
        }

        /// Facts written before there were kinds decode as preferences,
        /// which is what all of them were.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            text = try container.decode(String.self, forKey: .text)
            kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .preference
            until = try container.decodeIfPresent(Date.self, forKey: .until)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
        }

        private enum CodingKeys: String, CodingKey {
            case id, text, kind, until, createdAt
        }
    }

    /// Newest first.
    private(set) var facts: [Fact] = []

    static let limit = 50

    let fileURL: URL

    /// Deliberately not wired to `.mailboxDisconnected`, unlike chat history.
    /// These are facts about the person rather than their mail -- "keep
    /// replies short" outlives swapping inboxes. Signing out clears them.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        load()
    }

    private static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "Maily", directoryHint: .isDirectory)
            .appending(path: "memory.json")
    }

    // MARK: - Changing

    /// Adds a fact, unless it is one already. Returns nil when it was a
    /// duplicate, so the caller can say so rather than claiming to have
    /// learned something twice.
    @discardableResult
    func remember(_ text: String, kind: Kind = .preference, until: Date? = nil) -> Fact? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !facts.contains(where: { $0.text.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }

        let fact = Fact(text: String(trimmed.prefix(280)), kind: kind, until: until)
        facts.insert(fact, at: 0)
        if facts.count > Self.limit { facts = Array(facts.prefix(Self.limit)) }
        persist()
        push(fact)
        return fact
    }

    func forget(_ id: UUID) {
        facts.removeAll { $0.id == id }
        persist()
        Task.detached(priority: .background) { try? await Backend.delete("memories", id: id) }
    }

    func forgetAll() {
        facts = []
        try? FileManager.default.removeItem(at: fileURL)
        Task.detached(priority: .background) { try? await Backend.deleteAll("memories") }
    }

    // MARK: - What the model is told

    /// The ones still in force.
    func current(now: Date = .now) -> [Fact] {
        facts.filter { !$0.isExpired(now: now) }
    }

    /// The facts as one block for the prompt, grouped by kind, oldest first
    /// within each so the newest correction reads as the last word. A
    /// situation carries its end date, so the model can see it is about to
    /// stop being true. Expired ones are not sent at all.
    var prompt: String { prompt() }

    func prompt(now: Date = .now) -> String {
        // Turned off means nothing stored is sent. The facts stay on disk --
        // this is a pause, not a delete, and `forgetAll` is the delete.
        guard AppSettings.remembersThings else { return "" }

        let live = current(now: now)
        guard !live.isEmpty else { return "" }

        return Kind.allCases.compactMap { kind -> String? in
            let lines = live.filter { $0.kind == kind }.reversed().map { fact -> String in
                guard let until = fact.until else { return "- \(fact.text)" }
                return "- \(fact.text) (until \(until.formatted(.dateTime.day().month(.wide).year())))"
            }
            guard !lines.isEmpty else { return nil }
            return ([kind.promptHeading] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Reading it back

    /// One paragraph per kind, in plain prose.
    ///
    /// 🔴 **Composed here, on the device, from what is already stored. It
    /// never asks the model.**
    ///
    /// That is the whole design and it is easy to get wrong, because the
    /// obvious way to produce "a summary of what I know about you" is to hand
    /// the facts to a model and ask. Every viewing of this screen would then
    /// cost money and take a second, to restate sentences that were already
    /// written in plain English when they were saved.
    ///
    /// The facts were written by the model -- during a chat that was
    /// happening anyway, at no extra cost. Grouping them into paragraphs is
    /// string work.
    func summary(now: Date = .now) -> [Paragraph] {
        let live = current(now: now)

        return Kind.allCases.compactMap { kind in
            let facts = live.filter { $0.kind == kind }
            guard !facts.isEmpty else { return nil }

            // Oldest first, so it reads as things accumulating rather than a
            // stack with the newest on top.
            let sentences = facts.reversed().map { fact -> String in
                var line = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Each fact is one sentence and was not necessarily saved with
                // a full stop. Running them together without one gives a
                // paragraph that reads as a run-on.
                if let last = line.last, !".!?".contains(last) { line += "." }
                if let until = fact.until {
                    line += " (until \(until.formatted(.dateTime.day().month(.wide))))"
                }
                return line
            }

            return Paragraph(kind: kind, body: sentences.joined(separator: " "))
        }
    }

    struct Paragraph: Identifiable {
        let kind: Kind
        let body: String
        var id: Kind { kind }
        var title: String { kind.title }
    }

    /// Changes the wording of one fact, keeping its kind and its end date.
    ///
    /// The screen shows what Maily believes; a person who can only delete a
    /// belief they disagree with has to lose the true half of it too.
    func revise(_ id: UUID, to text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(280))
        guard !trimmed.isEmpty,
              let index = facts.firstIndex(where: { $0.id == id })
        else { return }

        facts[index].text = trimmed
        persist()
        push(facts[index])
    }

    // MARK: - Sync

    private struct Row: Codable {
        var id: UUID
        var user_id: UUID
        var fact: String
        var kind: String?
        var expires_at: Date?
        var created_at: Date
    }

    private func push(_ fact: Fact) {
        Task.detached(priority: .background) {
            guard let userID = try? await Backend.userID() else { return }
            let row = Row(
                id: fact.id, user_id: userID, fact: fact.text,
                kind: fact.kind.rawValue, expires_at: fact.until, created_at: fact.createdAt
            )
            try? await Backend.upsert("memories", [row])
        }
    }

    func pull() async {
        guard await Backend.isSignedIn else { return }
        guard let rows: [Row] = try? await Backend.select(
            "memories", query: "select=*&order=created_at.desc&limit=\(Self.limit)"
        ) else { return }

        var merged = Dictionary(facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows where merged[row.id] == nil {
            merged[row.id] = Fact(
                id: row.id,
                text: row.fact,
                kind: row.kind.flatMap(Kind.init(rawValue:)) ?? .preference,
                until: row.expires_at,
                createdAt: row.created_at
            )
        }
        facts = merged.values
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(Self.limit)
            .map { $0 }
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Fact].self, from: data)
        else { return }
        facts = stored.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(facts)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // Losing a preference is a nuisance, not a failure worth
            // interrupting the conversation over.
        }
    }
}
