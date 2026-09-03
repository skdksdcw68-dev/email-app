import Foundation

/// What the conversation is about, kept between turns.
///
/// The chat used to carry nothing but the last six turns of text. That is a
/// transcript, not a memory, and it fails in three specific ways:
///
///   - "try again" repeats the exact search that just found nothing, because
///     nothing remembers what was tried.
///   - "and what did she say about the invoice?" loses Sara, because the
///     people in a question are worked out from *that* question's words.
///   - "did you find it?" has no idea what "it" was, because the question
///     that went unanswered was never written down.
///
/// All three are things the app already knew and threw away. So this is
/// deliberately not a second model call and not a protocol the model has to
/// remember to follow: every field here is a record of something that already
/// happened. The model still decides what to search for and who matters --
/// this only stops the app forgetting the answer between turns.
struct ChatState: Equatable {

    /// A search that ran, and whether it was worth running.
    struct Attempt: Equatable {
        let query: String
        let found: Int
    }

    /// Queries already put to Gmail in this conversation, oldest first.
    private(set) var tried: [Attempt] = []

    /// Who the conversation is about. Carried forward, so a follow-up that
    /// names nobody is still about the person the last question named.
    private(set) var people: [String] = []

    /// A question that was asked and not answered. Cleared the moment
    /// something is found, because a question answered late is still answered.
    private(set) var unresolved: String?

    /// How many searches one conversation may remember. Past this the line
    /// gets long enough to cost more than it saves, and the oldest attempts
    /// are the least likely to be tried again anyway.
    private static let attemptsKept = 8

    // MARK: - Recording what happened

    /// A question is starting. Anything the question itself names replaces
    /// what was carried; a question that names nobody keeps it.
    mutating func asking(_ question: String, about named: [String]) {
        if !named.isEmpty { people = named }
        // Only the first unanswered question is held. A follow-up while
        // something is still open is usually about the same thing, and
        // overwriting would lose what was actually being looked for.
        if unresolved == nil { unresolved = question }
    }

    /// A search ran. Recorded whether or not it found anything -- the ones
    /// that found nothing are the ones worth not repeating.
    mutating func searched(_ query: String, found: Int) {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        // The same query twice in one conversation is the thing this exists
        // to prevent, so it is recorded once.
        if let index = tried.firstIndex(where: { $0.query.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            tried[index] = Attempt(query: cleaned, found: max(tried[index].found, found))
        } else {
            tried.append(Attempt(query: cleaned, found: found))
        }
        if tried.count > Self.attemptsKept { tried.removeFirst(tried.count - Self.attemptsKept) }
    }

    /// The turn is over. `found` is what an investigation turned up, and
    /// `searched` says whether one ran at all.
    mutating func answered(found: Int, searched: Bool) {
        // A question answered without looking was answered from what was
        // already to hand, so nothing is outstanding. Only a search that came
        // back empty leaves the question open -- which is exactly the state
        // "try again" needs to see.
        if !searched || found > 0 { unresolved = nil }
    }

    /// Nothing about the last turn was mail, so nothing about it is worth
    /// carrying. Asides -- "what can you do", "write me a haiku" -- should
    /// not quietly become the subject of the conversation.
    mutating func setAside() {
        unresolved = nil
    }

    // MARK: - Handing it to the model

    /// The state as one short paragraph, or nil when there is nothing worth
    /// saying. Nil is the common case on a first question, and it costs
    /// nothing then.
    func briefing() -> String? {
        var lines: [String] = []

        let empty = tried.filter { $0.found == 0 }.map(\.query)
        if !empty.isEmpty {
            lines.append(
                "Already searched in this conversation, and found nothing: "
                + empty.map { "\"\($0)\"" }.joined(separator: ", ")
                + ". Do not search for those words again."
            )
        }

        let hits = tried.filter { $0.found > 0 }.map(\.query)
        if !hits.isEmpty {
            lines.append(
                "Already searched, and found something: "
                + hits.map { "\"\($0)\"" }.joined(separator: ", ") + "."
            )
        }

        if !people.isEmpty {
            lines.append("This conversation is about: \(people.joined(separator: ", ")).")
        }

        if let unresolved {
            lines.append("Still unanswered from earlier: \"\(unresolved)\"")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A new conversation knows nothing about the last one.
    static let fresh = ChatState()
}
