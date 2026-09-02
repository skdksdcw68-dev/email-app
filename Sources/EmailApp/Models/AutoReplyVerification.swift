import Foundation

/// The check that runs on a reply after it is written and before it counts.
///
/// The model is told what it may say. This is the part that does not take its
/// word for it -- it reads the reply back against the approved facts and the
/// boundaries, on the device, and refuses anything it cannot account for.
///
/// It exists because "the prompt says not to" is not a safety mechanism. A
/// model that has been told never to quote a price will still quote one
/// occasionally, and the whole case for ever letting this send on its own is
/// that something other than the model's good intentions is checking.
///
/// Deliberately conservative and deliberately dumb. It does not understand
/// the reply; it looks for the specific shapes of claim that cost somebody
/// money -- a number that is not one of their numbers, a date nobody
/// approved, a promise, a boundary word -- and hands anything suspicious back
/// to the person. False alarms cost a tap. A miss costs a customer.
struct AutoReplyVerification: Codable, Equatable {

    /// What to do with the reply.
    enum Result: String, Codable {
        /// Nothing found. Safe to send, if sending is on.
        case clear
        /// Something in it could not be accounted for. Goes to the person.
        case holdBack
    }

    var result: Result
    /// What tripped it, in the words shown to the person.
    var problems: [String]
    /// Confidence the model reported, kept alongside so the log has both.
    var confidence: Double

    var isClear: Bool { result == .clear && problems.isEmpty }

    // MARK: - Checking

    /// Reads a reply back against what the person actually approved.
    ///
    /// `approved` is every fact they typed, joined; `boundaries` the titles of
    /// what must always come back to them; `allowed` the categories they let
    /// Maily answer.
    static func check(
        reply: String,
        approved: String,
        boundaries: [String],
        confidence: Double,
        floor: Double
    ) -> AutoReplyVerification {
        var problems: [String] = []

        if confidence < floor {
            problems.append("Maily wasn't confident enough about this one.")
        }

        // Money it was never given. The commonest and most expensive
        // invention there is: a number with a currency on it that does not
        // appear anywhere in what they approved.
        let approvedNumbers = numbers(in: approved)
        let quoted = amounts(in: reply)
        for amount in quoted where !approvedNumbers.contains(amount.digits) {
            problems.append("It quotes \(amount.text), which isn't in what you approved.")
        }

        // Dates it committed to. A deadline is a promise, and one nobody
        // approved is the kind of promise that ends a client relationship.
        for phrase in datePhrases(in: reply) {
            guard !approved.localizedCaseInsensitiveContains(phrase) else { continue }
            problems.append("It commits to \"\(phrase)\", which isn't in what you approved.")
        }

        // Promises, in the shape people actually write them.
        for promise in promisePhrases where reply.localizedCaseInsensitiveContains(promise) {
            problems.append("It promises something (\"\(promise)\"), which needs to come from you.")
            break
        }

        // A boundary the person named, showing up in the reply anyway. Rough
        // by design: the word "refund" in a reply from somebody who said
        // refunds always come back to them is worth one tap to check.
        for boundary in boundaries {
            for word in boundaryWords(for: boundary)
            where reply.localizedCaseInsensitiveContains(word) {
                problems.append("It touches on \(boundary.lowercased()), which you asked to always see.")
                break
            }
        }

        // Deduplicated: three unapproved numbers is one problem to a reader,
        // not three lines of the same sentence.
        var seen = Set<String>()
        let unique = problems.filter { seen.insert($0).inserted }

        return AutoReplyVerification(
            result: unique.isEmpty ? .clear : .holdBack,
            problems: unique,
            confidence: confidence
        )
    }

    // MARK: - What it looks for

    /// Every run of digits in the approved facts, so a figure in the reply
    /// can be matched against them however it was written. "$4,000" and
    /// "4000" are the same number to this.
    private static func numbers(in text: String) -> Set<String> {
        var found: Set<String> = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if character == "," || character == "." {
                continue
            } else if !current.isEmpty {
                found.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { found.insert(current) }
        return found
    }

    /// Amounts of money in a reply: a currency mark next to a number, or a
    /// number next to a currency word.
    private static func amounts(in text: String) -> [(text: String, digits: String)] {
        var found: [(String, String)] = []
        let marks: Set<Character> = ["$", "£", "€", "¥"]
        let words = ["usd", "eur", "gbp", "dollars", "euros", "pounds"]
        let scanner = text.split(whereSeparator: { $0 == " " || $0 == "\n" })

        for (index, rawPiece) in scanner.enumerated() {
            let piece = String(rawPiece)
            let digits = piece.filter(\.isNumber)
            guard !digits.isEmpty else { continue }

            let hasMark = piece.contains { marks.contains($0) }
            let neighbour = index + 1 < scanner.count ? String(scanner[index + 1]).lowercased() : ""
            let hasWord = words.contains { neighbour.hasPrefix($0) }

            if hasMark || hasWord {
                found.append((piece.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")), digits))
            }
        }
        return found
    }

    /// Dates a reply commits to, in the forms people write them.
    private static func datePhrases(in text: String) -> [String] {
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        let leads = ["by ", "before ", "on ", "no later than "]
        var found: [String] = []
        let lowered = text.lowercased()

        for lead in leads {
            var searchRange = lowered.startIndex..<lowered.endIndex
            while let range = lowered.range(of: lead, range: searchRange) {
                let after = lowered[range.upperBound...]
                let word = after.prefix { !$0.isWhitespace && $0 != "." && $0 != "," }
                if days.contains(String(word)) || word.contains(where: \.isNumber) {
                    found.append(lead + String(word))
                }
                searchRange = range.upperBound..<lowered.endIndex
            }
        }
        return found
    }

    private static let promisePhrases = [
        "i guarantee", "we guarantee", "i promise", "we promise",
        "you will receive", "i'll make sure", "we'll make sure",
        "definitely", "certainly will",
    ]

    /// The words that mean a boundary has been walked into. One or two each,
    /// chosen so a false alarm is plausible and a miss is not.
    private static func boundaryWords(for boundary: String) -> [String] {
        switch boundary.lowercased() {
        case let title where title.contains("legal"):
            ["contract", "agreement", "terms", "liability", "nda", "msa"]
        case let title where title.contains("pricing"):
            ["discount", "negotiate", "special rate", "bespoke price"]
        case let title where title.contains("negotiation"):
            ["negotiate", "haggle", "meet you halfway", "best offer"]
        case let title where title.contains("refund"):
            ["refund", "money back", "reimburse"]
        case let title where title.contains("deadline"):
            ["deadline", "delivery date", "ship by"]
        case let title where title.contains("sensitive"):
            ["password", "social security", "bank details", "card number"]
        default:
            []
        }
    }
}
