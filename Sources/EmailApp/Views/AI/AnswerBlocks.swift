import SwiftUI
import UIKit
import Charts

// What an assistant answer is made of, beyond prose.
//
// The reply format plan, in one place:
//   - Prose is rendered by `AssistantProse` with a real type hierarchy:
//     16pt body, headline section titles, tinted bullets and numbers -- and
//     it is selectable a word at a time, like text in a real editor.
//   - Numbers land as stat tiles, not sentences -- "3 urgent" reads faster
//     than "there are three urgent emails".
//   - Emails land as tappable cards that open the message.
//   - Comparisons land as a bar chart.
//   - An email the model writes lands as a draft card, never as prose.

/// A structured piece of an answer. Local answers are built from these; the
/// model's answers stay prose plus sources.
enum AnswerBlock: Equatable, Identifiable, Codable {
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

struct Stat: Equatable, Codable {
    /// A named system colour rather than a `Color`, so a stat survives a
    /// round trip through the history file.
    enum Tint: String, Codable {
        case red, orange, yellow, green, blue, indigo, purple, teal, pink, brown

        var color: Color {
            switch self {
            case .red:    Color(uiColor: .systemRed)
            case .orange: Color(uiColor: .systemOrange)
            case .yellow: Color(uiColor: .systemYellow)
            case .green:  Color(uiColor: .systemGreen)
            case .blue:   Color(uiColor: .systemBlue)
            case .indigo: Color(uiColor: .systemIndigo)
            case .purple: Color(uiColor: .systemPurple)
            case .teal:   Color(uiColor: .systemTeal)
            case .pink:   Color(uiColor: .systemPink)
            case .brown:  Color(uiColor: .systemBrown)
            }
        }
    }

    let title: String
    let value: String
    let symbol: String
    let tint: Tint

    /// A tile from whatever the model called it.
    ///
    /// A label that names a tag gets that tag's own chip symbol and colour,
    /// so "Very Urgent 12" in an answer and "Very Urgent 12" at the top of
    /// the inbox are recognisably the same thing. Anything else falls back to
    /// something neutral rather than being refused: the model chose to show a
    /// number, and dropping it because the app did not recognise the word
    /// would be the old mistake in a smaller costume.
    init(label: String, value: String) {
        self.title = label
        self.value = value

        if let tag = AITag.named(in: label.lowercased()) {
            self.symbol = tag.systemImage
            self.tint = tag.statTint
            return
        }
        switch label.lowercased() {
        case let text where text.contains("unread"):
            (self.symbol, self.tint) = ("envelope.badge.fill", .blue)
        case let text where text.contains("read"):
            (self.symbol, self.tint) = ("envelope.open", .green)
        case let text where text.contains("today") || text.contains("week"):
            (self.symbol, self.tint) = ("calendar", .purple)
        case let text where text.contains("sender") || text.contains("people"):
            (self.symbol, self.tint) = ("person.2.fill", .indigo)
        default:
            (self.symbol, self.tint) = ("tray.full.fill", .indigo)
        }
    }

    init(title: String, value: String, symbol: String, tint: Tint) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.tint = tint
    }
}

extension AITag {
    /// The tag's inbox colour, as a name a stat can be stored under.
    var statTint: Stat.Tint {
        switch self {
        case .urgent:        .red
        case .veryImportant: .orange
        case .important:     .yellow
        case .needsReply:    .blue
        case .noReplyNeeded: .green
        case .meeting:       .purple
        case .finance:       .teal
        case .security:      .indigo
        case .newsletter:    .brown
        case .promotion:     .pink
        }
    }
}

struct AnswerChart: Equatable, Codable {
    struct Point: Equatable, Identifiable, Codable {
        let label: String
        let value: Int
        var id: String { label }
    }

    let title: String
    let points: [Point]
}

/// An answer the mailbox itself could give, without the model.

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
                        .foregroundStyle(stat.tint.color)
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
/// Rendered as one selectable text view, so the reader can take a sentence
/// out of the middle of an answer. An email block is never shown as text:
/// while it is still streaming in, the prose stops at the fence and a
/// "Writing the email" line stands in; once complete, `AIChatView` lifts it
/// out into a draft card.
struct AssistantProse: View {
    let text: String

    var body: some View {
        let parsed = self.parsed
        VStack(alignment: .leading, spacing: 10) {
            if !parsed.pieces.isEmpty {
                SelectableText(attributed(parsed.pieces))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if parsed.isWritingEmail {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the email…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
    }

    /// The text without any email block: everything before an open fence,
    /// or everything around a closed one.
    private var visible: (prose: String, isWritingEmail: Bool) {
        // Tiles and charts are drawn as blocks once the answer is complete,
        // so their fences never belong in the prose -- not finished, and not
        // half arrived either.
        let withoutStructure = AnswerFences.extract(from: text).prose

        guard let open = withoutStructure.range(of: EmailBlock.opening) else {
            return (withoutStructure, false)
        }
        let before = String(withoutStructure[..<open.lowerBound])
        let afterOpen = withoutStructure[open.upperBound...]
        if let close = afterOpen.range(of: EmailBlock.closing) {
            return (before + "\n" + String(afterOpen[close.upperBound...]), false)
        }
        return (before, true)
    }

    private var parsed: (pieces: [Piece], isWritingEmail: Bool) {
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
        return (result, isWritingEmail)
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

    // MARK: Attributed

    /// The type hierarchy, as attributes: 16pt callout for prose, headline
    /// for headings, tinted markers hanging in a 16pt indent for lists.
    private func attributed(_ pieces: [Piece]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .callout)
        let tint = UIColor.tintColor

        for (index, piece) in pieces.enumerated() {
            let block = NSMutableAttributedString()
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            style.paragraphSpacing = 10

            switch piece {
            case .heading(let string):
                block.append(inline(string, font: .preferredFont(forTextStyle: .headline)))
                style.paragraphSpacing = 6
                style.paragraphSpacingBefore = 4

            case .subheading(let string):
                block.append(inline(string, font: weighted(.subheadline, .semibold)))
                style.paragraphSpacing = 6

            case .bullet(let string):
                block.append(NSAttributedString(
                    string: "\u{2022}\t",
                    attributes: [.font: weighted(.callout, .black), .foregroundColor: tint]
                ))
                block.append(inline(string, font: body))
                style.headIndent = 16
                style.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
                style.defaultTabInterval = 16
                style.paragraphSpacing = 6

            case .numbered(let number, let string):
                block.append(NSAttributedString(
                    string: "\(number).\t",
                    attributes: [.font: weighted(.callout, .semibold), .foregroundColor: tint]
                ))
                block.append(inline(string, font: body))
                style.headIndent = 22
                style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
                style.defaultTabInterval = 22
                style.paragraphSpacing = 6

            case .paragraph(let string):
                block.append(inline(string, font: body))
            }

            block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
            result.append(block)
            if index < pieces.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private func weighted(_ style: UIFont.TextStyle, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        return UIFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    /// Bold, italics, code and links from inline markdown, in the given
    /// font. A parse failure falls back to the plain string rather than
    /// eating the text.
    private func inline(_ string: String, font: UIFont, color: UIColor = .label) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: string, options: options) else {
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var runFont = font

            if let intent = run.inlinePresentationIntent {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    runFont = UIFont(descriptor: descriptor, size: 0)
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                }
            }

            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color]
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }
}
