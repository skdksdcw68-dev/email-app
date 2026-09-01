import SwiftUI

/// Search terms marked inside a line of text.
///
/// A results list that does not show *why* a message matched makes the reader
/// do the finding twice: once by searching, and again by scanning each row for
/// the word. Marking it is the whole difference between a list of results and
/// a list of messages.
///
/// Matching is case and diacritic insensitive, so "renewal" finds "Renewal"
/// and "cafe" finds "café".
enum Highlight {

    /// `text` with every occurrence of any term given a tinted background.
    /// Returns the text untouched when there is nothing to mark, which is the
    /// common case and must cost nothing.
    static func mark(_ text: String, terms: [String], tint: Color = .yellow) -> AttributedString {
        var attributed = AttributedString(text)
        let wanted = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard !wanted.isEmpty else { return attributed }

        // Found first, marked second. Searching and mutating in one pass
        // means walking indices of a string that is being changed underneath
        // the walk; two passes is both clearer and safe by construction.
        var found: [Range<AttributedString.Index>] = []
        for term in wanted {
            var searchRange = attributed.startIndex..<attributed.endIndex
            // `range(of:)` returns one occurrence, so step past each hit to
            // reach the rest of them.
            while let hit = attributed[searchRange].range(
                of: term, options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                found.append(hit)
                guard hit.upperBound < attributed.endIndex else { break }
                searchRange = hit.upperBound..<attributed.endIndex
            }
        }

        for range in found {
            attributed[range].backgroundColor = tint.opacity(0.35)
            attributed[range].foregroundColor = .primary
        }
        return attributed
    }

    /// The words worth marking from a plain search box: what somebody typed,
    /// minus the noise that would light up every row.
    static func terms(in query: String) -> [String] {
        query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0.lowercased()) }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "from", "with", "about", "that", "this", "was",
        "are", "any", "all", "you", "your", "email", "mail", "message",
    ]
}
