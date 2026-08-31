import SwiftUI
import UIKit

/// Writing replies to a lot of email at once, as a flow rather than a sheet.
///
/// A sheet was wrong for this. Generating eighty replies takes real time and
/// costs real money, and the results are worth more than a modal that a stray
/// downward swipe throws away. Each stage is a full screen, and the work
/// survives until the user leaves deliberately.
struct BulkReplyFlow: View {
    let messages: [Message]

    @Environment(MailStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    /// Straight past the warning for anyone who has already read it and asked
    /// not to see it again.
    @State private var step: Step = BulkReplyFlow.hasConsented ? .count : .consent
    @State private var selection: Selection = .count(10)
    @State private var manualPicks: Set<Message.ID> = []
    @State private var style: WriterStyle = .short
    @State private var instruction = ""

    @State private var drafts: [PendingReply] = []
    @State private var generated = 0
    @State private var sentCount = 0
    @State private var errorMessage: String?

    enum Step {
        case consent, count, manualPick, style, generating, review, sending, done
    }

    /// How many to write. "All" is resolved late so it stays correct if the
    /// mailbox changes underneath.
    enum Selection: Equatable {
        case count(Int)
        case all
        case manual
    }

    struct PendingReply: Identifiable {
        let id: Message.ID
        let message: Message
        var body: String
        var isSent = false
        var failure: String?
    }

    private static let consentKey = "bulkReply.consented"

    /// Everything a reply could reasonably be written for.
    private var eligible: [Message] {
        messages.filter { !$0.tags.contains(.noReplyNeeded) }
    }

    /// What will actually be written, with the requested count clamped to what
    /// exists -- asking for fifty out of twelve means twelve, not an error.
    private var targets: [Message] {
        switch selection {
        case .all: return eligible
        case .count(let n): return Array(eligible.prefix(n))
        case .manual: return eligible.filter { manualPicks.contains($0.id) }
        }
    }

    /// Derived from what Abel measured on a real run: 86 replies moved the
    /// bill by roughly a quarter of a dollar. An estimate, shown as one.
    private static let costPerReply = 0.003

    private var estimatedCost: String {
        let total = Double(targets.count) * Self.costPerReply
        return total < 0.01 ? "under $0.01" : String(format: "about $%.2f", total)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .consent:    ConsentStep(onCancel: { dismiss() }, onContinue: advanceFromConsent)
                case .count:      countStep
                case .manualPick: manualPickStep
                case .style:      styleStep
                case .generating: GeneratingStep(done: generated, total: targets.count)
                case .review:     reviewStep
                case .sending:    SendingStep(done: sentCount, total: drafts.filter { !$0.isSent }.count + sentCount)
                case .done:       doneStep
                }
            }
            .toolbar {
                // No way out mid-flight. Leaving during generation wastes what
                // has already been paid for; leaving during a send would stop
                // it halfway with no record of where it got to.
                if step != .generating && step != .sending {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(step == .done ? "Done" : "Cancel") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(step == .generating || step == .sending)
    }

    // MARK: - Consent

    private func advanceFromConsent(rememberChoice: Bool) {
        if rememberChoice { UserDefaults.standard.set(true, forKey: Self.consentKey) }
        step = .count
    }

    /// Skips straight past the warning for anyone who ticked "don't ask again".
    static var hasConsented: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    // MARK: - How many

    private var countStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "How many replies?",
                subtitle: "\(eligible.count) \(eligible.count == 1 ? "email needs" : "emails need") a reply. Maily writes drafts for the ones you pick — nothing is sent yet."
            )

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(presetCounts, id: \.self) { number in
                        optionCard(
                            title: "\(number) replies",
                            detail: nil,
                            symbol: "square.stack.3d.up",
                            isSelected: selection == .count(number)
                        ) { selection = .count(number) }
                    }

                    optionCard(
                        title: "Reply to all",
                        detail: "\(eligible.count) emails",
                        symbol: "tray.full",
                        isSelected: selection == .all
                    ) { selection = .all }

                    CustomCountCard(
                        maximum: eligible.count,
                        isSelected: isCustomSelected,
                        current: customValue
                    ) { selection = .count($0) }

                    optionCard(
                        title: "Choose them myself",
                        detail: manualPicks.isEmpty ? nil : "\(manualPicks.count) selected",
                        symbol: "hand.tap",
                        isSelected: selection == .manual
                    ) {
                        selection = .manual
                        step = .manualPick
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            PrimaryButton(
                title: targets.isEmpty ? "Pick some emails" : "Continue with \(targets.count)",
                isEnabled: !targets.isEmpty
            ) { step = .style }
        }
        .navigationTitle("Reply with AI")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Only offer counts the mailbox can actually satisfy.
    private var presetCounts: [Int] {
        [5, 10, 15, 50].filter { $0 < eligible.count }
    }

    private var isCustomSelected: Bool {
        if case .count(let n) = selection { return !presetCounts.contains(n) }
        return false
    }

    private var customValue: Int {
        if case .count(let n) = selection, !presetCounts.contains(n) { return n }
        return 0
    }

    // MARK: - Choosing individually

    private var manualPickStep: some View {
        VStack(spacing: 0) {
            List {
                ForEach(eligible) { message in
                    Button {
                        if manualPicks.contains(message.id) {
                            manualPicks.remove(message.id)
                        } else {
                            manualPicks.insert(message.id)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            SenderAvatar(contact: message.sender, size: 40)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.sender.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(message.subject)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: manualPicks.contains(message.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(manualPicks.contains(message.id)
                                                 ? Color.accentColor : Color.secondary.opacity(0.4))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)

            PrimaryButton(
                title: manualPicks.isEmpty ? "Select at least one" : "Done — \(manualPicks.count) selected",
                isEnabled: !manualPicks.isEmpty
            ) { step = .count }
        }
        .navigationTitle("Choose emails")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Style

    private var styleStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeader(
                title: "How should they sound?",
                subtitle: "The same style is used for all \(targets.count). You will read every draft before anything is sent."
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    FlowLayout(spacing: 8) {
                        ForEach(WriterStyle.allCases.filter { $0 != .polish }) { option in
                            StyleChip(option: option, isSelected: style == option) {
                                style = option
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Anything to say in all of them?")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("I'm travelling this week, will reply properly on Monday",
                                  text: $instruction, axis: .vertical)
                            .font(.subheadline)
                            .lineLimit(2...4)
                            .padding(12)
                            .background {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            }
                    }

                    Label("Roughly \(estimatedCost) for \(targets.count) replies.", systemImage: "creditcard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .dismissesKeyboardOnTap()

            PrimaryButton(title: "Generate \(targets.count) replies", isEnabled: !targets.isEmpty) {
                dismissKeyboard()
                step = .generating
                Task { await generateAll() }
            }
        }
        .navigationTitle("Style")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Review

    private var reviewStep: some View {
        VStack(spacing: 0) {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                ForEach($drafts) { $draft in
                    Section {
                        DraftCard(draft: $draft) { Task { await send(draft.id) } }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .dismissesKeyboardOnTap()

            if !unsent.isEmpty {
                PrimaryButton(title: "Send all \(unsent.count)", isEnabled: true) {
                    step = .sending
                    Task { await sendAll() }
                }
            }
        }
        .navigationTitle("\(drafts.count) drafts ready")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var unsent: [PendingReply] {
        drafts.filter { !$0.isSent && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color(uiColor: .systemGreen))
                .transition(.scale.combined(with: .opacity))

            VStack(spacing: 6) {
                Text(sentCount == 1 ? "1 reply sent" : "\(sentCount) replies sent")
                    .font(.title2.weight(.bold))
                if drafts.contains(where: { $0.failure != nil }) {
                    Text("Some could not be sent. Go back to see which.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            PrimaryButton(title: "Back to inbox", isEnabled: true) { dismiss() }
        }
        .padding(.horizontal, 4)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Work

    private func generateAll() async {
        generated = 0
        errorMessage = nil
        var produced: [PendingReply] = []

        let extra = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sequential on purpose. Eighty concurrent model calls is a rate limit
        // and a surprise bill, and the counter on screen would be a lie.
        for message in targets {
            do {
                let draft = try await AIService.draft(
                    replyingTo: message,
                    instruction: extra.isEmpty ? style.instruction : "\(style.instruction) \(extra)",
                    tone: user.tonePreference
                )
                produced.append(PendingReply(id: message.id, message: message, body: draft.body))
            } catch {
                produced.append(
                    PendingReply(id: message.id, message: message, body: "",
                                 failure: error.localizedDescription)
                )
            }
            generated += 1
        }

        drafts = produced
        step = .review
    }

    private func sendAll() async {
        let queue = unsent.map(\.id)
        sentCount = 0

        for id in queue {
            await send(id)
        }

        step = .done
    }

    private func send(_ id: Message.ID) async {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let draft = drafts[index]
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        do {
            try await store.send(
                subject: draft.message.subject.lowercased().hasPrefix("re:")
                    ? draft.message.subject
                    : "Re: \(draft.message.subject)",
                to: draft.message.sender.address,
                body: draft.body,
                replyingTo: draft.message
            )
            drafts[index].isSent = true
            drafts[index].failure = nil
            store.markRead(draft.message.id)
            sentCount += 1
        } catch {
            drafts[index].failure = error.localizedDescription
        }
    }

    // MARK: - Shared bits

    private func optionCard(
        title: String,
        detail: String?,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    }
                }

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(Color.accentColor)
                          : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)))
            }
        }
        .buttonStyle(.plain)
    }
}
