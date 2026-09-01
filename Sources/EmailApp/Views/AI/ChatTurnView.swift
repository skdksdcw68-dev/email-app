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
    let onDiscardDraft: () -> Void

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
                        AssistantProse(text: turn.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Selection alone is fiddly on a long answer; this
                            // takes the whole thing in one gesture.
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.string = turn.text
                                } label: {
                                    Label("Copy answer", systemImage: "doc.on.doc")
                                }
                            }
                    }

                    ForEach(turn.blocks) { block in
                        AnswerBlockView(block: block)
                    }

                    if let draft = Binding($turn.draft) {
                        EmailDraftCard(draft: draft, onSend: onSendDraft, onDiscard: onDiscardDraft)
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

/// The emails an answer came from.
struct SourceList: View {
    let sources: [Message]

    @State private var isExpanded = false

    private var shown: [Message] {
        isExpanded ? sources : Array(sources.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Based on")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Unnumbered. The model no longer writes [1], [2] into the prose,
            // so numbering these would point at markers that are not there.
            ForEach(shown) { message in
                NavigationLink(value: message.id) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "envelope.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)

                        VStack(alignment: .leading, spacing: 1) {
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

            if sources.count > 3 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show fewer" : "Show all \(sources.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
    }
}
