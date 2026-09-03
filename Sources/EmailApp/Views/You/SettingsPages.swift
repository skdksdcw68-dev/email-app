import SwiftUI
import UIKit

/// The deep end. Profile points here; nothing in Profile is duplicated.
///
/// Laid out in the five groups from the plan. Where something genuinely does
/// not exist yet the page says so, rather than offering a control that moves
/// and changes nothing.
struct AppSettingsView: View {
    @Environment(UserStore.self) private var user
    @Environment(AutoReplyStore.self) private var autoReply

    @State private var isEditingProfile = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        List {
            Section {
                Button { isEditingProfile = true } label: {
                    settingsRow("Personal information", "person.crop.circle",
                                "Your name and what you do")
                }
                .buttonStyle(.plain)
                NavigationLink { GmailAccountsView() } label: {
                    settingsRow("Gmail accounts", "envelope", "The mailbox, sync and permissions")
                }
                NavigationLink { PrivacySettingsView() } label: {
                    settingsRow("Account & security", "lock.shield", "What Maily holds about you")
                }
                Button(role: .destructive) { isConfirmingSignOut = true } label: {
                    settingsRow("Sign out", "rectangle.portrait.and.arrow.right",
                                "Leaves the app; your mail stays in Gmail", tint: .red)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Account")
            }

            Section {
                NavigationLink { AIAutomationSettingsView() } label: {
                    settingsRow("AI preferences", "sparkles", "Permissions, approvals, priority rules")
                }
                NavigationLink { WritingStyleView() } label: {
                    settingsRow("Writing style", "pencil.line", "How Maily sounds when it writes")
                }
                NavigationLink { MemorySettingsView() } label: {
                    settingsRow("Memory", "brain", "What you have told it to remember")
                }
                NavigationLink { AIUsageView() } label: {
                    settingsRow("AI usage", "gauge.with.dots.needle.33percent",
                                "What you have asked it to do this month")
                }
                NavigationLink { PersonalizationView() } label: {
                    settingsRow("Personalization", "person.text.rectangle",
                                "The answers that steer what it does")
                }
            } header: {
                Text("AI")
            }

            // Each of these opens the one question behind it, rather than
            // the whole eleven-step setup. The wizard is still there under
            // Edit setup for somebody who wants to walk the lot.
            Section {
                NavigationLink { AutoReplyView() } label: {
                    settingsRow("Auto-Reply", "arrowshape.turn.up.left.2",
                                autoReply.config.isSetUp
                                    ? (autoReply.config.isOn ? "On" : "Off, setup saved")
                                    : "Not set up")
                }
                if autoReply.config.isSetUp {
                    NavigationLink { AutoReplyEditView() } label: {
                        settingsRow("Edit setup", "slider.horizontal.3", "Change one thing at a time")
                    }
                    NavigationLink { AutoReplyInstructionsView() } label: {
                        settingsRow("Rules", "list.bullet.rectangle",
                                    "Your own rules for how it writes")
                    }
                    NavigationLink {
                        AutoReplySetupView(editing: autoReply.config, startingAt: .boundaries, singleStep: true)
                    } label: {
                        settingsRow("What always comes to you", "hand.raised",
                                    "\(autoReply.config.mustAsk.count) boundaries")
                    }
                    NavigationLink {
                        AutoReplySetupView(editing: autoReply.config, startingAt: .unsure, singleStep: true)
                    } label: {
                        settingsRow("When it isn't sure", "questionmark.circle",
                                    autoReply.config.whenUnsure.title)
                    }
                    NavigationLink {
                        AutoReplySetupView(editing: autoReply.config, startingAt: .knowledge, singleStep: true)
                    } label: {
                        settingsRow("What it may state", "brain.head.profile",
                                    autoReply.config.business.isEmpty
                                        ? "Nothing yet"
                                        : "\(autoReply.config.business.filled.count) facts")
                    }
                }
            } header: {
                Text("Auto-Reply")
            }

            Section {
                NavigationLink { NotificationSettingsView() } label: {
                    settingsRow("Notifications", "bell", "New mail, and what Maily did for you")
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("One switch for now. Maily wakes on new mail, reads it on this phone, and tells you when Auto-Reply has sent something.")
            }

            Section {
                NavigationLink { PrivacySettingsView() } label: {
                    settingsRow("Privacy", "hand.raised.square", "What leaves your phone, and what does not")
                }
                NavigationLink { StorageSettingsView() } label: {
                    settingsRow("Data and storage", "internaldrive",
                                "What is held here, and how to delete it")
                }
            } header: {
                Text("Privacy & Data")
            }

            Section {
                NavigationLink { AppearanceView() } label: {
                    settingsRow("Theme", "circle.lefthalf.filled", "Light, dark or your device setting")
                }
            } header: {
                Text("Appearance")
            }

            Section {
                NavigationLink { LanguageView() } label: {
                    settingsRow("Language", "globe", "What Maily reads and writes in")
                }
                NavigationLink { AutomationsView() } label: {
                    settingsRow("What runs on its own", "bolt.badge.clock",
                                "Sorting, follow-ups and Auto-Reply")
                }
                NavigationLink { PlanView() } label: {
                    settingsRow("Plan", "star.circle", "Free. You pay your own AI costs")
                }
            } header: {
                Text("General")
            }

            Section {
                NavigationLink { SupportView() } label: {
                    settingsRow("Help and support", "questionmark.circle",
                                "Report a problem, get in touch, about Maily")
                }
            } header: {
                Text("Support")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .sheet(isPresented: $isEditingProfile) { EditProfileView() }
        .alert("Sign out of Maily?", isPresented: $isConfirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { user.signOut() }
        } message: {
            Text("Your mail stays in Gmail. Anything Maily keeps on this phone goes.")
        }
    }

    private func settingsRow(
        _ title: String,
        _ symbol: String,
        _ detail: String,
        tint: Color = .accentColor
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(tint == .accentColor ? Color.primary : tint)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Whether new mail can reach the lock screen, and what to do when it cannot.
///
/// This screen exists because the failure it reports is otherwise invisible.
/// An app that has never asked for permission does not appear in iOS Settings
/// at all, so "notifications are off" and "notifications were never requested"
/// look identical from outside, and neither has a button anywhere.
struct NotificationSettingsView: View {
    @Environment(MailStore.self) private var mail
    @Environment(PushService.self) private var push

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    Text(push.isAuthorized ? "On" : "Off")
                        .foregroundStyle(push.isAuthorized ? Color.green : Color.secondary)
                }
                LabeledContent("This device") {
                    Text(push.token == nil ? "Not registered" : "Registered")
                        .foregroundStyle(push.token == nil ? Color.secondary : Color.green)
                }
                LabeledContent("Woken by Gmail") {
                    if let at = push.lastPushAt {
                        Text(at.formatted(.relative(presentation: .named)))
                            .foregroundStyle(Color.green)
                    } else {
                        Text("Never").foregroundStyle(Color.secondary)
                    }
                }
                if let result = push.lastPushResult {
                    LabeledContent("Last wake", value: result)
                }
            } header: {
                Text("New mail")
            } footer: {
                Text(push.isAuthorized
                     ? "Maily is woken when mail arrives, reads it on this phone, and writes the notification here. The sender and subject never leave your device."
                     : "Without this, new mail only appears when you open the app.")
            }

            if !push.isAuthorized {
                Section {
                    Button("Turn on notifications") {
                        Task { await push.enable(topic: PushService.topic) }
                    }
                    Button("Open iOS Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                } footer: {
                    // iOS shows the permission prompt once and once only. After
                    // that the button above does nothing visible, and the only
                    // way back is the Settings app.
                    Text("If the first button does nothing, iOS has already asked once. Use Settings instead.")
                }
            }

            if let error = push.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } header: {
                    Text("Last problem")
                }
            }

            if !mail.isConnected {
                Section {
                    Label("Connect a mailbox first.", systemImage: "tray")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task { await push.refreshAuthorization() }
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
    @Environment(ChatHistory.self) private var chats
    @Environment(AIMemory.self) private var memory

    @State private var showingDisconnect = false
    @State private var showingSignOut = false
    @State private var syncsChats = AppSettings.syncsChats
    @State private var sharesUsageData = AppSettings.sharesUsageData

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MemorySettingsView()
                } label: {
                    LabeledContent("What Maily remembers", value: "\(memory.facts.count)")
                }
            } header: {
                Text("Assistant memory")
            } footer: {
                Text("Say \"remember that…\" in a chat and it is kept here. Nothing is remembered unless you ask for it.")
            }

            Section {
                Toggle("Sync chats to my account", isOn: $syncsChats)
                    .onChange(of: syncsChats) { _, value in
                        AppSettings.syncsChats = value
                        if !value { Task { try? await Backend.deleteAll("chats") } }
                    }
                Toggle("Share usage data", isOn: $sharesUsageData)
                    .onChange(of: sharesUsageData) { _, value in
                        AppSettings.sharesUsageData = value
                    }
            } header: {
                Text("Sync and diagnostics")
            } footer: {
                Text("Syncing keeps your conversations on your Maily account so they follow you to another device. They include the email content quoted in them. Turning it off removes the synced copy and keeps everything on this phone.\n\nUsage data is how the app is used, never what is in it: which screens get opened, how long an answer takes, how often one fails. No email and nothing you type is included.")
            }

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
                FollowUpPreferences.clearAll()
                // Memory is about the person rather than the mailbox, so
                // disconnecting an inbox keeps it. Signing out does not.
                memory.forgetAll()
                chats.clearAll()
                user.signOut()
                Task { await AuthService.signOut() }
            }
        } message: {
            Text("Signs you out and removes the mailbox, the offline copy and your saved preferences from this device.")
        }
    }
}

/// Everything Maily has been told to remember, and the way to take it back.
///
/// A memory the person cannot see is a memory they cannot correct, and an
/// assistant that quietly holds a wrong fact about somebody is worse than
/// one that holds none.
struct MemorySettingsView: View {
    @Environment(AIMemory.self) private var memory

    @State private var showingClear = false

    var body: some View {
        List {
            if memory.facts.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "brain",
                        description: Text("Tell Maily \"remember that I sign off as Abel\" and it will keep it here.")
                    )
                }
            } else {
                // Grouped the way the model reads them. A situation shows
                // its last day, and greys out once it has passed: still
                // here so you can see what Maily knew, no longer applied.
                ForEach(AIMemory.Kind.allCases, id: \.self) { kind in
                    let facts = memory.facts.filter { $0.kind == kind }
                    if !facts.isEmpty {
                        Section(kind.title) {
                            ForEach(facts) { fact in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(fact.text)
                                        .font(.subheadline)
                                    if let until = fact.until {
                                        Text(fact.isExpired()
                                             ? "Ended \(until.formatted(.dateTime.day().month(.wide)))"
                                             : "Until \(until.formatted(.dateTime.day().month(.wide)))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(fact.isExpired() ? .secondary : .primary)
                            }
                            .onDelete { offsets in
                                for index in offsets { memory.forget(facts[index].id) }
                            }
                        }
                    }
                }

                Section {
                    Button("Forget everything", role: .destructive) { showingClear = true }
                } footer: {
                    Text("Swipe to remove one. Maily decides which kind each is when you tell it, and stops applying a situation the day after it ends.")
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .alert("Forget everything?", isPresented: $showingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { memory.forgetAll() }
        } message: {
            Text("Maily will stop applying all \(memory.facts.count) of these. It cannot be undone.")
        }
    }
}

/// Storage and the numbers worth knowing when something is wrong.
struct StorageSettingsView: View {
    @Environment(MailStore.self) private var mail

    @State private var archiveSize = "Calculating…"
    @State private var isChecking = false

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

            // What Gmail says is in the window against what is actually here.
            // Without this the app could be missing most of three months and
            // the only symptom was an assistant that could not find things.
            Section {
                if let audit = mail.importAudit {
                    LabeledContent("Last 3 months") {
                        Text("\(audit.held) of \(audit.expected)")
                            .foregroundStyle(audit.isComplete ? Color.green : Color.orange)
                    }
                    if !audit.isComplete {
                        LabeledContent("Still to fetch", value: "\(audit.missing)")
                    }
                } else {
                    LabeledContent("Last 3 months", value: isChecking ? "Checking…" : "Not checked yet")
                }

                Button(isChecking ? "Checking…" : "Check against Gmail") {
                    isChecking = true
                    Task {
                        await mail.verifyAgainstGmail(force: true)
                        isChecking = false
                    }
                }
                .disabled(isChecking || !mail.isConnected)
            } header: {
                Text("Sync")
            } footer: {
                Text("Maily counts what Gmail holds for the last three months and fetches anything it is missing. It checks once a day on its own.")
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
