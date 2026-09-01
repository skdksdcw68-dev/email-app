import SwiftUI
import Charts

// What an assistant answer is made of, beyond prose.
//
// The reply format plan, in one place:
//   - Prose is rendered by `AssistantProse` with a real type hierarchy:
//     16pt body, headline section titles, tinted bullets and numbers.
//   - Numbers land as stat tiles, not sentences -- "3 urgent" reads faster
//     than "there are three urgent emails".
//   - Emails land as tappable cards that open the message.
//   - Comparisons land as a bar chart.
//   - An email the model writes lands as a draft card, never as prose.

/// A structured piece of an answer. Local answers are built from these; the
/// model's answers stay prose plus sources.
enum AnswerBlock: Equatable, Identifiable {
    case stats([Stat])
    case messages([Message])
    case chart(AnswerChart)

    var id: String {
        switch self {
        case .stats(let stats):       "stats-" + stats.map(\.title).joined(separator: "-")
        case .messages(let messages): "messages-" + (messages.first?.id.uuidString ?? "none")
        case .chart(let chart):       "chart-" + chart.title
        }
    }
}

struct Stat: Equatable {
    let title: String
    let value: String
    let symbol: String
    let color: Color
}

struct AnswerChart: Equatable {
    struct Point: Equatable, Identifiable {
        let label: String
        let value: Int
        var id: String { label }
    }

    let title: String
    let points: [Point]
}

/// An answer the mailbox itself could give, without the model.
struct LocalAnswer {
    let text: String
    let blocks: [AnswerBlock]
}

// MARK: - Rendering

struct AnswerBlockView: View {
    let block: AnswerBlock

    var body: some View {
        switch block {
        case .stats(let stats):       StatTileRow(stats: stats)
        case .messages(let messages): AnswerMessageList(messages: messages)
        case .chart(let chart):       AnswerChartView(chart: chart)
        }
    }
}

/// Two or three numbers side by side, each with a name and a colour.
struct StatTileRow: View {
    let stats: [Stat]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(stats, id: \.title) { stat in
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: stat.symbol)
                        .font(.footnote)
                        .foregroundStyle(stat.color)
                    Text(stat.value)
                        .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                    Text(stat.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                }
            }
        }
    }
}

/// Emails inside an answer, as tappable cards that open the message.
struct AnswerMessageList: View {
    let messages: [Message]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(messages) { message in
                NavigationLink(value: message.id) {
                    HStack(spacing: 10) {
                        SenderAvatar(contact: message.sender, size: 34)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.sender.name)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(message.subject)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                }
                .buttonStyle(BouncyButtonStyle())
            }
        }
    }
}

/// A horizontal bar chart, for "who emails me most" and its relatives.
struct AnswerChartView: View {
    let chart: AnswerChart

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(chart.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart {
                ForEach(chart.points) { point in
                    BarMark(
                        x: .value("Count", point.value),
                        y: .value("Label", point.label)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing, spacing: 4) {
                        Text("\(point.value)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: CGFloat(chart.points.count) * 34 + 12)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
    }
}

// MARK: - Prose

/// Assistant prose with a deliberate type hierarchy, instead of one grey
/// slab of subheadline. Handles the markdown the model actually produces --
/// headings, bullets, numbered lists, bold and italics inline -- and nothing
/// speculative beyond that.
///
/// An email block is never shown as text. While it is still streaming in,
/// the prose stops at the fence and a "Writing the email" line stands in;
/// once complete, `AIChatView` lifts it out into a draft card.
struct AssistantProse: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                view(for: piece)
            }
        }
    }

    // MARK: Pieces

    private enum Piece {
        case heading(String)
        case subheading(String)
        case bullet(String)
        case numbered(Int, String)
        case paragraph(String)
        /// An email block is arriving; the prose pauses here.
        case writingEmail
    }

    /// The text without any email block: everything before an open fence,
    /// or everything around a closed one.
    private var visible: (prose: String, isWritingEmail: Bool) {
        guard let open = text.range(of: EmailBlock.opening) else { return (text, false) }
        let before = String(text[..<open.lowerBound])
        let afterOpen = text[open.upperBound...]
        if let close = afterOpen.range(of: EmailBlock.closing) {
            return (before + "\n" + String(afterOpen[close.upperBound...]), false)
        }
        return (before, true)
    }

    private var pieces: [Piece] {
        let (prose, isWritingEmail) = visible
        var result: [Piece] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in prose.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }

            if line.hasPrefix("### ") {
                flush(); result.append(.subheading(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flush(); result.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flush(); result.append(.heading(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); result.append(.bullet(String(line.dropFirst(2))))
            } else if let (number, rest) = numberedPrefix(line) {
                flush(); result.append(.numbered(number, rest))
            } else {
                paragraph.append(line)
            }
        }
        flush()

        if isWritingEmail { result.append(.writingEmail) }
        return result
    }

    /// "1. thing" -- but not "3.5% growth", which is why the text after the
    /// dot must start with a space.
    private func numberedPrefix(_ line: String) -> (Int, String)? {
        let parts = line.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let number = Int(parts[0]), number > 0, number < 100,
              parts[1].hasPrefix(" ")
        else { return nil }
        return (number, parts[1].trimmingCharacters(in: .whitespaces))
    }

    // MARK: Views

    @ViewBuilder
    private func view(for piece: Piece) -> some View {
        switch piece {
        case .heading(let string):
            inline(string)
                .font(.headline)
                .padding(.top, 2)

        case .subheading(let string):
            inline(string)
                .font(.subheadline.weight(.semibold))

        case .bullet(let string):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\u{2022}")
                    .font(.callout.weight(.black))
                    .foregroundStyle(.tint)
                inline(string)
                    .font(.callout)
                    .lineSpacing(3)
            }

        case .numbered(let number, let string):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
                inline(string)
                    .font(.callout)
                    .lineSpacing(3)
            }

        case .paragraph(let string):
            inline(string)
                .font(.callout)
                .lineSpacing(3)

        case .writingEmail:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the email…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Bold and italics, without letting a parse failure eat the text.
    private func inline(_ string: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: string, options: options) {
            return Text(attributed)
        }
        return Text(string)
    }
}
