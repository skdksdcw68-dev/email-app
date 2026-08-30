import SwiftUI

/// The You tab: how Maily works.
///
/// The onboarding answers are not decoration -- automation level, approval
/// rules and writing style are literally the `autonomy`, `approvals` and `tone`
/// questions, surfaced here so the user can see what their AI is set to.
struct YouView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    @State private var autoTagging = true
    @State private var summaries = true
    @State private var urgentAlerts = true
    @State private var showingDisconnectAlert = false
    @State private var showingSignOutAlert = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                inboxSection

                Section("AI") {
                    Toggle("Tag incoming mail", isOn: $autoTagging)
                    Toggle("Write summaries", isOn: $summaries)
                    Toggle("Notify me about urgent mail", isOn: $urgentAlerts)
                }

                preferencesSection
                subscriptionSection

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Link(destination: URL(string: "https://github.com/skdksdcw68-dev/email-app")!) {
                        Label("Help & feedback", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) { showingSignOutAlert = true }
                }
            }
            .navigationTitle("You")
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
                    // Ends the Supabase session as well; clearing only the
                    // local copy would leave the device still authenticated.
                    Task { await AuthService.signOut() }
                }
            } message: {
                Text("This clears your account and your AI preferences on this device.")
            }
        }
    }

    // MARK: - Sections

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

    /// Separate from the account above: this is a grant of access to one
    /// mailbox, not an identity. Disconnecting it keeps the account intact.
    @ViewBuilder
    private var inboxSection: some View {
        if let inbox = mail.account {
            Section {
                LabeledContent("Connected", value: inbox.email)
                Button("Disconnect inbox", role: .destructive) {
                    showingDisconnectAlert = true
                }
            } header: {
                Text("Connected accounts")
            } footer: {
                Text("Maily reads and organizes this mailbox on your behalf.")
            }
        } else {
            Section("Connected accounts") {
                Label("No inbox connected", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Automation level, approval rules and writing style are the onboarding
    /// answers, shown under the names the user would look for.
    @ViewBuilder
    private var preferencesSection: some View {
        let answered = user.questions.filter { !user.selections(for: $0).isEmpty }
        if !answered.isEmpty {
            Section {
                ForEach(answered) { question in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(settingName(for: question))
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

    private var subscriptionSection: some View {
        Section {
            LabeledContent("Plan", value: "Maily Free")
        } header: {
            Text("Subscription")
        } footer: {
            Text("Pro adds AI drafting, follow-up management, multiple accounts and daily briefings.")
        }
    }

    // MARK: - Helpers

    /// The onboarding wording is a question; here it should read as a setting.
    private func settingName(for question: OnboardingQuestion) -> String {
        switch question.id {
        case "autonomy": "Automation level"
        case "approvals": "Approval rules"
        case "tone": "Writing style"
        case "response_time": "Response expectations"
        case "priorities": "What matters most"
        case "delegate": "Delegated to Maily"
        case "role": "Your role"
        case "usage": "What you use email for"
        default: question.title
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
    YouView()
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(MailStore.connected())
}
