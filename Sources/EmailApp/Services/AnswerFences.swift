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
///
/// ```` ```remember ```` is the odd one out: nothing is drawn. It is the model
/// telling the app to keep something the person said about themselves, and
/// the app keeps it. See `MemoryNote`.
enum AnswerFences {

    private static let kinds: Set<String> = ["stats", "chart", "show", "remember"]

    /// Everything the model handed the app besides prose.
    struct Answer: Equatable {
        var prose: String
        var blocks: [AnswerBlock]
        /// What it was told to keep. Not drawn; acted on.
        var memories: [MemoryNote]
    }

    /// The prose with every block lifted out, and the blocks in the order
    /// they appeared. A fence that has not finished streaming is held back
    /// rather than shown half drawn.
    ///
    /// `messages` is the list the model was numbered against, in the same
    /// order, so a show block resolves to real messages. Without it a show
    /// block is dropped.
    static func extract(from text: String, messages: [Message] = []) -> (prose: String, blocks: [AnswerBlock]) {
        let answer = read(from: text, messages: messages)
        return (answer.prose, answer.blocks)
    }

    /// The same, with what the model asked the app to remember.
    static func read(from text: String, messages: [Message] = []) -> Answer {
        var prose = ""
        var blocks: [AnswerBlock] = []
        var memories: [MemoryNote] = []
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
            let inside = String(afterTicks[bodyStart..<close.lowerBound])
            if kind == "remember" {
                if let note = MemoryNote(fence: inside) { memories.append(note) }
            } else if let block = parse(kind, inside, messages: messages) {
                blocks.append(block)
            }
            rest = afterTicks[close.upperBound...]
        }

        prose += rest
        let tidied = prose
            .replacingOccurrences(of: "\n\\s*\n(\\s*\n)+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Answer(prose: tidied, blocks: blocks, memories: memories)
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

/// What the model asked the app to keep about the person, lifted out of a
/// ```` ```remember ```` fence.
///
///     ```remember
///     kind: situation
///     until: 2026-09-12
///     text: Travelling until the 12th.
///     ```
///
/// The model decides that a sentence was something to remember, which kind
/// it is and when it stops being true. The app used to guess the first of
/// those from an opening phrase, and "remember to reply to Sara" became a
/// preference. Now it only reads the answer.
struct MemoryNote: Equatable {
    var kind: AIMemory.Kind
    var text: String
    /// The last day it holds. Only a situation tends to have one.
    var until: Date?

    init(kind: AIMemory.Kind, text: String, until: Date? = nil) {
        self.kind = kind
        self.text = text
        self.until = until
    }

    /// Nil when there is no text, which is the one thing the block cannot
    /// do without. A kind the app does not know becomes a preference; a
    /// date it cannot read becomes no date, so the fact still holds rather
    /// than expiring at once or never arriving.
    init?(fence body: String) {
        var kind: AIMemory.Kind = .preference
        var text = ""
        var until: Date?

        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "kind":
                kind = AIMemory.Kind(rawValue: value.lowercased().replacingOccurrences(of: " ", with: "_")) ?? .preference
            case "until":
                if value.lowercased() != "none" { until = Extraction.day(value) }
            case "text":
                text = value
            default:
                continue
            }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(kind: kind, text: trimmed, until: until)
    }
}
