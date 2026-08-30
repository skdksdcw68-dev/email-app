import SwiftUI

/// Root of the Mail tab.
///
/// The inbox is normally already connected by the time this appears --
/// onboarding ends on `ConnectInboxView`. The disconnected state here is for a
/// user who disconnected from Settings and wants to reconnect, so it is a plain
/// reconnect prompt rather than the full onboarding pitch.
struct MailTabView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.isConnected {
                    MessageListView()
                } else {
                    reconnect
                }
            }
            .navigationDestination(for: Message.ID.self) { id in
                MessageDetailView(messageID: id)
            }
        }
    }

    private var reconnect: some View {
        ContentUnavailableView {
            Label("No Inbox Connected", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Connect your Google account to let Maily read and organize your email.")
        } actions: {
            Button {
                Task { await store.connect() }
            } label: {
                HStack(spacing: 8) {
                    if store.isConnecting {
                        ProgressView().tint(.white)
                    }
                    Text(store.isConnecting ? "Connecting\u{2026}" : "Connect Google")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isConnecting)
        }
        .navigationTitle("Mail")
    }
}

#Preview("Connected") {
    MailTabView().environment(MailStore.connected())
}

#Preview("Disconnected") {
    MailTabView().environment(MailStore())
}
