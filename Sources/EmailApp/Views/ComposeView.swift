import SwiftUI

struct ComposeView: View {
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
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
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
}

#Preview {
    ComposeView().environment(MailStore.connected())
}
