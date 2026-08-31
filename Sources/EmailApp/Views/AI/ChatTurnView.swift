import SwiftUI
import UIKit

/// One bubble. The user's is a tinted capsule pushed right; the assistant's is
/// plain text on the page, which is how every assistant on the platform reads
/// -- boxing a long answer makes it look like a quotation rather than a reply.
struct ChatTurnView: View {
    let turn: ChatMessage

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
                    ThinkingIndicator()
                } else if turn.failed {
                    Label(turn.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text(turn.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !turn.sources.isEmpty {
                        SourceList(sources: turn.sources)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Thinking", with the three dots that tell you it has not stalled.
struct ThinkingIndicator: View {
    @State private var phase = 0

    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Text("Thinking")
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
        .accessibilityLabel("Thinking")
    }
}

/// The emails an answer came from, numbered to match its [1], [2] citations.
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

            ForEach(Array(shown.enumerated()), id: \.element.id) { index, message in
                NavigationLink(value: message.id) {
                    HStack(alignment: .top, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))

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

/// What the AI tab shows before anybody has asked anything: where the mailbox
/// stands, what is outstanding, and a few things worth asking.
struct AIChatWelcome: View {
    let briefing: String
    let followUps: [FollowUp]
    let onPick: (String) -> Void

    private static let starters = [
        "What needs my attention today?",
        "Who am I keeping waiting?",
        "Any deadlines this week?",
        "Summarise my important emails",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Today", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(briefing)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !followUps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Outstanding")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(followUps.prefix(3)) { followUp in
                        NavigationLink(value: followUp.message.id) {
                            HStack(spacing: 10) {
                                Image(systemName: followUp.direction == .waitingOnYou
                                      ? "arrowshape.turn.up.left.fill"
                                      : "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(followUp.isOverdue ? Color.orange : Color.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(followUp.message.sender.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(followUp.direction == .waitingOnYou
                                         ? "Waiting on you"
                                         : "No reply since \(followUp.ageDescription)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 12)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Try asking")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(Self.starters, id: \.self) { starter in
                    Button { onPick(starter) } label: {
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
    }
}
