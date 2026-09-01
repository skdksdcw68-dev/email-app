import SwiftUI
import UIKit

/// An email Maily has written, sitting in the conversation waiting for a
/// decision. Modelled on the card ChatGPT shows for the same thing: a quiet
/// header with the actions in it, the envelope fields, the body, and one
/// footer line that says where the send stands.
///
/// Send is the only way anything leaves. Edit opens the full editor;
/// Discard drops it. Once it has gone the card locks and says so.
struct EmailDraftCard: View {
    @Binding var draft: ChatDraft
    let onSend: () -> Void
    let onEdit: () -> Void
    let onDiscard: () -> Void

    private var hasAddress: Bool {
        !draft.to.address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSend: Bool {
        hasAddress && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recipient: String {
        draft.to.name.isEmpty || draft.to.name.contains("@") ? draft.to.address : draft.to.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            field("To", hasAddress ? recipient : "Add a recipient", isPlaceholder: !hasAddress)
            hairline
            field("Subject", draft.subject.isEmpty ? "No subject" : draft.subject, isPlaceholder: draft.subject.isEmpty)
            hairline

            // Selectable a word at a time, so a line of the draft can be
            // copied out without taking the whole thing.
            SelectableText(draft.body, font: .preferredFont(forTextStyle: .callout))
                .frame(maxWidth: .infinity, alignment: .leading)
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
                iconButton("pencil", label: "Edit", action: onEdit)
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
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
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
                iconButton("pencil", label: "Edit", action: onEdit)
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

    private func field(_ label: String, _ value: String, isPlaceholder: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(label == "Subject" ? .subheadline.weight(.medium) : .subheadline)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
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

                Text(hasAddress ? "Nothing is sent until you tap send." : "Tap edit to add an address.")
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
