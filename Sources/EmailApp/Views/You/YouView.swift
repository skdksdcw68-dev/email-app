import SwiftUI
import UIKit

/// The control centre: who you are, the mailbox behind it, and everything
/// touched often enough to be worth a tap rather than a search.
///
/// Two things are true at once here, and an earlier version of this screen
/// only managed the first. Labels are one word wherever a word will do and
/// the state sits on the right, because a settings list is read down its left
/// edge and a column of sentences cannot be. But *short* is not the same as
/// *few*: trimming the words and then moving five rows to Settings left a
/// control centre with nothing to control. What somebody uses lives here,
/// however tidy the emptier version looked.
///
/// Nothing on this screen is also in Settings. A control in two places is a
/// control to decide about twice, and one of the two drifts.
struct YouView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyStore.self) private var autoReply
    @Environment(AutoReplyQueue.self) private var autoReplyQueue
    @Environment(AIMemory.self) private var memory

    @State private var isEditingProfile = false
    @State private var appearance = AppSettings.appearance

    var body: some View {
        NavigationStack {
            List {
                Section { header.listRowSeparator(.hidden) }

                accounts

                Section {
                    SettingsRow("Usage", "chart.bar",
                                value: AIUsage.total == 0 ? "None" : "\(AIUsage.total)") {
                        AIUsageView()
                    }
                    SettingsRow("Preferences", "sparkles") { AIPreferencesView() }
                    SettingsRow("Writing", "pencil.line", value: user.writingToneTitle) {
                        WritingStyleView()
                    }
                    SettingsRow("Memory", "brain",
                                value: memory.facts.isEmpty ? "Empty" : "\(memory.facts.count)") {
                        MemorySettingsView()
                    }
                    SettingsRow("Personalization", "person.text.rectangle") {
                        PersonalizationView()
                    }
                } header: {
                    Text("AI")
                }

                // Its own section rather than a row among the others. It is
                // the one feature that acts on somebody's behalf, and how
                // much of it is running should be readable without opening
                // anything.
                Section {
                    SettingsRow("Auto-Reply", "arrowshape.turn.up.left",
                                value: autoReplyValue, badge: autoReplyQueue.waiting.count) {
                        AutoReplyView()
                    }
                    if autoReply.config.isSetUp {
                        SettingsRow("Setup", "slider.horizontal.3") { AutoReplyEditView() }
                        SettingsRow("Rules", "list.bullet.rectangle",
                                    value: autoReply.config.instructions.isEmpty
                                        ? "None" : "\(autoReply.config.activeInstructions.count)") {
                            AutoReplyInstructionsView()
                        }
                    }
                } header: {
                    Text("Auto-Reply")
                } footer: {
                    Text(autoReplyFooter)
                }

                appearanceSection

                Section {
                    SettingsRow("Settings", "gearshape") { AppSettingsView() }
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $isEditingProfile) { EditProfileView() }
        }
    }

    // MARK: - Header

    /// The avatar carries the way in to editing, the way the apps people
    /// already use put it there.
    ///
    /// The address is under the name because this is the one screen that
    /// answers "which account am I in?" -- and somebody who has to open a
    /// subpage to find that out has been sent looking for their own email.
    private var header: some View {
        VStack(spacing: 10) {
            Button { isEditingProfile = true } label: {
                SenderAvatar(
                    contact: Contact(
                        name: user.account?.displayName ?? "You",
                        address: user.account?.email ?? ""
                    ),
                    size: 76
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit profile")

            VStack(spacing: 2) {
                Text(user.account?.displayName ?? "You")
                    .font(.headline)
                if let occupation = user.account?.occupation, !occupation.isEmpty {
                    Text(occupation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text(user.account?.email ?? "Not signed in")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    // MARK: - Accounts

    /// The mailbox, shown rather than named.
    ///
    /// A single row saying "Mailbox — abel@gmail.com" is the same words in
    /// less space, and it loses the thing that made this section worth
    /// having: the face beside the address, and somewhere obvious to go when
    /// the answer is "not that one".
    @ViewBuilder
    private var accounts: some View {
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
                            .truncationMode(.middle)
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
            SettingsRow("Add account", "plus.circle",
                        value: mail.isConnected ? "Swap" : "Connect") {
                GmailAccountsView()
            }
            SettingsRow("Manage accounts", "person.crop.circle") { GmailAccountsView() }
        } header: {
            Text("Accounts")
        }
    }

    // MARK: - Appearance

    /// Three options laid out flat, not folded into a menu.
    ///
    /// A menu hides two of the three behind a tap and makes choosing a
    /// two-step job. The segmented control shows what there is and what is
    /// picked at once, and switching is a swipe along it -- which is what
    /// somebody flipping between light and dark actually does.
    private var appearanceSection: some View {
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
    }

    private var autoReplyValue: String {
        let config = autoReply.config
        guard config.isSetUp else { return "Off" }
        guard config.isOn else { return "Paused" }
        return config.mode == .send ? "Sending" : "Drafting"
    }

    private var autoReplyFooter: String {
        let config = autoReply.config
        guard config.isSetUp else {
            return "Teach Maily to answer the mail you keep answering yourself."
        }
        guard config.isOn else { return "Paused. Nothing is being written or sent." }
        return config.mode == .send
            ? "Maily is sending replies for you."
            : "Maily writes the replies and waits for you."
    }
}

/// One row: an icon, a word, and what it is set to.
///
/// The value on the right is the point. "Appearance — System" tells somebody
/// what they came to find out without opening anything, where a sentence
/// underneath the label only tells them what the label already said.
struct SettingsRow<Destination: View>: View {
    let title: String
    let symbol: String
    var value: String?
    var badge: Int = 0
    @ViewBuilder let destination: Destination

    init(
        _ title: String,
        _ symbol: String,
        value: String? = nil,
        badge: Int = 0,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.symbol = symbol
        self.value = value
        self.badge = badge
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 26)
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 12)
                if badge > 0 {
                    WaitingBadge(count: badge)
                } else if let value {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

#Preview {
    YouView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(AutoReplyStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply.json")))
        .environment(AutoReplyQueue(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply-queue.json")))
        .environment(AIMemory())
}
