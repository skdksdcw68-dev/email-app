import Foundation

/// The fenced email the model writes when it is asked for one.
///
/// The safety net under the intent parser. However a request is phrased,
/// if the model ends up writing an email it must put it in a block that
/// opens with a line of ```` ```email ```` and closes with ```` ``` ````,
/// with `To:` and `Subject:` lines, a blank line, then the body. The app
/// lifts that block out of the prose and turns it into a draft card with a
/// Send button -- so an email never arrives as a wall of text the person
/// has to copy out by hand.
struct EmailBlock: Equatable {
    static let opening = "```email"
    static let closing = "```"

    var toName = ""
    var toAddress = ""
    var subject = ""
    var body = ""

    /// The prose with the block lifted out, and the block itself. Nil when
    /// the text has no complete block -- including while one is still
    /// streaming in.
    static func extract(from text: String) -> (prose: String, email: EmailBlock)? {
        guard let open = text.range(of: opening) else { return nil }
        let afterOpen = text[open.upperBound...]
        guard let close = afterOpen.range(of: closing) else { return nil }

        let raw = String(afterOpen[..<close.lowerBound])
        let before = String(text[..<open.lowerBound])
        let after = String(afterOpen[close.upperBound...])
        let prose = (before + "\n" + after)
            // The block took its blank lines with it; what is left around
            // the seam is at most one paragraph break.
            .replacingOccurrences(of: "\n\\s*\n(\\s*\n)+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prose, parse(raw))
    }

    /// Header lines first, a blank line, then the body. Tolerates the model
    /// bolding the labels or skipping the blank line.
    static func parse(_ raw: String) -> EmailBlock {
        var block = EmailBlock()
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: CharacterSet(charactersIn: "*-\u{2022} \t"))
            if line.isEmpty {
                index += 1
                break
            }
            if let value = header("to", in: line) {
                (block.toName, block.toAddress) = recipient(from: value)
                index += 1
                continue
            }
            if let value = header("subject", in: line) {
                block.subject = value
                index += 1
                continue
            }
            break
        }

        block.body = lines[index...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return block
    }

    private static func header(_ name: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(name + ":") else { return nil }
        return String(line.dropFirst(name.count + 1))
            .trimmingCharacters(in: CharacterSet(charactersIn: "* \t"))
    }

    /// "Sara Bekele <sara@x.com>" -> ("Sara Bekele", "sara@x.com").
    /// A bare address has no name; a bare name has no address.
    private static func recipient(from value: String) -> (name: String, address: String) {
        if let open = value.firstIndex(of: "<"), let close = value.firstIndex(of: ">"), open < close {
            let address = String(value[value.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let name = String(value[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            return (name, address)
        }
        if value.contains("@") {
            return ("", value.trimmingCharacters(in: .whitespaces))
        }
        return (value, "")
    }
}
