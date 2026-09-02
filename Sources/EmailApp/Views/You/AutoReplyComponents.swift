import SwiftUI

/// One question, and one way forward.
///
/// Every step in the setup is this: a small label, a title big enough to be
/// the only thing on the screen, one sentence of why, and the answer. The
/// button is nil while the question is unanswered, so the flow cannot be
/// walked past without answering it.
struct StepShell<Content: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String
    let button: String?
    let action: () -> Void
    @ViewBuilder let content: Content

    init(
        eyebrow: String?,
        title: String,
        subtitle: String,
        button: String?,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.button = button
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tint)
                        .tracking(0.6)
                }
                Text(title)
                    .font(.title.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)

            content

            if let button {
                Button(action: action) {
                    Text(button)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of several. A tick on the right rather than a radio button, because
/// the rest of the app marks a choice that way.
struct ChoiceRow: View {
    let title: String
    var detail: String? = nil
    let symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.footnote)
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Any number of. Same shape as `ChoiceRow` on purpose -- the difference is
/// how many can be on, and the square says so.
struct CheckRow: View {
    let title: String
    let symbol: String?
    let isOn: Bool
    var note: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.footnote)
                        .foregroundStyle(isOn ? Color.accentColor : .secondary)
                        .frame(width: 24)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let note, !isOn {
                    Text(note)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .buttonStyle(.plain)
    }
}

/// A labelled multi-line field. Grows with what is typed, because most of
/// these answers are a sentence and some are a paragraph.
struct FieldBlock: View {
    let label: String
    let hint: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.semibold))
            TextField(hint, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .font(.subheadline)
                .padding(.vertical, 11)
                .padding(.horizontal, 13)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                }
        }
    }
}

/// A line on the review screen that goes back to the step that set it.
struct ReviewCard: View {
    let title: String
    let value: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, _ value: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
            }
        }
        .buttonStyle(.plain)
    }
}

/// An email, drawn as an email rather than described as one.
struct PreviewBlock: View {
    let title: String
    let text: String
    var isReply = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(13)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(isReply
                              ? Color.accentColor.opacity(0.10)
                              : Color(uiColor: .secondarySystemGroupedBackground))
                }
        }
    }
}

// MARK: - Custom instructions

/// Add, edit, switch off, reorder, delete.
///
/// A list rather than one text box, because these are separate rules with
/// separate lives: "never say I hope you're doing well" should be retirable
/// without rewriting the other five, and switching one off to see whether it
/// was the problem is exactly what somebody does after reading a reply they
/// did not like.
struct InstructionEditor: View {
    @Binding var instructions: [AutoReplyConfig.Instruction]
    @Binding var draft: String

    @State private var editing: AutoReplyConfig.Instruction.ID?
    @State private var editText = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($instructions) { $instruction in
                InstructionRow(
                    instruction: $instruction,
                    onEdit: {
                        editing = instruction.id
                        editText = instruction.text
                    },
                    onDelete: {
                        instructions.removeAll { $0.id == instruction.id }
                    }
                )
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.subheadline)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 13)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                    .onSubmit(add)

                Button(action: add) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 4)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .alert("Edit instruction", isPresented: .constant(editing != nil)) {
            TextField("Instruction", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                defer { editing = nil }
                guard let id = editing,
                      let index = instructions.firstIndex(where: { $0.id == id }),
                      let cleaned = AutoReplyConfig.Instruction(cleaning: editText)
                else { return }
                instructions[index].text = cleaned.text
            }
        }
    }

    /// A different example each time, so the field teaches by showing rather
    /// than by explaining.
    private var placeholder: String {
        let examples = AutoReplyConfig.instructionExamples
        return examples[min(instructions.count, examples.count - 1)]
    }

    private func add() {
        problem = nil
        guard let instruction = AutoReplyConfig.Instruction(cleaning: draft) else { return }
        guard !instructions.contains(where: { $0.matches(instruction.text) }) else {
            problem = "You already told it that."
            draft = ""
            return
        }
        guard instructions.count < AutoReplyStore.instructionLimit else {
            problem = "That's as many rules as Maily can hold at once."
            return
        }
        withAnimation(.snappy(duration: 0.22)) {
            instructions.append(instruction)
        }
        draft = ""
    }
}

struct InstructionRow: View {
    @Binding var instruction: AutoReplyConfig.Instruction
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button {
                instruction.isOn.toggle()
            } label: {
                Image(systemName: instruction.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(instruction.isOn ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            Text(instruction.text)
                .font(.subheadline)
                .foregroundStyle(instruction.isOn ? .primary : .secondary)
                .strikethrough(!instruction.isOn, color: .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button("Edit", systemImage: "pencil", action: onEdit)
                Button(instruction.isOn ? "Turn off" : "Turn on",
                       systemImage: instruction.isOn ? "pause" : "play") {
                    instruction.isOn.toggle()
                }
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 13)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}

// MARK: - The example reply

/// The example shown at the end of the setup.
///
/// Written on the device from what the person just typed, not by the model:
/// it is a picture of their own settings, and it must never show a reply
/// containing a fact they did not give. That is the same rule the real
/// runtime follows, demonstrated rather than described -- if the preview
/// invented a price here, nobody would believe the promise that it will not
/// invent one later.
enum AutoReplyPreview {

    static func incoming(for config: AutoReplyConfig) -> String {
        switch config.persona {
        case .support:
            "Hi — I can't log in to my account and I'm not sure what I'm doing wrong. Can you help?"
        case .founder, .sales:
            "Hi, I found your site and wanted to know if you work with startups, and roughly how your pricing works."
        case .freelancer, .developer:
            "Hey, I've got a project coming up and wanted to know if you're taking work at the moment and what you'd charge."
        case .agency:
            "Hello — we're looking for help on a new project. Is this the kind of thing you take on?"
        case .creator:
            "Hi! We'd love to work with you on a collaboration. Are you open to partnerships right now?"
        default:
            "Hi, I had a quick question and wondered whether you could help."
        }
    }

    static func reply(for config: AutoReplyConfig) -> String {
        var lines: [String] = ["Hi,", ""]

        let brand = config.business.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(brand.isEmpty ? "Thanks for getting in touch." : "Thanks for getting in touch with \(brand).")

        // Only what they actually approved. Each of these is skipped when the
        // field is blank, which is what the runtime does too.
        if config.allowed.contains(.product), !config.business.whatItDoes.isEmpty {
            lines.append(config.business.whatItDoes)
        }
        if config.allowed.contains(.pricing), !config.business.pricing.isEmpty {
            lines.append(config.business.pricing)
        }
        if config.allowed.contains(.availability), !config.business.availability.isEmpty {
            lines.append(config.business.availability)
        }

        // The honest ending. Where they gave Maily nothing to say, the reply
        // says nothing and hands it back -- which is the behaviour, not a
        // placeholder.
        if lines.count == 3 {
            lines.append(handoff(for: config))
        }

        lines.append("")
        lines.append(signOff())
        return lines.joined(separator: "\n")
    }

    private static func handoff(for config: AutoReplyConfig) -> String {
        switch config.whenUnsure {
        case .askSender:
            "Could you tell me a little more about what you need? That way I can point you in the right direction."
        default:
            "Let me come back to you on this shortly."
        }
    }

    private static func signOff() -> String {
        let custom = AppSettings.customInstructions
        // The sign-off they already gave Maily elsewhere, rather than a
        // second place to type the same thing.
        if let line = custom.split(separator: "\n").first(where: { $0.lowercased().contains("sign off") }) {
            return String(line)
        }
        return "Best"
    }
}
