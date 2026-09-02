import Foundation

/// The model asking to look, instead of answering.
///
///     SEARCH: upwork welcome | upwork verify | joined upwork
///     OLDEST: from:linkedin | from:instagram
///
/// One line, and the app does the looking. Two verbs, because two different
/// questions hide behind "find it":
///
/// `SEARCH` is about wording. The alternatives after the first are the point:
/// a single query is a guess, and Gmail joins bare words with AND, so a guess
/// that is slightly wrong returns nothing at all and the answer comes back
/// "not in your mail" about an email sitting in the account. Three guesses
/// are an investigation.
///
/// `OLDEST` is about time. Gmail hands back the newest matches first, and
/// "when did I join LinkedIn" is answered by the one email at the very
/// bottom of eight years of LinkedIn. A search for it finds the eight most
/// recent notifications and never the welcome. So the model can ask for the
/// earliest mail matching something instead, one query per thing it is
/// asking about, and the app walks back to the start of the account for it.
/// This is why Upwork was findable and LinkedIn was not: nothing about
/// Upwork was special, it just does not write every day.
///
/// The model writes these rather than the app, because knowing that a
/// registration date lives in a welcome email, or that "when did it start"
/// needs the oldest match, is meaning, not string matching. No word list gets
/// there. See the search rules in the `ask` function for what it is told.
struct SearchRequest: Equatable {

    enum Kind: Equatable {
        /// Hypotheses about the words in the email. Each is a Gmail query.
        case wording
        /// The earliest mail matching each query, back to the start of the
        /// account.
        case earliest

        var marker: String {
            switch self {
            case .wording: "SEARCH:"
            case .earliest: "OLDEST:"
            }
        }
    }

    let kind: Kind
    /// Best guess first. Never empty.
    let queries: [String]

    /// At most this many alternatives per hop. Each one is at least one Gmail
    /// request, and a model asked for "several" will happily write twelve.
    static let maxHypotheses = 4

    /// The request on the first line of what the model wrote, or nothing if
    /// this is an answer.
    static func extract(from text: String) -> SearchRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for kind in [Kind.wording, .earliest] where trimmed.hasPrefix(kind.marker) {
            let line = trimmed
                .dropFirst(kind.marker.count)
                .prefix { $0 != "\n" }

            var seen = Set<String>()
            let queries = line
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

            return queries.isEmpty ? nil : SearchRequest(kind: kind, queries: Array(queries))
        }

        return nil
    }

    /// Whether the model asked to look rather than answering. Used to decide
    /// whether what streamed in is prose worth showing.
    static func isRequest(_ text: String) -> Bool {
        extract(from: text) != nil
    }

    /// Whether text still arriving might yet be a request: nothing so far, a
    /// few letters that a marker starts with, or a marker already written.
    /// While this is true the words are held back rather than shown, so the
    /// reader never sees the request itself.
    static func couldBecomeRequest(_ text: String) -> Bool {
        let head = text.drop { $0.isWhitespace }
        guard !head.isEmpty else { return true }
        return [Kind.wording, .earliest].contains { kind in
            head.hasPrefix(kind.marker) || kind.marker.hasPrefix(head)
        }
    }
}
