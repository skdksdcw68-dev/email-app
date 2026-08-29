import SwiftUI

/// Shown until a Gmail account is connected.
struct ConnectGmailView: View {
    @Environment(MailStore.self) private var store

    private struct Promise: Identifiable {
        let icon: String
        let text: String
        var id: String { icon }
    }

    private let promises: [Promise] = [
        Promise(icon: "sparkles", text: "Every message read and tagged for you"),
        Promise(icon: "arrowshape.turn.up.left.fill", text: "Know what needs a reply at a glance"),
        Promise(icon: "exclamationmark.3", text: "Urgent mail surfaced before it burns you"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "envelope.badge.shield.half.filled.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .padding(.bottom, 24)

            Text("Connect your Gmail")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Your inbox, triaged by AI before you open it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(promises) { promise in
                    HStack(spacing: 14) {
                        Image(systemName: promise.icon)
                            .font(.body)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text(promise.text)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 40)
            .padding(.horizontal, 40)

            Spacer()

            Button {
                Task { await store.connect() }
            } label: {
                HStack(spacing: 10) {
                    if store.isConnecting {
                        ProgressView().tint(.white)
                    }
                    Text(store.isConnecting ? "Connecting\u{2026}" : "Connect Gmail Account")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.isConnecting)
            .padding(.horizontal, 24)

            Text("We never send mail on your behalf without asking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { ConnectGmailView() }
        .environment(MailStore())
}
