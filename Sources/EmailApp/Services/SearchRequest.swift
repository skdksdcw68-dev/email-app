import Foundation

/// The model asking to look further before it answers.
///
/// Every rule that decided this on the app's behalf was a guess at what
/// somebody would type, and each one broke on the next phrasing. "Find my
/// Upwork registration" needed the words "welcome to upwork" before anything
/// would search, because a keyword table cannot know that a welcome email is
/// where a registration date lives. The model does know that. So instead of
/// guessing for it, the app gives it a way to say "not here, look further"
/// and does the looking.
///
/// The contract is one line and nothing else:
///
///     SEARCH: upwork welcome registration
///
/// Same shape as the ```` ```email ```` block: a small, checkable thing the
/// model can emit that the app knows how to act on.
enum SearchRequest {

    static let marker = "SEARCH:"

    /// The terms to look for, or nil when this is an ordinary answer.
    ///
    /// Deliberately strict about position. A model mentioning the word
    /// "search" in the middle of a sentence is talking, not asking, and
    /// treating that as a request would send the app off to Gmail in the
    /// middle of a perfectly good answer.
    static func extract(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else { return nil }

        let terms = trimmed
            .dropFirst(marker.count)
            // One line. Anything after is the model carrying on regardless.
            .prefix { $0 != "\n" }
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'`."))

        guard terms.count >= 2 else { return nil }
        return String(terms.prefix(200))
    }
}
