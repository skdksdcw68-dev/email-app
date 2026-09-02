import SwiftUI

/// Auto-Reply, once it has been set up. Its own destination, not a row in a
/// settings list, because handing over your replies is the largest thing this
/// app asks anybody to do and it should be somewhere you can look at it.
///
/// Three states, and the difference between the last two matters: switching
/// Auto-Reply off keeps everything. Nobody should have to answer twelve
/// questions again because they went on holiday.
struct AutoReplyView: View {
    @Environment(AutoReplyStore.self) private var autoReply

    @State private var isSettingUp = false
    @State private var isConfirmingOff = false
    @State private var isConfirmingForget = false

    private var config: AutoReplyConfig { autoReply.config }

    var body: some View {
        List {
            if config.isSetUp {
                statusSection
                whatItDoesSection
                instructionsSection
                knowledgeSection
                manageSection
            } else {
                pitch
            }
        }
        .navigationTitle("Auto-Reply")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sheet(isPresented: $isSettingUp) {
            AutoReplySetupView(editing: config.isSetUp ? config : nil)
        }
        .alert("Turn off Auto-Reply?", isPresented: $isConfirmingOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off") { autoReply.setOn(false) }
        } message: {
            Text("Your setup is saved. You can turn it back on any time without answering anything again.")
        }
        .alert("Delete this setup?", isPresented: $isConfirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { autoReply.forgetSetup() }
        } message: {
            Text("Everything you taught Maily about your work goes with it. This cannot be undone.")
        }
    }

    // MARK: - Not set up

    private var pitch: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "arrowshape.turn.up.left.2.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text("Let Maily handle the routine replies.")
                        .font(.title3.weight(.bold))
                    Text("Tell it what you do, what it may answer, and what should always come back to you. It writes the replies; you decide what happens to them.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .listRowSeparator(.hidden)
            }

            Section {
                Button {
                    isSettingUp = true
                } label: {
                    Label("Set up Auto-Reply", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                }
            } footer: {
                Text("Takes a few minutes. Maily starts by drafting replies for you to send — it never sends anything on its own until you turn that on yourself.")
            }
        }
    }

    // MARK: - Set up

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: config.isOn ? "checkmark.circle.fill" : "pause.circle.fill")
                    .font(.title3)
                    .foregroundStyle(config.isOn ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.isOn ? "On" : "Off")
                        .font(.subheadline.weight(.semibold))
                    Text(config.isOn
                         ? "\(config.handledCount) kinds of mail handled automatically"
                         : "Setup saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(config.isOn ? "Turn off" : "Turn on") {
                    if config.isOn { isConfirmingOff = true } else { autoReply.setOn(true) }
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, 2)
        } footer: {
            Text(config.isOn
                 ? "Turning it off keeps everything you taught it."
                 : "Nothing is being answered while this is off.")
        }
    }

    private var whatItDoesSection: some View {
        Section {
            // Draft is the only mode offered today. Sending on somebody's
            // behalf waits on the verification layer -- the checks that a
            // reply is inside its permissions, that every fact in it came
            // from the person, and that it is not answering a machine. An
            // option that quietly skipped those would be the one mistake
            // this whole feature cannot afford.
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.footnote)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AutoReplyConfig.RunMode.draft.title)
                        .font(.subheadline.weight(.medium))
                    Text(AutoReplyConfig.RunMode.draft.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            HStack(spacing: 12) {
                Image(systemName: "paperplane")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AutoReplyConfig.RunMode.send.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Not yet. Maily has to be able to check its own work first — that a reply is inside what you allowed, that every fact in it came from you, and that it isn't answering a machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("What Maily does with a reply")
        }
    }

    private var instructionsSection: some View {
        Section {
            NavigationLink {
                AutoReplyInstructionsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom instructions")
                            .font(.subheadline.weight(.medium))
                        Text(instructionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text("Your own rules for how Maily writes. Edit them without going through the setup again.")
        }
    }

    private var instructionSummary: String {
        let active = config.activeInstructions.count
        let total = config.instructions.count
        if total == 0 { return "None yet" }
        if active == total { return "\(active) active instruction\(active == 1 ? "" : "s")" }
        return "\(active) of \(total) active"
    }

    private var knowledgeSection: some View {
        Section {
            row("You", config.persona?.title ?? "Not set", "person.fill")
            row("It may answer", "\(config.allowed.count) kinds of mail", "checkmark.circle.fill")
            row("Always asks you", "\(config.mustAsk.count) boundaries", "hand.raised.fill")
            row("When unsure", config.whenUnsure.title, "questionmark.circle.fill")
            row("Facts it may state",
                config.business.isEmpty ? "None" : "\(config.business.filled.count)",
                "brain.head.profile")
        } header: {
            Text("What it knows")
        } footer: {
            Text("Maily can only state facts you gave it. Anything else comes back to you.")
        }
    }

    private func row(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title).font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var manageSection: some View {
        Section {
            Button("Edit setup") { isSettingUp = true }
            Button("Delete setup", role: .destructive) { isConfirmingForget = true }
        } footer: {
            Text("Editing opens the same questions with your answers already in them.")
        }
    }
}

/// The instructions on their own, reachable without the setup flow.
///
/// This is the screen somebody opens after reading a reply they did not like,
/// so it is built for editing rather than for onboarding: swipe to delete,
/// drag to reorder, tap to switch one off and see whether that was the one.
struct AutoReplyInstructionsView: View {
    @Environment(AutoReplyStore.self) private var autoReply

    @State private var draft = ""
    @State private var editing: AutoReplyConfig.Instruction?
    @State private var editText = ""
    @State private var problem: String?

    private var instructions: [AutoReplyConfig.Instruction] { autoReply.config.instructions }

    var body: some View {
        List {
            Section {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .font(.subheadline)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Add a rule")
            } footer: {
                if let problem {
                    Text(problem).foregroundStyle(.orange)
                } else {
                    Text("These change how Maily writes, not what it knows. A price or a policy belongs in your setup, where Maily is allowed to state it as fact.")
                }
            }

            if instructions.isEmpty {
                Section {
                    Text("No rules yet. Maily writes in your usual style until you give it one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(instructions) { instruction in
                        Button {
                            autoReply.setInstruction(instruction.id, isOn: !instruction.isOn)
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: instruction.isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.body)
                                    .foregroundStyle(instruction.isOn ? Color.accentColor : Color.secondary.opacity(0.4))
                                Text(instruction.text)
                                    .font(.subheadline)
                                    .foregroundStyle(instruction.isOn ? .primary : .secondary)
                                    .strikethrough(!instruction.isOn, color: .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                guard let index = instructions.firstIndex(where: { $0.id == instruction.id })
                                else { return }
                                autoReply.removeInstructions(at: IndexSet(integer: index))
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editing = instruction
                                editText = instruction.text
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete { autoReply.removeInstructions(at: $0) }
                    .onMove { autoReply.moveInstructions(from: $0, to: $1) }
                } header: {
                    Text("Your rules")
                } footer: {
                    Text("Tap one to switch it off without deleting it. Drag to reorder — the ones nearer the top carry more weight.")
                }
            }
        }
        .navigationTitle("Custom instructions")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .toolbar { EditButton() }
        .keyboardDismissable()
        .alert("Edit instruction", isPresented: .constant(editing != nil)) {
            TextField("Instruction", text: $editText)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let editing { autoReply.updateInstruction(editing.id, text: editText) }
                editing = nil
            }
        }
    }

    private var placeholder: String {
        let examples = AutoReplyConfig.instructionExamples
        return examples[min(instructions.count, examples.count - 1)]
    }

    private func add() {
        problem = autoReply.addInstruction(draft) ? nil : reasonItFailed
        if problem == nil { draft = "" }
    }

    private var reasonItFailed: String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if instructions.contains(where: { $0.matches(trimmed) }) { return "You already told it that." }
        if instructions.count >= AutoReplyStore.instructionLimit {
            return "That's as many rules as Maily can hold at once."
        }
        return nil
    }
}
