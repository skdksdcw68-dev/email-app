import SwiftUI
import UIKit

/// Renaming yourself. The email is whoever you signed in with and is not
/// editable here, so it is shown rather than offered as a field.
struct EditProfileView: View {
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("How Maily addresses you, and the name your replies go out under.")
                }

                Section {
                    LabeledContent("Email", value: user.account?.email ?? "Not signed in")
                    if let provider = user.account?.provider {
                        LabeledContent("Signed in with", value: provider.title)
                    }
                } footer: {
                    Text("Your email comes from the account you signed in with and cannot be changed here.")
                }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        user.setDisplayName(name)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { name = user.account?.displayName ?? "" }
        }
    }
}

/// Everything about the connected mailbox: status, what Maily is allowed to
/// do, and how to get rid of it.
struct GmailAccountsView: View {
    @Environment(MailStore.self) private var mail

    @State private var showingDisconnect = false
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section {
                if let account = mail.account {
                    HStack(spacing: 12) {
                        SenderAvatar(
                            contact: Contact(name: account.displayName, address: account.email),
                            size: 40
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(account.email)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 2)
                } else {
                    Label("No mailbox connected", systemImage: "envelope.badge.shield.half.filled")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Current")
            }

            if mail.isConnected {
                Section {
                    LabeledContent("Connection", value: mail.connectionError == nil ? "Connected" : "Problem")
                    LabeledContent("Messages held", value: "\(mail.messages.count)")
                    LabeledContent("Offline copy", value: "Last three months")
                    Button {
                        Task {
                            isRefreshing = true
                            await mail.refresh()
                            isRefreshing = false
                        }
                    } label: {
                        HStack {
                            Text(isRefreshing ? "Syncing…" : "Sync now")
                            Spacer()
                            if isRefreshing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(isRefreshing)
                } header: {
                    Text("Sync")
                }

                Section {
                    Label("Read your mail", systemImage: "envelope.open")
                    Label("Create drafts and send", systemImage: "paperplane")
                } header: {
                    Text("What Maily can do")
                } footer: {
                    // Stated plainly, because it is the reason archive and
                    // delete do not stick in Gmail.
                    Text("Maily cannot archive, delete or star mail. Doing that needs a further Gmail permission this app deliberately does not ask for.")
                }
            }

            Section {
                Button("Add another account") {}
                    .disabled(true)
            } footer: {
                Text("One mailbox at a time for now. Several accounts at once, and a combined inbox across them, is not built yet.")
            }

            if mail.isConnected {
                Section {
                    Button("Disconnect inbox", role: .destructive) { showingDisconnect = true }
                }
            }
        }
        .navigationTitle("Gmail accounts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .alert("Disconnect inbox?", isPresented: $showingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) { mail.disconnect() }
        } message: {
            Text("Removes the mailbox and every cached message from this device. Your Maily account and preferences are kept.")
        }
    }
}

/// Appearance on its own, as the plan has it.
struct AppearanceView: View {
    @State private var appearance = AppSettings.appearance

    var body: some View {
        List {
            Section {
                ForEach(AppSettings.Appearance.allCases) { option in
                    Button {
                        appearance = option
                        AppSettings.appearance = option
                        NotificationCenter.default.post(name: .appearanceChanged, object: nil)
                    } label: {
                        HStack {
                            Label(option.title, systemImage: option.symbol)
                                .foregroundStyle(.primary)
                            Spacer()
                            if appearance == option {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                Text("System follows your device setting.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Writing style on its own, as the plan has it.
struct WritingStyleView: View {
    @Environment(UserStore.self) private var user

    @State private var instructions = AppSettings.customInstructions

    var body: some View {
        List {
            Section {
                ForEach(WritingTone.allCases) { tone in
                    Button {
                        user.setTone(tone.rawValue)
                    } label: {
                        HStack {
                            Text(tone.title).foregroundStyle(.primary)
                            Spacer()
                            if user.tonePreference == tone.instruction {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                Text("How Maily sounds when it writes on your behalf.")
            }

            Section {
                TextField("Keep my emails short and natural", text: $instructions, axis: .vertical)
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
        .navigationTitle("Writing style")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Language. English only today, and it says so rather than offering a picker
/// that changes nothing.
struct LanguageView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("English")
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tint)
                }
            } footer: {
                Text("Maily is only available in English at the moment. It reads and writes mail in whatever language the mail is in, regardless of this setting.")
            }
        }
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// Notifications.
///
/// Deliberately not a page of switches that do nothing. Maily cannot deliver
/// notifications at all yet: that needs Gmail push through a server, which is
/// the one piece of architecture this app has avoided. Saying so is better
/// than storing preferences for a feature that does not exist.
struct NotificationsView: View {
    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not available yet")
                            .font(.subheadline.weight(.semibold))
                        Text("Maily reads your mail directly from Gmail to this phone, with no server in between. Push notifications need one, so they are not built yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Label("Urgent mail", systemImage: "bolt.fill")
                Label("Needs a reply", systemImage: "arrowshape.turn.up.left.fill")
                Label("Follow-up reminders", systemImage: "clock.arrow.circlepath")
                Label("Daily briefing", systemImage: "sun.max.fill")
            } header: {
                Text("Planned")
            } footer: {
                Text("These are what Maily will be able to tell you about once notifications are built.")
            }
            .foregroundStyle(.secondary)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// The plan. There is no subscription, and pretending otherwise would be a
/// sales page for a product that does not exist.
struct PlanView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Free")
                        .font(.title3.weight(.bold))
                    Text("Every feature is on. You pay your own AI costs directly, and nothing goes through Maily.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Current plan")
            }

            Section {
                Label("Roughly a third of a cent per email classified", systemImage: "creditcard")
                Label("Bulk mail is sorted by rules on this phone, at no cost", systemImage: "bolt.slash")
                Label("Results are cached, so nothing is paid for twice", systemImage: "arrow.clockwise")
            } header: {
                Text("What it costs")
            } footer: {
                Text("Estimates from real runs, not a quote. Your provider's dashboard is the real number.")
            }
        }
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
