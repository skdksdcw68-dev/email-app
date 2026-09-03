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
    @Environment(AutoReplyStore.self) private var autoReply
    @Environment(AutoReplyQueue.self) private var autoReplyQueue

    @State private var isEditingProfile = false
    @State private var appearance = AppSettings.appearance

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                    Button("Edit profile") { isEditingProfile = true }
                        .font(.subheadline)
                }

                gmailSection

                // What somebody manages, not what they configure. Everything
                // here is either a live number or a thing they change often;
                // the depth is one tap away at the bottom.
                Section {
                    NavigationLink { AIUsageView() } label: {
                        usageRow
                    }
                    NavigationLink { AIPreferencesView() } label: {
                        row("AI preferences", "sparkles")
                    }
                    NavigationLink { WritingStyleView() } label: {
                        row("Writing style", "pencil.line")
                    }
                    NavigationLink { MemorySettingsView() } label: {
                        row("Memory", "brain")
                    }
                    NavigationLink { PersonalizationView() } label: {
                        row("Personalization", "person.text.rectangle")
                    }
                } header: {
                    Text("AI")
                }

                // Its own section rather than a row among the others. It is
                // the one feature that acts on somebody's behalf, and how
                // much of it is running should be readable without opening
                // anything.
                Section {
                    NavigationLink { AutoReplyView() } label: {
                        autoReplyRow
                    }
                    if autoReply.config.isSetUp {
                        NavigationLink { AutoReplyEditView() } label: {
                            row("Edit setup", "slider.horizontal.3")
                        }
                        NavigationLink { AutoReplyInstructionsView() } label: {
                            row("Rules", "list.bullet.rectangle.fill")
                        }
                    }
                } header: {
                    Text("Auto-Reply")
                } footer: {
                    Text(autoReply.config.isSetUp
                         ? (autoReply.config.mode == .send
                            ? "Maily is sending replies for you."
                            : "Maily writes the replies and waits for you.")
                         : "Teach Maily to answer the mail you keep answering yourself.")
                }

                // Directly here, because it is one tap and everybody uses
                // it. A subpage for three options is a subpage nobody wants.
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppSettings.Appearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { _, value in
                        AppSettings.appearance = value
                        NotificationCenter.default.post(name: .appearanceChanged, object: nil)
                    }
                    .listRowSeparator(.hidden)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System follows your device setting.")
                }

                Section {
                    NavigationLink { AppSettingsView() } label: {
                        row("Settings", "Notifications, privacy, language and the rest",
                            "gearshape.fill")
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
                // What they do sits above the address, when they have said.
                // It is the more interesting line about a person, and the
                // one the assistant actually uses.
                if let occupation = user.account?.occupation, !occupation.isEmpty {
                    Text(occupation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(user.account?.email ?? "Not signed in")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

            // One mailbox at a time is what the app actually does, so this
            // connects when there is nothing connected and says so plainly
            // when there is. A row promising a second account would be a
            // promise the app cannot keep.
            NavigationLink { GmailAccountsView() } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add account")
                        .font(.subheadline)
                    Text(mail.isConnected
                         ? "One mailbox at a time. Swap it from here."
                         : "Connect your Gmail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink { GmailAccountsView() } label: {
                Text("Manage accounts")
                    .font(.subheadline)
            }
        } header: {
            Text("Accounts")
        }
    }

    /// Auto-Reply carries its own state on the row, because whether Maily is
    /// answering mail on your behalf is not something you should have to open
    /// a screen to find out.
    private var autoReplyRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrowshape.turn.up.left.2.fill")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Auto-Reply")
                    .font(.subheadline)
                Text(autoReplyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !autoReplyQueue.waiting.isEmpty {
                WaitingBadge(count: autoReplyQueue.waiting.count)
            } else if autoReply.config.isSetUp {
                Text(autoReply.config.isOn ? "On" : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(autoReply.config.isOn ? Color.green : Color.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    /// The count, on the row, because the moment somebody wants to know what
    /// the AI is costing them is the moment they open this tab -- not after
    /// tapping into a screen they did not know was there.
    private var usageRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("AI usage")
                    .font(.subheadline)
                Text(AIUsage.total == 0
                     ? "Nothing yet this month"
                     : "\(AIUsage.total) requests in \(AIUsage.monthName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    private var autoReplyDetail: String {
        let config = autoReply.config
        guard config.isSetUp else { return "Let Maily handle the routine replies" }
        guard config.isOn else { return "Setup saved" }
        let waiting = autoReplyQueue.waiting.count
        if waiting > 0 { return waiting == 1 ? "1 reply waiting" : "\(waiting) replies waiting" }
        return "\(config.handledCount) kinds of mail handled"
    }

    /// The same row with a second line under it, for the handful that carry
    /// a live number or a caveat worth reading before tapping.
    private func row(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
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
        .environment(AutoReplyStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply.json")))
        .environment(AutoReplyQueue(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply-queue.json")))
}
