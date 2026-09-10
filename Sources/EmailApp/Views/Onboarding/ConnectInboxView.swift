import SwiftUI

/// The last onboarding step: granting Maily access to the mailbox.
///
/// Separate from `AccountView` on purpose. The Maily account says who you are;
/// this says which inbox the AI may read and manage. A user can disconnect the
/// inbox without losing their account or preferences.
///
/// 🔴 This screen used to *be* the connection: one "Connect Google" button
/// wired straight to `mail.connect()`. Somebody whose mail is not on Gmail
/// reached the end of onboarding and found nothing they could do -- even
/// though `AddMailboxFlow` has offered Google, Microsoft and IMAP for weeks,
/// and has had a `firstRun` mode built for exactly this moment that nothing
/// ever called.
///
/// So this is the pitch and the flow is the flow. One place that adds a
/// mailbox, which is the rule settled on 2026-09-06 -- the provider question
/// belongs to the flow's own first step, not to two screens that can disagree.
struct ConnectInboxView: View {
    @Environment(UserStore.self) private var user

    @State private var isConnecting = false

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
        .init(symbol: "sparkles", text: "Summarise what arrived so you know what needs you"),
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

            // Gmail, Outlook and anything with an IMAP server -- said here
            // rather than discovered on the next screen, because somebody
            // whose mail is not on Gmail should not have to tap a button
            // labelled with a competitor's name to find that out.
            Text("Works with Gmail, iCloud, Yahoo and any other mail account. Your mail is read on this phone, not copied to a server of ours.")
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
                isConnecting = true
            } label: {
                Text("Connect a mailbox")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)

            Text("You can disconnect at any time in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        // Full screen rather than a sheet: this is the last step of onboarding
        // rather than a detour from it, and the flow brings its own navigation
        // bar. Its X returns here, so nobody is trapped in the provider list.
        .fullScreenCover(isPresented: $isConnecting) {
            AddMailboxFlow(firstRun: true) {
                user.next()
            }
        }
    }
}

#Preview {
    ConnectInboxView()
        .environment(UserStore(defaults: .previews, startAt: .connectInbox))
        .environment(MailStore())
}
