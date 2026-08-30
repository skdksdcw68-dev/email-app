import SwiftUI

/// Root of the Inbox tab.
///
/// The inbox is normally connected by the time this appears -- onboarding ends
/// on `ConnectInboxView`. The disconnected state here is for someone who
/// disconnected from You, so it is a plain reconnect prompt rather than the
/// full onboarding pitch.
struct InboxTabView: View {
    @Environment(MailStore.self) private var mail

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
    }

    private var reconnect: some View {
        ContentUnavailableView {
            Label("No Inbox Connected", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Connect your Google account to let Maily read and organize your email.")
        } actions: {
            Button {
                Task { await mail.connect() }
            } label: {
                Group {
                    if mail.isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Connect Google")
                    }
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mail.isConnecting)
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
