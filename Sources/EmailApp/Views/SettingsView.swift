import SwiftUI

struct SettingsView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    @State private var autoTagging = true
    @State private var summaries = true
    @State private var urgentAlerts = true
    @State private var showingDisconnectAlert = false
    @State private var showingSignOutAlert = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                inboxSection

                Section("AI") {
                    Toggle("Tag incoming mail", isOn: $autoTagging)
                    Toggle("Write summaries", isOn: $summaries)
                    Toggle("Notify me about urgent mail", isOn: $urgentAlerts)
                }

                preferencesSection

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }

                Section {
                    Button("Sign out", role: .destructive) { showingSignOutAlert = true }
                }
            }
            .navigationTitle("Settings")
            .alert("Disconnect inbox?", isPresented: $showingDisconnectAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) { mail.disconnect() }
            } message: {
                Text("Removes the mailbox and every cached message from this device. Your Maily account and preferences are kept.")
            }
            .alert("Sign out of Maily?", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign out", role: .destructive) {
                    mail.disconnect()
                    user.signOut()
                }
            } message: {
                Text("This clears your account and your AI preferences on this device.")
            }
        }
    }

    // MARK: - Sections

    /// The Maily account: who the customer is.
    @ViewBuilder
    private var accountSection: some View {
        if let account = user.account {
            Section("Maily account") {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.accentColor.opacity(0.18))
                        .frame(width: 46, height: 46)
                        .overlay {
                            Text(account.initials)
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName).font(.headline)
                        Text(account.email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("Signed in with", value: account.provider.title)
            }
        }
    }

    /// The Google grant: which mailbox the AI may act on. Separate from the
    /// account above -- disconnecting one does not touch the other.
    @ViewBuilder
    private var inboxSection: some View {
        if let inbox = mail.account {
            Section {
                LabeledContent("Connected", value: inbox.email)
                Button("Disconnect inbox", role: .destructive) {
                    showingDisconnectAlert = true
                }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Maily reads and organizes this mailbox on your behalf.")
            }
        } else {
            Section("Inbox") {
                Label("No inbox connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Echoes back what onboarding collected, so it is visible and obviously
    /// persisted rather than silently discarded.
    @ViewBuilder
    private var preferencesSection: some View {
        let answered = user.questions.filter { !user.selections(for: $0).isEmpty }
        if !answered.isEmpty {
            Section {
                ForEach(answered) { question in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(question.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(summary(for: question))
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Your preferences")
            } footer: {
                Text("Collected during setup. These shape how your AI works.")
            }
        }
    }

    private func summary(for question: OnboardingQuestion) -> String {
        let selected = user.selections(for: question)
        let labels = question.options.filter { selected.contains($0.id) }.map(\.label)
        return labels.isEmpty ? "Not set" : labels.joined(separator: ", ")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(MailStore.connected())
}
