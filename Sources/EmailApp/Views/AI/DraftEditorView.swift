import SwiftUI
import UIKit

/// The full editor for an email the assistant wrote, in the shape of
/// ChatGPT's: an X to leave, copy and send in the bar, the envelope fields,
/// the body, and along the bottom a row of one-tap changes plus a place to
/// ask for any other change in your own words.
///
/// Every edit lands straight in the draft on the card behind this screen,
/// so closing the editor is never "did that save". Send from here sends the
/// card's draft, through the same path, with the same result reporting.
struct DraftEditorView: View {
    @Binding var draft: ChatDraft
    let tone: String
    let onSend: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var showsCc = false
    @State private var request = ""
    @State private var isRevising = false
    @State private var revisionError: String?
    @FocusState private var isAskingForChanges: Bool

    private var canSend: Bool {
        !draft.to.address.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The changes people actually ask for, one tap each. Anything else
    /// goes in the field underneath.
    private static let quickChanges: [(title: String, instruction: String)] = [
        ("Make it warmer", "Make it warmer and more personal, without making it longer."),
        ("Polish the copy", "Polish the wording. Fix grammar, tighten the sentences, keep the meaning and the length."),
        ("Add a clear next step", "End with one clear next step or a specific ask, in one sentence."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    envelopeRow("To", text: $draft.to.address) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showsCc.toggle() }
                        } label: {
                            Image(systemName: "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showsCc ? 0 : 180))
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showsCc ? "Hide Cc" : "Show Cc")
                    }

                    if showsCc {
                        Divider()
                        envelopeRow("Cc", text: $draft.cc) { EmptyView() }
                    }

                    Divider()

                    TextField("Subject", text: $draft.subject)
                        .font(.body)
                        .padding(.vertical, 14)

                    Divider()

                    TextField("Write the email", text: $draft.body, axis: .vertical)
                        .font(.body)
                        .lineSpacing(4)
                        .lineLimit(8...80)
                        .padding(.top, 16)
                        .padding(.bottom, 24)

                    if let revisionError {
                        Label(revisionError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.bottom, 16)
                    }
                }
                .padding(.horizontal, 20)
                .disabled(isRevising)
                .opacity(isRevising ? 0.45 : 1)
                .animation(.easeOut(duration: 0.2), value: isRevising)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if isRevising {
                    ThinkingIndicator(label: "Rewriting")
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.regularMaterial))
                        .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { changesBar }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = draft.body
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy")

                    Button {
                        dismiss()
                        onSend()
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
        }
    }

    // MARK: - Pieces

    private func envelopeRow<Trailing: View>(
        _ label: String,
        text: Binding<String>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            Text("\(label):")
                .font(.body)
                .foregroundStyle(.secondary)
            TextField("Recipients", text: text)
                .font(.body)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            trailing()
        }
        .padding(.vertical, 12)
    }

    /// One-tap changes, then a field for any other change. Sits on the
    /// keyboard's safe area like the rest of the app's tool bars: this
    /// screen is a form, not a chat, and nothing here needs to track a
    /// keyboard drag.
    private var changesBar: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.quickChanges, id: \.title) { change in
                        Button {
                            revise(change.instruction)
                        } label: {
                            Text(change.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .frame(height: 40)
                                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                        }
                        .buttonStyle(PressButtonStyle())
                        .disabled(isRevising)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 10) {
                TextField("Ask for changes", text: $request)
                    .font(.body)
                    .focused($isAskingForChanges)
                    .submitLabel(.send)
                    .onSubmit(submitRequest)

                if !request.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(action: submitRequest) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(PressButtonStyle())
                    .disabled(isRevising)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .frame(height: 50)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
            .padding(.horizontal, 20)
            .animation(.easeOut(duration: 0.15), value: request.isEmpty)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Revising

    private func submitRequest() {
        let instruction = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        request = ""
        revise(instruction)
    }

    /// One change, applied by the model, landing in the draft. The body is
    /// the only thing that changes; the envelope is the person's.
    private func revise(_ instruction: String) {
        guard !isRevising else { return }
        isAskingForChanges = false
        isRevising = true
        revisionError = nil

        Task { @MainActor in
            defer { isRevising = false }
            do {
                let result = try await AIService.revise(
                    text: draft.body,
                    instruction: instruction,
                    replyingTo: draft.replyingTo,
                    tone: tone
                )
                withAnimation(.easeOut(duration: 0.2)) {
                    draft.body = result.body
                }
            } catch {
                revisionError = error.localizedDescription
            }
        }
    }
}
