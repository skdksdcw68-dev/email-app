import SwiftUI
import UIKit

/// The deep end. Profile points here; nothing in Profile is duplicated.
///
/// Laid out in the five groups from the plan. Where something genuinely does
/// not exist yet the page says so, rather than offering a control that moves
/// and changes nothing.
struct AppSettingsView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { AIAutomationSettingsView() } label: {
                    settingsRow("AI & Automation", "sparkles", "Permissions, approvals, priority rules")
                }
                NavigationLink { GmailAccountsView() } label: {
                    settingsRow("Accounts & Sync", "arrow.triangle.2.circlepath", "Mailbox, sync, permissions")
                }
                NavigationLink { PrivacySettingsView() } label: {
                    settingsRow("Privacy & Security", "lock.shield", "What leaves your phone, and what to delete")
                }
                NavigationLink { StorageSettingsView() } label: {
                    settingsRow("App", "iphone", "Storage and diagnostics")
                }
                NavigationLink { SupportView() } label: {
                    settingsRow("Support", "questionmark.circle", "Help, feedback, about")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }

    private func settingsRow(_ title: String, _ symbol: String, _ detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What the AI may do, what it must ask about, and the rules that steer it.
struct AIAutomationSettingsView: View {
    @Environment(MailStore.self) private var mail

    @State private var tagging = AppSettings.tagsIncomingMail
    @State private var summaries = AppSettings.writesSummaries
    @State private var asksBeforeBulk = !BulkReplyFlow.hasConsented

    private var important: [Person] { mail.people.filter(\.isImportant) }
    private var muted: [Person] { mail.people.filter(\.isMuted) }

    var body: some View {
        List {
            Section {
                Toggle("Read incoming mail", isOn: $tagging)
                    .onChange(of: tagging) { _, value in AppSettings.tagsIncomingMail = value }
                Toggle("Summarise when I open a message", isOn: $summaries)
                    .onChange(of: summaries) { _, value in AppSettings.writesSummaries = value }
            } header: {
                Text("AI permissions")
            } footer: {
                Text("With reading off, Maily still sorts mail using rules on this device. Those cost nothing and nothing leaves your phone.")
            }

            Section {
                Toggle("Warn me before writing in bulk", isOn: $asksBeforeBulk)
                    .onChange(of: asksBeforeBulk) { _, value in
                        UserDefaults.standard.set(!value, forKey: "bulkReply.consented")
                    }
                LabeledContent("Sending", value: "Always ask")
            } header: {
                Text("Approvals")
            } footer: {
                Text("Maily never sends mail on its own. Every reply, including bulk ones, is shown to you first.")
            }

            Section {
                if important.isEmpty && muted.isEmpty {
                    Text("Nothing set. Mark someone important or muted from their page in People.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(important) { person in
                        Label(person.contact.name, systemImage: "star.fill")
                            .foregroundStyle(.primary)
                    }
                    ForEach(muted) { person in
                        Label(person.contact.name, systemImage: "bell.slash.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Priority rules")
            } footer: {
                Text("Mail from important people scores higher; muted people never read as urgent. Set these from a person's page.")
            }

            Section {
                Text("Maily does not keep a log of what its AI did. Nothing is recorded beyond the tags and summaries you can already see on your mail.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("AI action history")
            }
        }
        .navigationTitle("AI & Automation")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }
}

/// What leaves the phone, and how to get rid of what stayed.
struct PrivacySettingsView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    @State private var showingDisconnect = false
    @State private var showingSignOut = false

    var body: some View {
        List {
            Section {
                Label("Read your mail", systemImage: "envelope.open")
                Label("Create drafts and send", systemImage: "paperplane")
            } header: {
                Text("Gmail permissions")
            } footer: {
                Text("Maily cannot archive, delete or star mail. That needs a further permission this app deliberately does not ask for.")
            }

            Section {
                Text("Your mail goes straight from Gmail to this phone. It does not pass through any server of ours.\n\nWhen the AI is used, only the sender, the subject and the opening of a message are sent, never a whole mailbox. Results are cached on the phone so the same message is never sent twice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Data processing")
            }

            Section {
                LabeledContent("Held on this device", value: "\(mail.messages.count) messages")
                LabeledContent("Offline copy", value: "Last three months")
                Button("Clear cached mail", role: .destructive) { MessageArchive.clear() }
            } header: {
                Text("Data retention")
            } footer: {
                Text("Clearing removes the offline copy only. Your mail stays in Gmail and returns on the next sync.")
            }

            Section {
                Button("Disconnect inbox", role: .destructive) { showingDisconnect = true }
                Button("Sign out and erase", role: .destructive) { showingSignOut = true }
            } header: {
                Text("Account")
            }
        }
        .navigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .alert("Disconnect inbox?", isPresented: $showingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { mail.disconnect() }
        } message: {
            Text("Removes the mailbox and every cached message from this device. Your Maily account and preferences are kept.")
        }
        .alert("Sign out and erase?", isPresented: $showingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                mail.disconnect()
                PersonPreferences.clearAll()
                user.signOut()
                Task { await AuthService.signOut() }
            }
        } message: {
            Text("Signs you out and removes the mailbox, the offline copy and your saved preferences from this device.")
        }
    }
}

/// Storage and the numbers worth knowing when something is wrong.
struct StorageSettingsView: View {
    @Environment(MailStore.self) private var mail

    @State private var archiveSize = "Calculating…"

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Messages", value: "\(mail.messages.count)")
                LabeledContent("Offline copy", value: archiveSize)
                Button("Clear cached mail", role: .destructive) {
                    MessageArchive.clear()
                    archiveSize = "0 KB"
                }
            } header: {
                Text("Storage")
            }

            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Mailbox", value: mail.account?.email ?? "None")
                LabeledContent("Connection", value: mail.connectionError ?? "OK")
                LabeledContent("People known", value: "\(mail.people.count)")
                LabeledContent("Follow-ups", value: "\(mail.followUps.count)")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Useful when reporting a problem.")
            }
        }
        .navigationTitle("App")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task { archiveSize = await MessageArchive.formattedSize() }
    }
}

struct SupportView: View {
    private let repo = URL(string: "https://github.com/skdksdcw68-dev/email-app")!

    var body: some View {
        List {
            Section {
                Link(destination: repo.appendingPathComponent("issues/new")) {
                    Label("Report a problem", systemImage: "exclamationmark.bubble")
                }
                Link(destination: repo.appendingPathComponent("issues")) {
                    Label("Send feedback", systemImage: "bubble.left.and.bubble.right")
                }
            } header: {
                Text("Get help")
            }

            Section {
                Text("Maily reads your Gmail, sorts it by what actually needs you, and writes replies you approve before anything is sent.\n\nIt talks to Gmail directly from your phone. No server of ours ever holds your mail.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About Maily")
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
    }
}
