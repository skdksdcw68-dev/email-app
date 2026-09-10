import SwiftUI

/// Root of the Inbox tab.
///
/// The inbox is normally connected by the time this appears -- onboarding ends
/// on `ConnectInboxView`. The disconnected state here is for someone who
/// disconnected from You, so it is a plain reconnect prompt rather than the
/// full onboarding pitch.
struct InboxTabView: View {
    @Environment(MailStore.self) private var mail

    @State private var isConnecting = false

    var body: some View {
        NavigationStack {
            Group {
                if mail.isConnected {
                    InboxHomeView()
                } else {
                    reconnect
                }
            }
            .navigationDestination(for: Message.ID.self) { id in
                MessageDetailView(messageID: id)
            }
        }
        // The same flow the + on Manage accounts opens, so the provider
        // question is asked in one place and answered the same way wherever
        // somebody starts from. This used to call `mail.connect()` directly,
        // which meant Google or nothing.
        .sheet(isPresented: $isConnecting) { AddMailboxFlow() }
    }

    private var reconnect: some View {
        ContentUnavailableView {
            Label("No Inbox Connected", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Connect a mailbox to let Maily read and organize your email. Gmail, iCloud, Yahoo and any other mail account.")
        } actions: {
            Button {
                isConnecting = true
            } label: {
                Text("Connect a mailbox")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Inbox")
    }
}

#Preview("Connected") {
    InboxTabView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}

#Preview("Disconnected") {
    InboxTabView()
        .environment(MailStore())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
