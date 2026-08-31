import SwiftUI
import UIKit

/// Profile: who you are, which mailbox you use, how Maily behaves, what you
/// are on, and the way into Settings.
///
/// Deliberately short. Profile is the handful of controls worth reaching in
/// one tap; the deep end lives behind Settings. A forty-item menu here would
/// be a settings screen wearing a profile's name.
struct YouView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    @State private var isEditingProfile = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                    Button("Edit profile") { isEditingProfile = true }
                        .font(.subheadline)
                }

                gmailSection

                Section {
                    NavigationLink { AppearanceView() } label: {
                        row("Appearance", "circle.lefthalf.filled")
                    }
                    NavigationLink { LanguageView() } label: {
                        row("Language", "globe")
                    }
                    NavigationLink { NotificationsView() } label: {
                        row("Notifications", "bell.badge")
                    }
                    NavigationLink { WritingStyleView() } label: {
                        row("Writing style", "pencil.line")
                    }
                } header: {
                    Text("Personal")
                }

                Section {
                    NavigationLink { AIPreferencesView() } label: {
                        row("AI preferences", "sparkles")
                    }
                } header: {
                    Text("AI")
                }

                Section {
                    NavigationLink { PlanView() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "star.circle.fill")
                                .font(.body)
                                .foregroundStyle(.tint)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Free")
                                    .font(.subheadline.weight(.medium))
                                Text("You pay your own AI costs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Plan")
                }

                Section {
                    NavigationLink { AppSettingsView() } label: {
                        row("Settings", "gearshape.fill")
                    }
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $isEditingProfile) { EditProfileView() }
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
                size: 56
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(user.account?.displayName ?? "You")
                    .font(.title3.weight(.bold))
                Text(user.account?.email ?? "Not signed in")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Gmail

    @ViewBuilder
    private var gmailSection: some View {
        Section {
            if let account = mail.account {
                HStack(spacing: 12) {
                    SenderAvatar(
                        contact: Contact(name: account.displayName, address: account.email),
                        size: 34
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text(account.email)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            } else {
                Label("No mailbox connected", systemImage: "envelope.badge.shield.half.filled")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            NavigationLink { GmailAccountsView() } label: {
                Text("Manage all accounts")
                    .font(.subheadline)
            }
        } header: {
            Text("Gmail accounts")
        }
    }

    private func row(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            Text(title)
                .font(.subheadline)
        }
        .padding(.vertical, 1)
    }
}

#Preview {
    YouView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
