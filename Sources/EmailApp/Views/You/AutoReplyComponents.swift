import SwiftUI
import UIKit

/// One question on a page. Title, one line of why, then the answer.
///
/// Deliberately the same shape as `QuestionView` in onboarding: same type
/// scale, same 20pt gutter, same left alignment. Somebody who has just signed
/// up should recognise this immediately -- it is the same app asking them
/// something, not a different screen borrowed from somewhere else.
struct StepHeader<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(_ title: String, _ subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 14)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two-across cards, like the onboarding grid. Compact once there are more
/// than eight, for the same reason: sixteen tall tiles is a scroll marathon.
struct OptionGrid: View {
    let options: [AutoReplyOptions.Option]
    let selected: Set<String>
    let onTap: (String) -> Void

    private var isCompact: Bool { options.count > 8 }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            spacing: 10
        ) {
            ForEach(options) { option in
                Button {
                    onTap(option.id)
                } label: {
                    Group {
                        if isCompact {
                            HStack(alignment: .top, spacing: 9) {
                                icon(option, size: 15)
                                label(option)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                icon(option, size: 22)
                                label(option)
                            }
                        }
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, minHeight: isCompact ? 66 : 104, alignment: .topLeading)
                    .background(background(for: option))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(option.id) ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    private func icon(_ option: AutoReplyOptions.Option, size: CGFloat) -> some View {
        Image(systemName: option.symbol)
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(selected.contains(option.id)
                             ? AnyShapeStyle(Color.accentColor)
                             : AnyShapeStyle(.secondary))
            .frame(width: isCompact ? 19 : 26, alignment: .leading)
    }

    private func label(_ option: AutoReplyOptions.Option) -> some View {
        Text(option.label)
            .font(isCompact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func background(for option: AutoReplyOptions.Option) -> some View {
        let isSelected = selected.contains(option.id)
        return RoundedRectangle(cornerRadius: 14)
            .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
    }
}

/// A full-width row, like the onboarding list layout. For choices whose
/// labels are sentences rather than nouns.
struct OptionRowCard: View {
    let label: String
    var detail: String? = nil
    let symbol: String?
    let isSelected: Bool
    var note: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                        .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let note, !isSelected {
                    Text(note)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color(uiColor: .tertiaryLabel))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// One of a handful, side by side. Five of these is a style, and five
/// screens of cards for the same thing would be a chore.
struct PickerRow<Value: Hashable & Identifiable>: View {
    let title: String
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    init(
        _ title: String,
        _ values: [Value],
        selection: Binding<Value>,
        label: @escaping (Value) -> String
    ) {
        self.title = title
        self.values = values
        _selection = selection
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote.weight(.semibold))
            Picker(title, selection: $selection) {
                ForEach(values) { value in
                    Text(label(value)).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

extension PickerRow where Value: RawRepresentable, Value.RawValue == String {
    /// Everything in the style block is an enum with a `title`, so the label
    /// closure is the same every time.
    init(_ title: String, _ values: [Value], selection: Binding<Value>) where Value: Titled {
        self.init(title, values, selection: selection) { $0.title }
    }
}

/// Anything with a display name. Lets the style pickers be declared in one
/// line each rather than five with the same closure copied out.
protocol Titled {
    var title: String { get }
}

extension AutoReplyConfig.Style.Tone: Titled {}
extension AutoReplyConfig.Style.Length: Titled {}
extension AutoReplyConfig.Style.Warmth: Titled {}
extension AutoReplyConfig.Style.Formality: Titled {}
extension AutoReplyConfig.Style.Emojis: Titled {}

/// A labelled field, for the few answers a card cannot give.
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
                .font(.body)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(uiColor: .secondarySystemBackground))
                }
        }
    }
}

// MARK: - Intro

struct AutoReplyIntroStep: View {
    var body: some View {
        StepHeader("Let Maily handle the routine replies.",
                   "Teach it how you work, what it can answer, and when it should bring you in.") {
            VStack(alignment: .leading, spacing: 16) {
                point("brain.head.profile", "Understand your work",
                      "It learns what you do and who writes to you.")
                point("list.bullet.rectangle.fill", "Follow your rules",
                      "It only answers what you allow, in the way you tell it to.")
                point("hand.raised.fill", "Know when to ask",
                      "Anything near a line comes back to you, untouched.")
            }
            .padding(.top, 6)
        }
    }

    private func point(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - What Maily understood

/// The model's own account of the setup, with a way back to each answer.
struct AutoReplyUnderstandingView: View {
    let understanding: AutoReplyUnderstanding?
    let isThinking: Bool
    let onEdit: (String) -> Void

    var body: some View {
        if let understanding {
            VStack(spacing: 10) {
                ForEach(understanding.sections, id: \.title) { section in
                    section(section.title, section.body, section.step)
                }

                Text("Everything here comes from the choices and information you provided.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        } else if isThinking {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .frame(height: 74)
                }
            }
            .redacted(reason: .placeholder)
        } else {
            Text("Maily couldn't put this together just now. Go back a step and try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, _ body: String, _ step: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                    .tracking(0.6)
                Spacer()
                Button("Edit") { onEdit(step) }
                    .font(.caption.weight(.semibold))
            }
            Text(body)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
    }
}

// MARK: - The example

/// A real reply, and the part that matters: what it refused to answer.
struct AutoReplyExampleView: View {
    let example: AutoReplyExample?
    let isThinking: Bool
    let onRegenerate: () -> Void
    let onEditRules: () -> Void

    var body: some View {
        if let example {
            VStack(alignment: .leading, spacing: 14) {
                block("Incoming", example.incoming, isReply: false)
                block("Maily's reply", example.reply, isReply: true)

                if !example.safety.isEmpty || !example.blockedFacts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHY THIS IS SAFE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                            .tracking(0.6)

                        if !example.safety.isEmpty {
                            Text(example.safety)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        ForEach(example.evidenceUsed, id: \.self) { fact in
                            row("checkmark.circle.fill", fact, .green)
                        }
                        ForEach(example.rulesFollowed, id: \.self) { rule in
                            row("list.bullet", rule, .secondary)
                        }
                        ForEach(example.blockedFacts, id: \.self) { blocked in
                            row("hand.raised.fill", blocked, .orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                }

                HStack(spacing: 16) {
                    Button("Generate another", action: onRegenerate)
                    Button("Change my rules", action: onEditRules)
                }
                .font(.subheadline)
            }
        } else if isThinking {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 110)
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .frame(height: 160)
            }
            .redacted(reason: .placeholder)
        } else {
            Text("Maily couldn't write an example just now. Try again in a moment.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func block(_ title: String, _ text: String, isReply: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(isReply
                              ? Color.accentColor.opacity(0.12)
                              : Color(uiColor: .secondarySystemBackground))
                }
        }
    }

    private func row(_ symbol: String, _ text: String, _ tint: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Done

struct AutoReplyDoneView: View {
    let allowed: Int
    let boundaries: Int
    let escalation: String

    @State private var isShown = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 62))
                .foregroundStyle(.tint)
                .scaleEffect(isShown ? 1 : 0.6)
                .opacity(isShown ? 1 : 0)

            Text("Auto-Reply is ready.")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("You've taught Maily what to handle and when to bring you in. It writes the replies and leaves them for you — nothing is sent until you say so.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 9) {
                summary("checkmark.circle.fill", "\(allowed) kinds of mail it can handle")
                summary("hand.raised.fill", "\(boundaries) things that always come to you")
                summary("questionmark.circle.fill", escalation)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { isShown = true }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func summary(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(width: 20)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Custom instructions

/// Add, edit, switch off, delete. A list rather than one text box, because
/// these are separate rules with separate lives.
struct InstructionEditor: View {
    @Binding var instructions: [AutoReplyConfig.Instruction]
    @Binding var draft: String

    @State private var editing: AutoReplyConfig.Instruction.ID?
    @State private var editText = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($instructions) { $instruction in
                InstructionRow(instruction: $instruction) {
                    editing = instruction.id
                    editText = instruction.text
                } onDelete: {
                    withAnimation(.snappy(duration: 0.2)) {
                        instructions.removeAll { $0.id == instruction.id }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                    .submitLabel(.done)
                    .onSubmit(add)

                Button(action: add) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.bottom, 6)
            }

            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
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

    /// A different example each time, so the field teaches by showing.
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
        withAnimation(.snappy(duration: 0.2)) { instructions.append(instruction) }
        draft = ""
    }
}

struct InstructionRow: View {
    @Binding var instruction: AutoReplyConfig.Instruction
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                instruction.isOn.toggle()
            } label: {
                Image(systemName: instruction.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(instruction.isOn ? Color.accentColor : Color(uiColor: .tertiaryLabel))
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
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
    }
}
