import SwiftUI

/// Search, presented from the inbox toolbar rather than pinned above the mail.
///
/// A permanent search bar cost a row of vertical space on every launch to serve
/// something people reach for occasionally. As a sheet it gets the whole screen
/// and the keyboard when it is actually wanted.
struct SearchView: View {
    @Environment(MailStore.self) private var mail
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// `searchable(text:isPresented:)` is iOS 17 and opens the field focused.
    /// `.searchFocused` would be tidier but is iOS 18 only.
    @State private var isFieldPresented = true

    /// Searches every mailbox, not just the inbox -- someone looking for a
    /// message rarely knows or cares which folder it landed in.
    private var results: [Message] {
        guard !query.isEmpty else { return [] }
        return Mailbox.allCases
            .filter { !$0.isSmart }
            .flatMap { mail.messages(in: $0, matching: query) }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { message in
                    NavigationLink(value: message.id) {
                        MessageRow(message: message)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, isPresented: $isFieldPresented, prompt: "Search all mail")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView(
                        "Search your mail",
                        systemImage: "magnifyingglass",
                        description: Text("Find messages by sender, subject or content.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}

#Preview {
    SearchView().environment(MailStore.connected())
}
