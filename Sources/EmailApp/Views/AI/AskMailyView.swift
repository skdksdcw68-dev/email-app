import SwiftUI
import UIKit

/// Free-form questions about the mailbox.
///
/// Retrieval happens on the device against mail already held, so only a
/// handful of messages leave the phone per question. The emails the answer
/// leaned on are listed underneath and are tappable -- an answer you can check
/// is worth more than one you have to trust.
struct AskMailyView: View {
    @Environment(MailStore.self) private var mail

    @State private var question = ""
    @State private var answer: String?
    @State private var sources: [Message] = []
    @State private var isWorking = false
    @State private var errorMessage: String?

    private static let starters = [
        "What needs my attention today?",
        "Who am I keeping waiting?",
        "Any deadlines this week?",
        "Show me invoices from this month",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let answer {
                    answerCard(answer)
                } else if !isWorking {
                    starterList
                }

                if isWorking { working }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .dismissesKeyboardOnTap()
        .navigationTitle("Ask Maily")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { askBar }
    }

    // MARK: - Pieces

    private var starterList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Self.starters, id: \.self) { starter in
                Button {
                    question = starter
                    Task { await send() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(starter)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonLine()
            SkeletonLine()
            SkeletonLine(width: 200)
        }
    }

    private func answerCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !sources.isEmpty {
                Divider()

                Text("Based on")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                // Numbered to match the [1], [2] citations in the answer.
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, message in
                    NavigationLink(value: message.id) {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.sender.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(message.subject)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about your email", text: $question, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))

            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(canAsk ? Color.accentColor : Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(!canAsk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canAsk: Bool {
        !isWorking && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Work

    private func send() async {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return }

        isWorking = true
        errorMessage = nil
        answer = nil
        defer { isWorking = false }

        let context = mail.context(for: asked)
        sources = context

        do {
            let result = try await AIService.ask(question: asked, context: context)
            answer = result.answer
        } catch {
            errorMessage = error.localizedDescription
            sources = []
        }
    }
}

#Preview {
    NavigationStack {
        AskMailyView()
    }
    .environment(MailStore.connected())
}
