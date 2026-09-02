import Foundation

/// Structure the model asked for, rather than structure the app guessed at.
///
/// The keyword ladder that used to decide when an answer became tiles or a
/// chart is gone. It intercepted questions it only half understood and
/// returned a canned paragraph instead of an answer, which is worse than
/// plain prose. The model decides now: it writes normally, and where a set
/// of numbers reads better drawn than described, it fences them.
///
///     ```stats
///     Very Urgent: 12
///     Needs Reply: 8
///     Unread: 30
///     ```
///
///     ```chart
///     Inbox by tag
///     Very Urgent: 12
///     Important: 30
///     ```
///
///     ```show
///     1
///     4
///     ```
///
/// The last one is the emails themselves. The model reads a numbered list;
/// when the answer *is* one of those emails, it names the number and the
/// app draws the card, rather than the model typing the sender, subject and
/// time back out as a paragraph. "Show me the last one" used to come back as
/// bold text describing an email that was sitting one tap away.
///
/// Same contract as ```` ```email ````, and deliberately so: one way for the
/// model to hand the app something richer than a paragraph.
enum AnswerFences {

    private static let kinds: Set<String> = ["stats", "chart", "show"]

    /// The prose with every block lifted out, and the blocks in the order
    /// they appeared. A fence that has not finished streaming is held back
    /// rather than shown half drawn.
    ///
    /// `messages` is the list the model was numbered against, in the same
    /// order, so a show block resolves to real messages. Without it a show
    /// block is dropped.
    static func extract(from text: String, messages: [Message] = []) -> (prose: String, blocks: [AnswerBlock]) {
        var prose = ""
        var blocks: [AnswerBlock] = []
        var rest = Substring(text)

        while let open = rest.range(of: "```") {
            let head = String(rest[..<open.lowerBound])
            let afterTicks = rest[open.upperBound...]

            guard let newline = afterTicks.firstIndex(of: "\n") else {
                // No line to name the block. Either a closing fence -- which
                // belongs to whoever opened it, and must survive for the
                // email parser to find -- or one of ours truncated mid-word
                // by the stream, which should not be shown at all.
                let tail = afterTicks.trimmingCharacters(in: .whitespaces).lowercased()
                let ours = !tail.isEmpty && kinds.contains { $0.hasPrefix(tail) }
                prose += ours ? head : head + "```" + String(afterTicks)
                rest = ""
                break
            }

            let kind = afterTicks[..<newline]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard kinds.contains(kind) else {
                // Somebody else's fence -- ```email, or a code sample. Leave
                // it exactly as it came.
                prose += head + "```"
                rest = afterTicks
                continue
            }

            let bodyStart = afterTicks.index(after: newline)
            guard let close = afterTicks[bodyStart...].range(of: "```") else {
                // Still streaming. Show the prose so far and nothing of the
                // half-written block.
                prose += head
                rest = ""
                break
            }

            prose += head
            if let block = parse(kind, String(afterTicks[bodyStart..<close.lowerBound]), messages: messages) {
                blocks.append(block)
            }
            rest = afterTicks[close.upperBound...]
        }

        prose += rest
        let tidied = prose
            .replacingOccurrences(of: "\n\\s*\n(\\s*\n)+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (tidied, blocks)
    }

    /// The most a show block will draw. A guard against a runaway block, not
    /// a design choice: how many to show is the reader's call, and "list my
    /// last ten" answered with eight was the app overruling them. The model
    /// can only number what it was given, which is the real bound.
    static let showLimit = 40

    // MARK: - Blocks

    private static func parse(_ kind: String, _ body: String, messages: [Message]) -> AnswerBlock? {
        let lines = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*-\u{2022} \t")) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        switch kind {
        case "show":
            // Numbers into the list the model was reading. One per line is
            // what it is told; a comma-separated line is accepted too. Only
            // the first number on each piece counts, so "3. Sara, 10:31" is
            // message three and not messages three, ten and thirty-one.
            // Anything out of range is dropped, and nothing in range means no
            // block rather than an empty one.
            guard !messages.isEmpty else { return nil }
            var seen = Set<Int>()
            let picked = lines
                .flatMap { $0.split(separator: ",") }
                .compactMap { piece -> Int? in
                    let digits = piece.drop { !$0.isNumber }.prefix { $0.isNumber }
                    return Int(digits)
                }
                .filter { $0 >= 1 && $0 <= messages.count && seen.insert($0).inserted }
                .prefix(showLimit)
                .map { messages[$0 - 1] }
            return picked.isEmpty ? nil : .messages(Array(picked))

        case "stats":
            // Three across is what the row fits. A fourth makes all of them
            // too narrow to read, so the model's extras are dropped rather
            // than crushed.
            let stats = lines.compactMap(pair).prefix(3).map { Stat(label: $0.label, value: $0.value) }
            return stats.isEmpty ? nil : .stats(Array(stats))

        case "chart":
            // The first line that is not a pair is the title.
            var title = "Breakdown"
            var rows = lines
            if pair(lines[0]) == nil {
                title = lines[0]
                rows = Array(lines.dropFirst())
            }
            let points = rows.compactMap(pair).compactMap { row -> AnswerChart.Point? in
                guard let value = Int(row.value.filter(\.isNumber)) else { return nil }
                return AnswerChart.Point(label: row.label, value: value)
            }
            return points.isEmpty ? nil : .chart(AnswerChart(title: title, points: points))

        default:
            return nil
        }
    }

    /// "Very Urgent: 12" -> ("Very Urgent", "12").
    private static func pair(_ line: String) -> (label: String, value: String)? {
        guard let colon = line.lastIndex(of: ":") else { return nil }
        let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !value.isEmpty else { return nil }
        return (label, value)
    }
}
