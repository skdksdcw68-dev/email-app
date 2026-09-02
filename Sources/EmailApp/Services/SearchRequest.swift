import Foundation

/// The model asking to look, instead of answering.
///
///     SEARCH: upwork welcome | upwork verify | joined upwork
///
/// One line, and the app does the looking. The alternatives after the first
/// are the point. A single query is a guess, and Gmail joins bare words with
/// AND, so a guess that is slightly wrong returns nothing at all and the
/// answer comes back "not in your mail" about an email sitting in the
/// account. Three guesses are an investigation: the words a welcome email
/// actually uses are one of them.
///
/// The model writes these rather than the app, because knowing that a
/// registration date lives in a welcome email is meaning, not string
/// matching. No word list gets there. See the `SEARCH` rules in the `ask`
/// function for what it is told.
enum SearchRequest {

    static let marker = "SEARCH:"

    /// At most this many alternatives per hop. Each one is a Gmail request,
    /// and a model asked for "several" will happily write twelve.
    static let maxHypotheses = 4

    /// The queries to try, best first, or nothing if this is an answer.
    static func extract(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return [] }

        let line = trimmed
            .dropFirst(marker.count)
            .prefix { $0 != "\n" }

        var seen = Set<String>()
        let hypotheses = line
            .split(separator: "|")
            .map { piece in
                piece.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.,"))
            }
            .filter { candidate in
                // Two characters is the shortest thing worth asking Gmail
                // about, and a repeat costs a request for nothing.
                candidate.count >= 2 && seen.insert(candidate.lowercased()).inserted
            }
            .prefix(maxHypotheses)
            .map { String($0.prefix(200)) }

        return Array(hypotheses)
    }

    /// Whether the model asked to search rather than answering. Used to
    /// decide whether what streamed in is prose worth showing.
    static func isRequest(_ text: String) -> Bool {
        !extract(from: text).isEmpty
    }
}
