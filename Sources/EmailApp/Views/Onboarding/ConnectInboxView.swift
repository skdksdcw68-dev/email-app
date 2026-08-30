import SwiftUI

/// The last onboarding step: granting Maily access to the mailbox.
///
/// Separate from `AccountView` on purpose. The Maily account says who you are;
/// this says which inbox the AI may read and manage. A user can disconnect the
/// inbox without losing their account or preferences.
struct ConnectInboxView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    /// A struct rather than a tuple: Swift key paths cannot address tuple
    /// elements, so `ForEach(_, id: \.1)` does not compile.
    private struct Permission: Identifiable {
        let symbol: String
        let text: String
        var id: String { symbol }
    }

    private let permissions: [Permission] = [
        .init(symbol: "tray.full.fill", text: "Read your email so it can sort and prioritise it"),
        .init(symbol: "square.and.pencil", text: "Draft replies for you to review"),
        .init(symbol: "archivebox.fill", text: "Organize, label and archive on your behalf"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "envelope.badge.shield.half.filled.fill")
                .font(.system(size: 58))
                .foregroundStyle(.tint)

            Text("Connect your inbox")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.top, 22)

            Text("Maily needs access to your Google account to read, organize, draft and manage your email.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
                .padding(.horizontal, 30)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(permissions) { permission in
                    HStack(spacing: 14) {
                        Image(systemName: permission.symbol)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        Text(permission.text)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 34)
            .padding(.horizontal, 36)

            Spacer()

            Button {
                Task {
                    await mail.connect()
                    user.next()
                }
            } label: {
                // Spinner replaces the label rather than sitting next to an
                // ellipsis -- one indicator, in place.
                Group {
                    if mail.isConnecting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Connect Google").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(mail.isConnecting)
            .padding(.horizontal, 24)

            Text("You can disconnect at any time in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
    }
}

#Preview {
    ConnectInboxView()
        .environment(UserStore(defaults: .previews, startAt: .connectInbox))
        .environment(MailStore())
}
