import SwiftUI

struct SettingsView: View {
    @Environment(MailStore.self) private var store

    @State private var autoTagging = true
    @State private var summaries = true
    @State private var urgentAlerts = true
    @State private var showingDisconnectAlert = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection

                if store.isConnected {
                    Section("AI") {
                        Toggle("Tag incoming mail", isOn: $autoTagging)
                        Toggle("Write summaries", isOn: $summaries)
                        Toggle("Notify me about urgent mail", isOn: $urgentAlerts)
                    }

                    Section {
                        Button("Disconnect Gmail", role: .destructive) {
                            showingDisconnectAlert = true
                        }
                    } footer: {
                        Text("Removes the account and every cached message from this device.")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .alert("Disconnect Gmail?", isPresented: $showingDisconnectAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) { store.disconnect() }
            } message: {
                Text("You will need to sign in again to see your mail.")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if let account = store.account {
            Section("Account") {
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
            }
        } else {
            Section {
                ContentUnavailableView(
                    "No Account",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("Connect Gmail from the Mail tab to get started.")
                )
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

#Preview("Connected") {
    SettingsView().environment(MailStore.connected())
}

#Preview("Not connected") {
    SettingsView().environment(MailStore())
}
