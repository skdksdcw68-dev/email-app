import SwiftUI
import UIKit

/// The You tab: who you are, which mailbox you are using, and how Maily
/// should behave.
///
/// Deliberately short. Profile is the handful of controls worth reaching in
/// one tap; everything deeper lives behind Settings. A forty-item menu here
/// would be a settings screen wearing a profile's name.
struct YouView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    var body: some View {
        NavigationStack {
            List {
                Section { header }
                    .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20))

                mailboxSection

                Section {
                    NavigationLink {
                        PersonalPreferencesView()
                    } label: {
                        row("Personal", "paintbrush.fill", "Appearance, writing style")
                    }

                    NavigationLink {
                        AIPreferencesView()
                    } label: {
                        row("AI", "sparkles", "What Maily is allowed to do")
                    }
                }

                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "star.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free")
                                .font(.subheadline.weight(.semibold))
                            Text("Every feature, and you pay your own AI costs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Plan")
                }

                Section {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        row("Settings", "gearshape.fill", "Privacy, data, account")
                    }
                }
            }
            .navigationTitle("You")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            SenderAvatar(
                contact: Contact(
                    name: user.account?.displayName ?? "You",
                    address: user.account?.email ?? ""
                ),
                size: 58
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(user.account?.displayName ?? "You")
                    .font(.title3.weight(.bold))
                Text(user.account?.email ?? "Not signed in")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let provider = user.account?.provider {
                    Text("Signed in with \(provider.title)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Mailbox

    @ViewBuilder
    private var mailboxSection: some View {
        Section {
            if let account = mail.account {
                HStack(spacing: 12) {
                    SenderAvatar(
                        contact: Contact(name: account.displayName, address: account.email),
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName)
                            .font(.subheadline.weight(.medium))
                        Text(account.email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("Current")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .padding(.vertical, 2)
            } else {
                Label("No mailbox connected", systemImage: "envelope.badge.shield.half.filled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Gmail")
        } footer: {
            // Said plainly rather than left as a missing button somebody hunts
            // for. One mailbox is what the app supports today.
            Text(mail.account == nil
                 ? "Connect a mailbox from the Inbox tab."
                 : "Maily reads and organises this mailbox on your behalf. Support for a second account is not built yet.")
        }
    }

    private func row(_ title: String, _ symbol: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    YouView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
