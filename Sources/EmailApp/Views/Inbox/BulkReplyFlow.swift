import SwiftUI
import UIKit

/// Writing replies to a lot of email at once, as a flow rather than a sheet.
///
/// A sheet was wrong for this. Generating eighty replies takes real time and
/// costs real money, and the results are worth more than a modal that a stray
/// downward swipe throws away. Each stage is a full screen, the stages slide
/// into each other like pages, and the work survives until the user leaves
/// deliberately.
struct BulkReplyFlow: View {
    let messages: [Message]

    @Environment(MailStore.self) private var store
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    /// Straight past the warning for anyone who has already read it and asked
    /// not to see it again.
    @State private var step: Step = BulkReplyFlow.hasConsented ? .count : .consent
    /// Which way the last step change went, so the slide matches.
    @State private var advancing = true
    @State private var selection: Selection = .count(10)
    @State private var manualPicks: Set<Message.ID> = []
    @State private var style: WriterStyle = .short
    @State private var instruction = ""

    @State private var drafts: [PendingReply] = []
    @State private var generated = 0
    /// Who is being written to right now, shown on the generating screen.
    @State private var writingTo: String?
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
        var isSending = false
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
            ZStack {
                stepView
                    .id(step)
                    // A real page-to-page move: the new step slides in from
                    // the side it belongs to while the old one settles away.
                    // Removal is deliberately direction-agnostic (fade and
                    // settle), so a step can never exit the wrong way.
                    .transition(.asymmetric(
                        insertion: .move(edge: advancing ? .trailing : .leading).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    ))
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: step)
            .toolbar { leadingChrome }
        }
        .interactiveDismissDisabled(step == .generating || step == .sending)
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .consent:
            ConsentStep(onContinue: advanceFromConsent)
        case .count:
            ReplyCountStep(
                available: eligible.count,
                selection: $selection,
                selectedCount: targets.count,
                onPickManually: { go(.manualPick) },
                onContinue: { go(.style) }
            )
        case .manualPick:
            manualPickStep
        case .style:
            styleStep
        case .generating:
            GeneratingStep(done: generated, total: targets.count, recipient: writingTo)
        case .review:
            reviewStep
        case .sending:
            SendingStep(done: sentCount, total: drafts.filter { !$0.isSent }.count + sentCount)
        case .done:
            DoneStep(
                sent: sentCount,
                hadFailures: drafts.contains { $0.failure != nil },
                onDone: { dismiss() }
            )
        }
    }

    /// The top-left control follows where you are: an X while nothing has
    /// been chosen yet, Back once there is a previous step to return to, and
    /// nothing at all mid-flight -- leaving during generation wastes what has
    /// been paid for, and leaving during a send would stop it halfway with no
    /// record of where it got to.
    @ToolbarContentBuilder
    private var leadingChrome: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            switch step {
            case .consent, .count:
                FlowCloseButton { dismiss() }
            case .manualPick, .style:
                FlowBackButton(showsLabel: true) { go(.count, forward: false) }
            case .review:
                FlowBackButton(showsLabel: true) { go(.style, forward: false) }
            case .done:
                FlowBackButton(showsLabel: true) { dismiss() }
            case .generating, .sending:
                EmptyView()
            }
        }
    }

    private func go(_ next: Step, forward: Bool = true) {
        advancing = forward
        step = next
    }

    // MARK: - Consent

    private func advanceFromConsent(rememberChoice: Bool) {
        if rememberChoice { UserDefaults.standard.set(true, forKey: Self.consentKey) }
        go(.count)
    }

    /// Skips straight past the warning for anyone who ticked "don't ask again".
    static var hasConsented: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
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
            ) { go(.count, forward: false) }
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
            .dismissesKeyboardOnBackgroundTap()

            PrimaryButton(title: "Generate \(targets.count) replies", isEnabled: !targets.isEmpty) {
                dismissKeyboard()
                go(.generating)
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
            .dismissesKeyboardOnBackgroundTap()

            if !unsent.isEmpty {
                PrimaryButton(title: "Send all \(unsent.count)", isEnabled: true) {
                    go(.sending)
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

    // MARK: - Work

    /// @MainActor is load-bearing. A plain async method called from a
    /// MainActor context does not stay on it, so `generated += 1` ran off the
    /// main actor and the counter sat at zero until the whole loop finished.
    @MainActor
    private func generateAll() async {
        generated = 0
        errorMessage = nil
        var produced: [PendingReply] = []

        let extra = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        // Sequential on purpose. Eighty concurrent model calls is a rate limit
        // and a surprise bill, and the counter on screen would be a lie.
        for message in targets {
            writingTo = message.sender.name
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

        writingTo = nil
        drafts = produced
        go(.review)
    }

    @MainActor
    private func sendAll() async {
        let queue = unsent.map(\.id)
        sentCount = 0

        for id in queue {
            await send(id)
        }

        go(.done)
    }

    @MainActor
    private func send(_ id: Message.ID) async {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        let draft = drafts[index]
        guard !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !draft.isSending, !draft.isSent else { return }

        drafts[index].isSending = true

        do {
            try await store.send(
                subject: draft.message.subject.lowercased().hasPrefix("re:")
                    ? draft.message.subject
                    : "Re: \(draft.message.subject)",
                to: draft.message.sender.address,
                body: draft.body,
                replyingTo: draft.message
            )
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                drafts[index].isSending = false
                drafts[index].isSent = true
                drafts[index].failure = nil
            }
            store.markReplied(draft.message.id)
            sentCount += 1
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) {
                drafts[index].isSending = false
                drafts[index].failure = error.localizedDescription
            }
        }
    }
}
