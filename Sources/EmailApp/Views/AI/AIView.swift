import SwiftUI

/// The AI tab: what Maily can do.
///
/// The questions here resolve against the mailbox right now, deterministically
/// -- nothing is a placeholder. When a real model is wired in it answers the
/// same questions with judgement instead of filters, and gains free-form input.
struct AIView: View {
    @Environment(MailStore.self) private var mail

    var body: some View {
        NavigationStack {
            List {
                briefing

                Section("Ask Maily") {
                    ForEach(AIQuestion.all) { question in
                        NavigationLink(value: question) {
                            HStack(spacing: 12) {
                                Image(systemName: question.symbol)
                                    .font(.body)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.tint)
                                    .frame(width: 26)
                                Text(question.prompt)
                                    .font(.subheadline)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Label("Free-form questions and AI drafting arrive with the model.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("AI")
            .navigationDestination(for: AIQuestion.self) { AIAnswerView(question: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
        }
    }

    private var briefing: some View {
        Section("Daily briefing") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    Text(mail.inboxStatus)
                        .font(.subheadline.weight(.medium))
                }

                Text(briefingDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var briefingDetail: String {
        let counts = mail.counts
        var parts: [String] = ["\(counts.new) new"]
        if counts.important > 0 { parts.append("\(counts.important) important") }
        if counts.needsReply > 0 { parts.append("\(counts.needsReply) awaiting a reply") }
        if counts.urgent > 0 { parts.append("\(counts.urgent) urgent") }
        return parts.joined(separator: " · ")
    }
}

/// A question Maily can answer today, without a model.
struct AIQuestion: Identifiable, Hashable {
    let id: String
    let prompt: String
    let symbol: String
    let tag: AITag?
    /// Shown above the results, describing what was found.
    let emptyMessage: String

    static let all: [AIQuestion] = [
        .init(id: "reply", prompt: "What do I need to reply to?", symbol: "arrowshape.turn.up.left.fill",
              tag: .needsReply, emptyMessage: "Nothing is waiting on a reply."),
        .init(id: "urgent", prompt: "What is urgent right now?", symbol: "exclamationmark.3",
              tag: .urgent, emptyMessage: "Nothing urgent."),
        .init(id: "important", prompt: "What matters most this week?", symbol: "star.fill",
              tag: .veryImportant, emptyMessage: "Nothing flagged as very important."),
        .init(id: "ignore", prompt: "What can I safely ignore?", symbol: "tray.2.fill",
              tag: .noReplyNeeded, emptyMessage: "Nothing to skip."),
    ]
}

/// The answer to one question: the mail it matches.
struct AIAnswerView: View {
    let question: AIQuestion

    @Environment(MailStore.self) private var mail

    private var results: [Message] {
        mail.messages(in: .inbox, tag: question.tag)
    }

    var body: some View {
        List {
            if results.isEmpty {
                ContentUnavailableView(
                    "Nothing found",
                    systemImage: "checkmark.circle.fill",
                    description: Text(question.emptyMessage)
                )
            } else {
                Section {
                    ForEach(results) { message in
                        NavigationLink(value: message.id) {
                            MessageRow(message: message)
                        }
                        .messageSwipeActions(for: message)
                    }
                } header: {
                    Text("\(results.count) \(results.count == 1 ? "message" : "messages")")
                }
            }
        }
        .navigationTitle(question.prompt)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    AIView().environment(MailStore.connected())
}
