import SwiftUI
import UIKit

/// One turn. The user's is a tinted capsule pushed right; the assistant's is
/// typography on the page -- prose through `AssistantProse`, structured
/// blocks, and a draft card when it has written an email -- which is how
/// every assistant on the platform reads. Boxing a long answer makes it look
/// like a quotation rather than a reply.
struct ChatTurnView: View {
    @Binding var turn: ChatMessage
    let onSendDraft: () -> Void
    let onEditDraft: () -> Void
    let onDiscardDraft: () -> Void
    var onUndo: () -> Void = {}

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(turn.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    }
                    .textSelection(.enabled)
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                if turn.isPending {
                    ThinkingIndicator(label: turn.pendingLabel ?? "Thinking")
                } else if turn.failed {
                    Label(turn.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    if !turn.text.isEmpty {
                        // No context menu here any more: the prose is a real
                        // text view with the system's own selection and edit
                        // menu, and a SwiftUI long-press menu on top of it
                        // would swallow the press that starts a selection.
                        AssistantProse(text: turn.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(turn.blocks) { block in
                        AnswerBlockView(block: block)
                    }

                    if let draft = Binding($turn.draft) {
                        EmailDraftCard(
                            draft: draft,
                            onSend: onSendDraft,
                            onEdit: onEditDraft,
                            onDiscard: onDiscardDraft
                        )
                    }

                    if let receipt = turn.receipt {
                        ActionReceiptCard(receipt: receipt, onUndo: onUndo)
                    }

                    if turn.isLocal {
                        // The honest label for a free answer: this one never
                        // left the phone and cost nothing.
                        Label("Answered on device", systemImage: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    if !turn.sources.isEmpty {
                        SourceList(sources: turn.sources)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What an action did, and how to take it back.
///
/// The draft card set the pattern: an action the assistant performs shows
/// itself, states its result, and admits its limits. Marking read is the
/// first one that is not an email, so the caveat lives here -- it happened
/// inside Maily, and Gmail elsewhere is unchanged.
struct ActionReceiptCard: View {
    let receipt: ChatReceipt
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: receipt.isUndone ? "arrow.uturn.backward" : receipt.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(receipt.isUndone ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)
                .background {
                    Circle().fill(
                        (receipt.isUndone ? Color.secondary : Color.accentColor).opacity(0.12)
                    )
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.isUndone ? "Put back the way it was." : receipt.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(receipt.isUndone ? .secondary : .primary)
                if let detail = receipt.detail, !receipt.isUndone {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if !receipt.undo.isEmpty && !receipt.isUndone {
                Button("Undo", action: onUndo)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .animation(.snappy(duration: 0.25), value: receipt.isUndone)
    }
}

/// "Thinking", or whatever the work is, with the three dots that tell you it
/// has not stalled.
struct ThinkingIndicator: View {
    var label = "Thinking"

    @State private var phase = 0

    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 4, height: 4)
                        .opacity(phase == index ? 1 : 0.3)
                }
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityLabel(label)
    }
}

/// The emails an answer came from, folded into one quiet line.
///
/// Verifiability matters, but a card of twenty emails under every answer
/// was louder than the answer. Collapsed, this is a caption; tapped, it
/// opens into the same cards the assistant uses everywhere else, each one a
/// link to the message.
struct SourceList: View {
    let sources: [Message]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "envelope.fill")
                        .font(.caption2)
                    Text(sources.count == 1 ? "Based on 1 email" : "Based on \(sources.count) emails")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide sources" : "Show sources")

            if isExpanded {
                AnswerMessageList(messages: sources)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
