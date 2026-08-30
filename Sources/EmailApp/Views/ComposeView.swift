import SwiftUI

struct ComposeView: View {
    /// When set, the sheet opens as a reply: recipient and subject prefilled,
    /// with the original quoted underneath.
    var replyingTo: Message? = nil

    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var recipient = ""
    @State private var subject = ""
    @State private var messageBody = ""

    private var canSend: Bool {
        recipient.contains("@") && !recipient.hasSuffix("@")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To") {
                        TextField("name@example.com", text: $recipient)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Subject") {
                        TextField("Subject", text: $subject)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    TextEditor(text: $messageBody)
                        .frame(minHeight: 220)
                        .overlay(alignment: .topLeading) {
                            if messageBody.isEmpty {
                                Text("Message")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .navigationTitle(replyingTo == nil ? "New Message" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: prefill)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        store.send(subject: subject, to: recipient, body: messageBody)
                        dismiss()
                    }
                    .disabled(!canSend)
                }
            }
        }
    }

    /// "Re: Re: x" is nobody's idea of a good subject line.
    private func prefill() {
        guard let original = replyingTo, recipient.isEmpty else { return }
        recipient = original.sender.address
        subject = original.subject.lowercased().hasPrefix("re:")
            ? original.subject
            : "Re: \(original.subject)"
        messageBody = "\n\n---\nOn \(original.fullDate), \(original.sender.name) wrote:\n\(original.body)"
    }
}

#Preview {
    ComposeView().environment(MailStore.connected())
}
