import SwiftUI

/// Root of the Mail tab. Swaps between the connect screen and the inbox.
struct MailTabView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.isConnected {
                    MessageListView()
                } else {
                    ConnectGmailView()
                }
            }
            .navigationDestination(for: Message.ID.self) { id in
                MessageDetailView(messageID: id)
            }
        }
    }
}

#Preview {
    MailTabView().environment(MailStore.connected())
}
