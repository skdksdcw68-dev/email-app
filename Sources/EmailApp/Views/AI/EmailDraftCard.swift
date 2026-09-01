import SwiftUI
import UIKit

/// An email Maily has written, sitting in the conversation waiting for a
/// decision. Modelled on the card ChatGPT shows for the same thing: a quiet
/// header with the actions in it, the envelope fields, the body, and one
/// footer line that says where the send stands.
///
/// Send is the only way anything leaves. Edit lets the person fix the text
/// first; Discard drops it. Once it has gone the card locks and says so.
struct EmailDraftCard: View {
    @Binding var draft: ChatDraft
    let onSend: () -> Void
    let onDiscard: () -> Void

    @State private var isEditing = false

    private var isLocked: Bool { draft.status != .ready }

    private var recipient: String {
        draft.to.name.isEmpty || draft.to.name.contains("@") ? draft.to.address : draft.to.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            field("To", recipient)
            hairline
            subjectRow
            hairline

            bodyArea
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: draft.status)
        .animation(.easeOut(duration: 0.15), value: isEditing)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 14) {
            Text("Email")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            switch draft.status {
            case .ready:
                iconButton(isEditing ? "checkmark" : "pencil", label: isEditing ? "Done editing" : "Edit") {
                    isEditing.toggle()
                }
                iconButton("doc.on.doc", label: "Copy") {
                    UIPasteboard.general.string = draft.body
                }
                Button(action: onSend) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityLabel("Send")

            case .sending:
                ProgressView()
                    .tint(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.accentColor.opacity(0.75)))

            case .sent:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color(uiColor: .systemGreen))
                    .frame(width: 40, height: 40)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))

            case .failed:
                Button(action: onSend) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(PressButtonStyle())
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel(label)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var subjectRow: some View {
        HStack(spacing: 0) {
            if isEditing && !isLocked {
                TextField("Subject", text: $draft.subject)
                    .font(.subheadline.weight(.medium))
            } else {
                Text(draft.subject.isEmpty ? "No subject" : draft.subject)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(draft.subject.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var bodyArea: some View {
        if isEditing && !isLocked {
            TextField("Write the email", text: $draft.body, axis: .vertical)
                .font(.callout)
                .lineLimit(3...14)
        } else {
            Text(draft.body)
                .font(.callout)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch draft.status {
        case .ready:
            HStack {
                Button(role: .destructive, action: onDiscard) {
                    Text("Discard")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(PressButtonStyle())

                Spacer(minLength: 0)

                Text("Nothing is sent until you tap send.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .sending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Sending to \(recipient)…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .sent:
            Label("Sent to \(recipient)", systemImage: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: .systemGreen))

        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hairline: some View {
        Divider().padding(.horizontal, 16)
    }
}
