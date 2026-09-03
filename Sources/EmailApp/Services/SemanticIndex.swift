import Foundation
import NaturalLanguage

/// Finding mail by what it is about rather than by the words it used.
///
/// Retrieval is a word match: a question asking about "the laptop" scores
/// zero against an email that says MacBook throughout and never says laptop.
/// The message is right there on the phone, the model is never handed it, and
/// the answer comes back as "nothing in your mail about that".
///
/// **This runs entirely on the device, and it has to.** Gmail's Limited Use
/// rules do not allow message content to go to a server to build a semantic
/// layer, so nothing here touches the network -- `NLEmbedding` ships with iOS
/// and the vectors never leave. That is a constraint, not a preference: the
/// day this becomes a server call is the day the app is in breach.
///
/// Two stages, cheapest first:
///
///   1. **Expand the question.** Word embeddings give the near neighbours of
///      each word -- laptop → notebook, macbook, computer -- and those join
///      the keyword match. Only the question is embedded, so this costs the
///      same whether the mailbox holds ten messages or ten thousand.
///   2. **Rank what survived.** Sentence embeddings measure the question
///      against a shortlist, which catches what no word list would: "when am
///      I meeting the accountant" against "confirming Thursday 2pm with
///      Grant Thornton".
///
/// Stage two is capped, because embedding is per-message work and a mailbox
/// is thousands of them. See `shortlist`.
enum SemanticIndex {

    // MARK: - Availability

    /// English only, for now. Both of these are nil on a system without the
    /// asset, and everything here degrades to the keyword match rather than
    /// failing -- semantic search is an improvement on retrieval, not a
    /// dependency of it.
    nonisolated(unsafe) private static let words = NLEmbedding.wordEmbedding(for: .english)
    nonisolated(unsafe) private static let sentences = NLEmbedding.sentenceEmbedding(for: .english)

    /// The two are separate assets and one can be present without the other
    /// -- the simulator ships the word model and not the sentence one. So
    /// each stage asks about its own, and a missing model costs that stage
    /// and nothing else.
    static var canExpand: Bool { words != nil }
    static var canRank: Bool { sentences != nil }

    static var isAvailable: Bool { canExpand || canRank }

    // MARK: - Expanding a question

    /// How many neighbours each word brings in. Three is where it stops being
    /// help: past that the neighbours are neighbours of neighbours, and
    /// "invoice" starts pulling in words that would match half the mailbox.
    static let neighboursPerWord = 3

    /// How far a neighbour may be and still count. `NLEmbedding` distances
    /// run 0 (identical) upward; past about 0.9 the words are related only in
    /// the sense that all words are.
    static let neighbourLimit: Double = 0.9

    /// The question's words, plus what they nearly mean.
    ///
    /// Returns only the additions, so the caller can score them lower than
    /// the words actually typed -- an email that says "laptop" should still
    /// beat one that only says "notebook".
    static func expand(_ terms: Set<String>) -> Set<String> {
        guard let words, !terms.isEmpty else { return [] }

        var found: Set<String> = []
        for term in terms {
            for (neighbour, distance) in words.neighbors(for: term, maximumCount: neighboursPerWord) {
                guard distance <= neighbourLimit else { continue }
                guard !terms.contains(neighbour), neighbour.count > 3 else { continue }
                found.insert(neighbour)
            }
        }
        return found
    }

    // MARK: - Ranking a shortlist

    /// How many messages get the sentence treatment. Embedding is real work
    /// per message -- a few milliseconds each -- and a question must not
    /// spend a second of it. The shortlist comes from the keyword and
    /// neighbour pass, which is already sorted by how promising it is.
    static let shortlist = 120

    /// Vectors already worked out, kept for the session.
    ///
    /// Keyed by Gmail's id, so the same message re-fetched does not pay
    /// twice. Held in memory rather than on disk: the mailbox turns over, the
    /// embedding model could change under an OS update, and a stale vector
    /// silently ranks the wrong thing.
    nonisolated(unsafe) private static var vectors: [String: [Double]] = [:]

    /// Similarity between the question and each candidate, 0 to 1, higher is
    /// closer. Messages that cannot be embedded are simply absent -- a
    /// missing score means "no opinion", not "unrelated".
    static func similarity(of candidates: [Message], to question: String) -> [Message.ID: Double] {
        guard let sentences else { return [:] }

        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard asked.count > 2, let target = sentences.vector(for: asked) else { return [:] }

        var scores: [Message.ID: Double] = [:]
        for message in candidates.prefix(shortlist) {
            guard let vector = vector(for: message, using: sentences) else { continue }
            let distance = cosineDistance(target, vector)
            // Distance to closeness, floored at zero: a negative similarity
            // is not "less than unrelated", it is just unrelated.
            scores[message.id] = max(0, 1 - distance)
        }
        return scores
    }

    /// What a message is *about*, in the few words worth embedding.
    ///
    /// The subject and the opening, not the whole body. A sentence embedding
    /// of eight paragraphs is an average of eight paragraphs, which is a
    /// vector that means nothing -- the signal is in the top of the message,
    /// which is where people say what they want.
    private static func vector(for message: Message, using model: NLEmbedding) -> [Double]? {
        if let remoteID = message.remoteID, let cached = vectors[remoteID] { return cached }

        let gist = "\(message.subject). \(message.body.prefix(240))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard gist.count > 2, let vector = model.vector(for: gist) else { return nil }

        if let remoteID = message.remoteID { vectors[remoteID] = vector }
        return vector
    }

    /// Standard cosine distance, 0 for identical direction.
    private static func cosineDistance(_ left: [Double], _ right: [Double]) -> Double {
        guard left.count == right.count, !left.isEmpty else { return 1 }

        var dot = 0.0, leftMagnitude = 0.0, rightMagnitude = 0.0
        for index in left.indices {
            dot += left[index] * right[index]
            leftMagnitude += left[index] * left[index]
            rightMagnitude += right[index] * right[index]
        }
        guard leftMagnitude > 0, rightMagnitude > 0 else { return 1 }
        return 1 - dot / (leftMagnitude.squareRoot() * rightMagnitude.squareRoot())
    }

    /// Dropped when the mailbox is cleared, so a signed-out account leaves
    /// nothing of its mail behind, not even as numbers.
    static func forgetEverything() {
        vectors.removeAll()
    }
}
