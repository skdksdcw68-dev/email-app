import SwiftUI
import UIKit

/// What the writer should aim for. A shortcut for the common asks, so the
/// usual case is one tap rather than typing an instruction every time.
enum WriterStyle: String, CaseIterable, Identifiable {
    case polish
    case short
    case friendly
    case formal
    case detailed
    case accept
    case decline

    var id: Self { self }

    var title: String {
        switch self {
        case .polish:   "Polish mine"
        case .short:    "Short"
        case .friendly: "Friendly"
        case .formal:   "Formal"
        case .detailed: "Detailed"
        case .accept:   "Say yes"
        case .decline:  "Say no"
        }
    }

    var systemImage: String {
        switch self {
        case .polish:   "wand.and.sparkles"
        case .short:    "text.alignleft"
        case .friendly: "hand.wave"
        case .formal:   "briefcase"
        case .detailed: "list.bullet"
        case .accept:   "checkmark.circle"
        case .decline:  "xmark.circle"
        }
    }

    /// What actually gets sent to the model.
    var instruction: String {
        switch self {
        case .polish:   ""   // handled by the refine endpoint instead
        case .short:    "Reply briefly. Two or three sentences at most."
        case .friendly: "Reply warmly and personally, like a friend would."
        case .formal:   "Reply formally and professionally."
        case .detailed: "Reply thoroughly, answering each point that was raised."
        case .accept:   "Reply agreeing to what was asked, and confirm it clearly."
        case .decline:  "Reply declining politely. Do not over-explain or apologise twice."
        }
    }
}

/// Generates a reply and shows it before it goes anywhere.
///
/// Nothing here sends mail. The result lands in the compose editor and the
/// user still has to press Send -- the model writes a suggestion, it does not
/// speak for anybody.
struct AIWriterSheet: View {
    let replyingTo: Message?
    /// What the user already typed, if anything. Enables "Polish mine".
    let existingText: String
    let tone: String
    let onUse: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var style: WriterStyle = .short
    @State private var customPrompt = ""
    @State private var result = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var styles: [WriterStyle] {
        // Nothing to polish when the editor is empty.
        WriterStyle.allCases.filter { $0 != .polish || !existingText.isEmpty }
    }

    private var canGenerate: Bool {
        if isWorking { return false }
        if style == .polish { return !existingText.isEmpty }
        return true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stylePicker
                    promptField
                    if let errorMessage { errorRow(errorMessage) }
                    if !result.isEmpty { preview }
                }
                .padding(16)
            }
            .dismissesKeyboardOnTap()
            .navigationTitle("Write with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
    }

    // MARK: - Pieces

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Style")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            // A flowing wrap, so seven chips do not force a horizontal scroll
            // the user has to discover.
            FlowLayout(spacing: 8) {
                ForEach(styles) { option in
                    styleChip(option)
                }
            }
        }
    }

    private func styleChip(_ option: WriterStyle) -> some View {
        let isSelected = style == option
        return Button {
            withAnimation(.snappy(duration: 0.18)) { style = option }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.systemImage)
                    .font(.caption.weight(.semibold))
                Text(option.title)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anything specific?")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField(
                "Tell them Thursday works, and ask for the invoice",
                text: $customPrompt,
                axis: .vertical
            )
            .font(.subheadline)
            .lineLimit(2...5)
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .secondarySystemBackground))
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Suggested reply", systemImage: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)

            Text(result)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.08))
                }

            Text("Nothing is sent until you press Send.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            if result.isEmpty {
                Button {
                    Task { await generate() }
                } label: {
                    primaryLabel(isWorking ? "Writing…" : "Generate", showsSpinner: isWorking)
                }
                .buttonStyle(.plain)
                .disabled(!canGenerate)
            } else {
                Button {
                    Task { await generate() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Again")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 48)
                    .padding(.horizontal, 18)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Button {
                    onUse(result)
                    dismiss()
                } label: {
                    primaryLabel("Use this", showsSpinner: false)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func primaryLabel(_ title: String, showsSpinner: Bool) -> some View {
        HStack(spacing: 8) {
            if showsSpinner {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "sparkles")
            }
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Capsule().fill(canGenerate || !result.isEmpty ? Color.accentColor : Color.secondary))
    }

    // MARK: - Work

    private func generate() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        let extra = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if style == .polish {
                let refined = try await AIService.refine(
                    text: extra.isEmpty ? existingText : "\(existingText)\n\nAlso: \(extra)",
                    replyingTo: replyingTo,
                    tone: tone
                )
                result = refined.body
            } else {
                let instruction = extra.isEmpty
                    ? style.instruction
                    : "\(style.instruction) \(extra)"
                let draft = try await AIService.draft(
                    replyingTo: replyingTo,
                    instruction: instruction,
                    tone: tone
                )
                result = draft.body
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Wraps chips onto as many lines as they need.
///
/// SwiftUI has no flow layout of its own before iOS 16's Layout protocol, and
/// an HStack in a ScrollView would push seven chips off the side of a phone.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let rows = rows(for: subviews, width: width)
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + row.height + (total == 0 ? 0 : spacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : x + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
                x = 0
            }
            x = current.indices.isEmpty ? size.width : x + spacing + size.width
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    AIWriterSheet(
        replyingTo: MailStore.connected().messages(in: .inbox).first,
        existingText: "",
        tone: "warm and friendly",
        onUse: { _ in }
    )
}
