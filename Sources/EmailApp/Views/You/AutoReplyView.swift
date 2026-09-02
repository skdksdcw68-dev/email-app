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
    @Environment(AutoReplyQueue.self) private var queue

    @State private var isSettingUp = false
    @State private var isConfirmingOff = false
    @State private var isConfirmingForget = false
    @State private var isConfirmingSend = false

    private var config: AutoReplyConfig { autoReply.config }

    var body: some View {
        List {
            if config.isSetUp {
                statusSection
                queueSection
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
        // A page, not a sheet. This is a setup, not a detail to glance at,
        // and a sheet says the opposite of what it is.
        .navigationDestination(isPresented: $isSettingUp) {
            AutoReplySetupView(editing: config.isSetUp ? config : nil)
        }
        .alert("Turn off Auto-Reply?", isPresented: $isConfirmingOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn off") { autoReply.setOn(false) }
        } message: {
            Text("Your setup is saved. You can turn it back on any time without answering anything again.")
        }
        .alert("Let Maily send on its own?", isPresented: $isConfirmingSend) {
            Button("Cancel", role: .cancel) {}
            Button("Let it send") { autoReply.setMode(.send) }
        } message: {
            Text("Replies will go without you seeing them first. Only ones Maily is sure about, that answered the whole message and passed the check against what you approved — never twice in one conversation, never more than \(MailStore.autoSendPerHour) an hour. You'll get a notification for each, and you can stop it at any time.")
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

    /// What Maily has actually done, above what it is allowed to do. The
    /// count is the first thing worth knowing when you open this screen.
    private var queueSection: some View {
        Section {
            NavigationLink {
                AutoReplyQueueView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full.fill")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replies")
                            .font(.subheadline.weight(.medium))
                        Text(queueSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if !queue.waiting.isEmpty {
                        Text("\(queue.waiting.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                .padding(.vertical, 2)
            }
        } footer: {
            Text("Nothing Maily writes is sent until you send it.")
        }
    }

    private var queueSummary: String {
        let waiting = queue.waiting.count
        if waiting == 0 {
            return queue.log.isEmpty ? "Nothing yet" : "Nothing waiting"
        }
        return waiting == 1 ? "1 reply waiting for you" : "\(waiting) replies waiting for you"
    }

    private var whatItDoesSection: some View {
        Section {
            ForEach(AutoReplyConfig.RunMode.allCases) { mode in
                Button {
                    if mode == .send && config.mode != .send {
                        isConfirmingSend = true
                    } else {
                        autoReply.setMode(mode)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode == .draft ? "square.and.pencil" : "paperplane.fill")
                            .font(.footnote)
                            .foregroundStyle(config.mode == mode ? Color.accentColor : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(mode.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if config.mode == mode {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }

            // The one control that has to work when somebody is panicking.
            // It stops everything and puts the mode back, so getting out is
            // one tap and does not depend on remembering which switch did
            // what.
            if config.mode == .send {
                Button(role: .destructive) {
                    autoReply.stopEverything()
                } label: {
                    Label("Stop sending now", systemImage: "hand.raised.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
        } header: {
            Text("What Maily does with a reply")
        } footer: {
            Text(config.mode == .send
                 ? "Maily only sends when it's over \(Int(MailStore.autoSendConfidenceFloor * 100))% sure, answered the whole message, and the reply passed the check against what you approved. Never twice in one conversation, never more than \(MailStore.autoSendPerHour) an hour, and you get a notification for each one."
                 : "Every reply waits for you. Nothing leaves on its own.")
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
