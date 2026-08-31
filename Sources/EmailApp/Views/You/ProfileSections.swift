import SwiftUI
import UIKit

/// Appearance, writing style and the custom instruction: the handful of
/// preferences worth reaching without going through Settings.
struct PersonalPreferencesView: View {
    @Environment(UserStore.self) private var user

    @State private var appearance = AppSettings.appearance
    @State private var instructions = AppSettings.customInstructions

    var body: some View {
        List {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppSettings.Appearance.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: appearance) { _, value in
                    AppSettings.appearance = value
                    // Tells the root to re-apply straight away rather than on
                    // the next launch.
                    NotificationCenter.default.post(name: .appearanceChanged, object: nil)
                }
            } header: {
                Text("Appearance")
            }

            Section {
                ForEach(WritingTone.allCases) { tone in
                    Button {
                        user.setTone(tone.rawValue)
                    } label: {
                        HStack {
                            Text(tone.title)
                                .foregroundStyle(.primary)
                            Spacer()
                            if user.tonePreference == tone.instruction {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Writing style")
            } footer: {
                Text("How Maily sounds when it writes on your behalf.")
            }

            Section {
                TextField(
                    "Keep my emails short and natural",
                    text: $instructions,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .onChange(of: instructions) { _, value in
                    AppSettings.customInstructions = value
                }
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Anything you want Maily to remember whenever it writes for you.")
            }
        }
        .navigationTitle("Personal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// The onboarding tone answers, as a list you can change later.
enum WritingTone: String, CaseIterable, Identifiable {
    case professional, warm, direct, thorough, casual

    var id: Self { self }

    var title: String {
        switch self {
        case .professional: "Professional"
        case .warm:         "Friendly"
        case .direct:       "Concise"
        case .thorough:     "Detailed"
        case .casual:       "Casual"
        }
    }

    /// Must match what UserStore.tonePreference produces, since that is what
    /// actually reaches the model.
    var instruction: String {
        switch self {
        case .professional: "formal and professional"
        case .warm:         "warm and friendly"
        case .direct:       "short and direct, no filler"
        case .thorough:     "detailed and thorough"
        case .casual:       "casual and relaxed"
        }
    }
}

/// What the AI is allowed to do, and what it costs.
struct AIPreferencesView: View {
    @State private var tagging = AppSettings.tagsIncomingMail
    @State private var summaries = AppSettings.writesSummaries

    var body: some View {
        List {
            Section {
                Toggle("Tag incoming mail", isOn: $tagging)
                    .onChange(of: tagging) { _, value in AppSettings.tagsIncomingMail = value }
            } footer: {
                Text("Off, Maily still sorts mail using rules on this device. Those are free and nothing leaves your phone.")
            }

            Section {
                Toggle("Summarise when I open a message", isOn: $summaries)
                    .onChange(of: summaries) { _, value in AppSettings.writesSummaries = value }
            } footer: {
                Text("Summaries are written when you open an email, so you only pay for what you read.")
            }

            Section {
                Label("Maily never sends without you", systemImage: "hand.raised.fill")
                    .font(.subheadline)
                Label("Only headers and the opening of a message are sent", systemImage: "lock.fill")
                    .font(.subheadline)
                Label("Results are cached, so nothing is paid for twice", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            } header: {
                Text("How it works")
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// The deep end: privacy, data, and the destructive actions.
struct AppSettingsView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail

    @State private var showingDisconnect = false
    @State private var showingSignOut = false

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Gmail access", value: "Read and send")
                LabeledContent("Mail stored on device", value: "\(mail.messages.count) messages")
            } header: {
                Text("Privacy and data")
            } footer: {
                Text("Mail is read straight from Gmail to your phone. It does not pass through a server of ours. Only headers and the opening of a message are ever sent to the AI.")
            }

            Section {
                Button("Clear cached mail", role: .destructive) {
                    MessageArchive.clear()
                }
            } footer: {
                Text("Removes the offline copy. Your mail stays in Gmail and comes back on the next refresh.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
                Link(destination: URL(string: "https://github.com/skdksdcw68-dev/email-app")!) {
                    Label("Help and feedback", systemImage: "questionmark.circle")
                }
            } header: {
                Text("About")
            }

            Section {
                Button("Disconnect inbox", role: .destructive) { showingDisconnect = true }
                Button("Sign out", role: .destructive) { showingSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .alert("Disconnect inbox?", isPresented: $showingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { mail.disconnect() }
        } message: {
            Text("Removes the mailbox and every cached message from this device. Your Maily account and preferences are kept.")
        }
        .alert("Sign out of Maily?", isPresented: $showingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                mail.disconnect()
                user.signOut()
                Task { await AuthService.signOut() }
            }
        } message: {
            Text("You will need to sign in again, and reconnect your inbox.")
        }
    }
}
