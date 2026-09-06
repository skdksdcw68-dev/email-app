import SwiftUI
import UIKit

/// Everything Maily can be configured to do, on one page.
///
/// Long on purpose, and one word a row. This is the screen somebody opens
/// knowing roughly what they want; scanning a column of single words finds it
/// faster than reading a column of sentences explaining what each word means.
/// Where a row has a state, the state sits on the right, so the page answers
/// as much as it navigates.
///
/// Nothing here is repeated on the You tab. A control in two places is a
/// control somebody has to decide about twice, and one of the two will drift.
struct AppSettingsView: View {
    @Environment(UserStore.self) private var user
    @Environment(AutoReplyStore.self) private var autoReply
    @Environment(MailStore.self) private var mail
    @Environment(AIMemory.self) private var memory

    @State private var isConfirmingSignOut = false
    /// Read once on appear rather than on every draw: it asks the Google SDK,
    /// and a view body is not the place to.
    @State private var hasContacts = true

    private var config: AutoReplyConfig { autoReply.config }

    var body: some View {
        List {
            // The profile, the mailbox, usage, writing and personalization
            // live on You, and so does the theme. They are not repeated
            // here: a control in two places is a control to decide about
            // twice, and one of the two drifts.
            Section {
                SettingsRow("Memory",
                            value: memory.facts.isEmpty ? "Empty" : "\(memory.facts.count)") {
                    MemorySettingsView()
                }
                // No value rather than a wrong one. It read the string
                // literal "Free", so a paying Max subscriber was told their
                // plan was Free in Settings while the paywall simultaneously
                // showed Max as current. The screen behind it knows the truth
                // and asks the server for it.
                SettingsRow("Plan") { PlanView() }
            } header: {
                Text("Account")
            }

            // The chips at the top of the inbox, and what the AI sorts into.
            Section {
                SettingsRow("Categories", value: "\(CategoryStore.shared.visible.count)") {
                    CategoriesView()
                }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Rename, reorder or hide the categories, or add your own and tell Maily what belongs in it.")
            }

            senderPhotos

            // Everything Auto-Reply is configured to do. You carries whether
            // it is running and what is waiting; the shape of it is set here
            // and rarely opened again.
            Section {
                SettingsRow("Setup", value: config.isSetUp ? "Done" : "Not set up") {
                    config.isSetUp ? AnyView(AutoReplyEditView()) : AnyView(AutoReplyView())
                }
                if config.isSetUp {
                    // "Rules" was here, and it opened `AutoReplyInstructionsView`
                    // -- the same page reachable from Auto-Reply as "Custom
                    // instructions", from Edit setup as "Custom instructions",
                    // and inline in the setup flow. Four doors, three names,
                    // one page. This was the fourth.
                    SettingsRow("Boundaries", value: "\(config.mustAsk.count)") {
                        AutoReplySetupView(editing: config, startingAt: .boundaries, singleStep: true)
                    }
                    SettingsRow("Uncertainty", value: config.whenUnsure.shortTitle) {
                        AutoReplySetupView(editing: config, startingAt: .unsure, singleStep: true)
                    }
                    SettingsRow("Knowledge",
                                value: config.business.isEmpty
                                    ? "None" : "\(config.business.filled.count)") {
                        AutoReplySetupView(editing: config, startingAt: .knowledge, singleStep: true)
                    }
                }
            } header: {
                Text("Auto-Reply")
            }

            // Rows now say what the page they open is called. Eight of them
            // disagreed: "Automation" opened "AI & Automation", "Running"
            // opened "Automations", "Privacy" opened "Privacy & Security",
            // "Storage" opened "App". A row is a promise about where it goes.
            Section {
                SettingsRow("AI & Automation") { AIAutomationSettingsView() }
                SettingsRow("Notifications") { NotificationSettingsView() }
                SettingsRow("Language", value: "English") { LanguageView() }
            } header: {
                Text("App settings")
            }

            Section {
                SettingsRow("Privacy & Security") { PrivacySettingsView() }
                SettingsRow("Storage", value: "\(mail.messages.count)") {
                    StorageSettingsView()
                }
            } header: {
                Text("Privacy and data")
            }

            Section {
                SettingsRow("Help") { SupportView() }
            } header: {
                Text("Get help")
            }

            // Signs out of the **mailbox**, not the account.
            //
            // It used to say "Log out" and call `user.signOut()`, which clears
            // three UserDefaults keys, does not call `AuthService.signOut()`
            // at all, and leaves the mailbox connected. Meanwhile Privacy had
            // "Sign out and erase", which did the whole thing. Two buttons,
            // near-identical words, materially different outcomes, and no way
            // to tell which was which before pressing one.
            //
            // Now: this one disconnects the mailbox in front of you. Ending
            // the Maily account lives on Edit profile, alone, and says so.
            if let account = mail.account {
                Section {
                    Button(role: .destructive) { isConfirmingSignOut = true } label: {
                        Text("Sign out of this mailbox")
                            .font(Style.rowTitle)
                            .foregroundStyle(Color.urgent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Disconnects \(account.address) from this phone. Your Maily account, your other mailboxes and everything you have taught it stay. To sign out of Maily itself, go to You → Edit profile.")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        // Defaults to true so the row does not flash into view for somebody
        // who already granted it.
        .onAppear { hasContacts = AuthService.hasContactsAccess }
        .alert("Sign out of this mailbox?", isPresented: $isConfirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            // `disconnect`, not `user.signOut()`. The old button called the
            // latter, which ends the Maily *account* -- from a row that read
            // like it was about the mailbox.
            Button("Sign out", role: .destructive) { mail.disconnect() }
        } message: {
            Text("Its mail, read state, snoozes and drafts go from this phone, and Maily's access to it ends. Your mail itself is untouched, and you stay signed in to Maily.")
        }
    }

    /// Turning sender photographs on, for a grant that predates them.
    ///
    /// 🔴 This row is the whole reason the feature reaches anybody who is
    /// already using Maily. Contacts is asked for at sign-in now, but a grant
    /// made under an older build cannot contain a scope that did not exist
    /// then -- and it must not be *required*, because requiring it would make
    /// every existing session fail its scope check and sign the mailbox out.
    /// So it is offered, here, once.
    ///
    /// Shown only when it would do something: a Google mailbox that has not
    /// granted it yet. Once granted the row goes, rather than becoming a
    /// permanently-on switch that does nothing.
    @ViewBuilder
    private var senderPhotos: some View {
        if mail.account?.provider == .gmail, !hasContacts {
            Section {
                Button {
                    Task {
                        if await AuthService.requestContactsAccess() {
                            hasContacts = true
                            // Forced: whatever is on disk was fetched under
                            // the grant that just got wider.
                            await mail.refreshContacts(force: true)
                        }
                    }
                } label: {
                    LabeledContent {
                        Text("Off").foregroundStyle(.secondary)
                    } label: {
                        Text("Sender photos").font(Style.rowTitle)
                    }
                }
            } header: {
                Text("Mail")
            } footer: {
                // ⚠️ Says what it actually delivers. "See who is emailing you"
                // would promise a face on every row, and most rows will not
                // have one: a newsletter is not a Google account with a photo.
                Text("Shows a photo instead of a letter for people in your Google Contacts and people you have emailed, the way Gmail does. Maily reads their names, addresses and pictures, and nothing else.")
            }
        }
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

    @State private var newMail = AppSettings.notifiesNewMail
    @State private var autoReplySent = AppSettings.notifiesAutoReply
    @State private var importantOnly = AppSettings.notifiesOnlyImportant
    @State private var showingDiagnostics = false

    var body: some View {
        List {
            // 🔴 One switch when iOS has not agreed yet, and nothing else.
            //
            // The screen used to show its whole contents regardless -- status
            // rows, wake times, diagnostics -- to somebody who had not granted
            // permission and for whom none of it could be true. Offering a
            // page of settings that cannot take effect is worse than offering
            // one thing that can.
            if !push.isAuthorized {
                permissionGate
            } else {
                Section {
                    Toggle("New mail", isOn: $newMail)
                        .onChange(of: newMail) { _, value in AppSettings.notifiesNewMail = value }

                    if newMail {
                        Toggle("Only what matters", isOn: $importantOnly)
                            .onChange(of: importantOnly) { _, value in
                                AppSettings.notifiesOnlyImportant = value
                            }
                    }
                } header: {
                    Text("New mail")
                } footer: {
                    Text(importantOnly
                         ? "Only mail Maily tagged as urgent or needing a reply. Anything it has not read yet still comes through, because unread is not the same as unimportant."
                         : "Maily is woken when mail arrives, reads it on this phone, and writes the notification here. The sender and subject never leave your device.")
                }

                Section {
                    Toggle("Replies Maily sent for me", isOn: $autoReplySent)
                        .onChange(of: autoReplySent) { _, value in
                            AppSettings.notifiesAutoReply = value
                        }
                } header: {
                    Text("Auto-Reply")
                } footer: {
                    Text("Mail going out under your name without you seeing it first is the one thing worth interrupting you for. Separate from new mail on purpose — silencing a busy inbox should not silence this.")
                }

                // Per mailbox, and this now does something: the flag was
                // written by a switch on each mailbox's page and read by
                // nothing at all.
                if mail.registry.hasSeveral {
                    Section {
                        ForEach(mail.registry.accounts) { account in
                            Toggle(account.title, isOn: Binding(
                                get: { account.notifies },
                                set: { on in mail.registry.update(account.id) { $0.notifies = on } }
                            ))
                        }
                    } header: {
                        Text("Which mailboxes")
                    } footer: {
                        Text("The first thing anybody with two mailboxes wants is mail from one and quiet from the other.")
                    }
                }

                diagnostics
            }

            if !mail.isConnected {
                Section {
                    Text("Connect a mailbox first.")
                        .font(Style.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .task { await push.refreshAuthorization() }
    }

    /// The only thing on screen until iOS has said yes.
    private var permissionGate: some View {
        Section {
            Toggle("Allow notifications", isOn: Binding(
                get: { push.isAuthorized },
                set: { wantsOn in
                    guard wantsOn else { return }
                    Task { await push.enable(topic: PushService.topic, for: mail.registry.accounts) }
                }
            ))

            // iOS shows its prompt once per install and never again. After a
            // refusal the switch above genuinely cannot do anything, and
            // saying so is better than a control that silently fails.
            Button("Open iOS Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(Style.rowTitle)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Without this, new mail only appears when you open Maily. If the switch does nothing, iOS has already asked once — use Settings instead.")
        }
    }

    /// Kept, but folded away.
    ///
    /// These four lines are how a "notifications are not arriving" report gets
    /// diagnosed, and they have earned their place more than once. They are
    /// also not settings, and they were the entire screen -- somebody looking
    /// for a switch found a status report.
    private var diagnostics: some View {
        Section {
            DisclosureGroup("If something is not arriving", isExpanded: $showingDiagnostics) {
                LabeledContent("This device") {
                    Text(push.token == nil ? "Not registered" : "Registered")
                        .foregroundStyle(push.token == nil ? Color.secondary : Color.ok)
                }
                LabeledContent("Last woken") {
                    if let at = push.lastPushAt {
                        Text(at.formatted(.relative(presentation: .named)))
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                if let result = push.lastPushResult {
                    LabeledContent("Last wake", value: result)
                }
                if let error = push.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Style.rowDetail)
                        .foregroundStyle(Color.warning)
                }
            }
            .font(Style.rowTitle)
        }
    }
}

/// What the AI may do, what it must ask about, and the rules that steer it.
struct AIAutomationSettingsView: View {
    @Environment(MailStore.self) private var mail
    @Environment(AutoReplyStore.self) private var autoReply

    @State private var tagging = AppSettings.tagsIncomingMail
    @State private var summaries = AppSettings.writesSummaries
    @State private var asksBeforeBulk = !BulkReplyFlow.hasConsented

    private var autoReplyState: String {
        guard autoReply.config.isRunning else { return "Off" }
        return autoReply.config.mode == .send ? "Sending" : "Writing drafts"
    }

    private var important: [Person] { mail.people.filter(\.isImportant) }
    private var muted: [Person] { mail.people.filter(\.isMuted) }

    var body: some View {
        List {
            // What is actually running, and switchable where it can be.
            //
            // This was its own page called "Running", reached from a Settings
            // row called "Running" that opened a page titled "Automations".
            // Three read-only rows saying On or Off, two links to pages that
            // are already in Settings, and no way to change anything from the
            // one screen people open when they want something to stop.
            //
            // Folded in here, with the switch where there is one.
            Section {
                Toggle("Sorting new mail", isOn: $tagging)
                    .onChange(of: tagging) { _, value in AppSettings.tagsIncomingMail = value }

                Toggle("Summarising what I open", isOn: $summaries)
                    .onChange(of: summaries) { _, value in AppSettings.writesSummaries = value }

                // Not a toggle, because turning Auto-Reply on is a decision
                // with a confirmation attached and it belongs on its own
                // screen. This says what it is doing and goes there.
                NavigationLink { AutoReplyView() } label: {
                    LabeledContent("Auto-Reply") {
                        Text(autoReplyState)
                    }
                    .font(Style.rowTitle)
                }

                LabeledContent("Following up") {
                    Text("\(mail.followUps.count) watched")
                }
                .font(Style.rowTitle)
            } header: {
                Text("Running now")
            } footer: {
                Text("Everything Maily does on its own. With sorting off it still files mail using rules on this phone, which cost nothing.")
            }

            Section {
                Toggle("Warn me before writing in bulk", isOn: $asksBeforeBulk)
                    .onChange(of: asksBeforeBulk) { _, value in
                        // Stored inverted, and under a raw key rather than
                        // through AppSettings -- the flag records that consent
                        // was *given*, and the switch asks whether to warn.
                        UserDefaults.standard.set(!value, forKey: "bulkReply.consented")
                    }
                // Read-only because it is true and not a choice: nothing in
                // this app sends without a person pressing send. It is here so
                // the answer is visible, not so it can be changed.
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
                Button("Clear cached mail", role: .destructive) {
                    if let id = mail.account?.id { MessageArchive.clear(mailbox: id) }
                }
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
    @State private var isOn = AppSettings.remembersThings

    var body: some View {
        List {
            Section {
                Toggle("Remember things about me", isOn: $isOn)
                    .onChange(of: isOn) { _, value in AppSettings.remembersThings = value }
            } footer: {
                // Pause, not delete, and it says which. Somebody who turns
                // this off for an afternoon should not come back to an empty
                // page -- that is what Forget everything is for.
                Text(isOn
                     ? "Maily keeps what you tell it to remember and uses it when it writes for you."
                     : "Nothing new is kept and nothing already here is used. What Maily already knows is still below, and comes back if you turn this on again.")
            }

            if !memory.facts.isEmpty {
                Section {
                    NavigationLink { MemorySummaryView() } label: {
                        LabeledContent("Memory summary") {
                            Text("\(memory.facts.count)")
                        }
                        .font(Style.rowTitle)
                    }
                } footer: {
                    Text("Everything Maily knows about you, read as one page.")
                }
            }

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

/// What Maily knows about you, as prose rather than a list of rows.
///
/// 🔴 **Written here, on the phone, from what is already stored. No model
/// call, no tokens, no wait.**
///
/// Worth being explicit because the obvious implementation is the wrong one:
/// "summarise what you know about me" reads like a job for the model, and
/// doing it that way would charge for every viewing of this screen to restate
/// sentences that were already plain English when they were saved. The facts
/// were written by the model, inside a chat that was happening anyway. This
/// only groups them.
///
/// Each line is editable, because a page showing what an assistant believes
/// about somebody is useless if the only response to a wrong belief is to
/// delete the true half along with it.
struct MemorySummaryView: View {
    @Environment(AIMemory.self) private var memory

    @State private var editing: AIMemory.Fact?
    @State private var revised = ""

    var body: some View {
        List {
            ForEach(memory.summary()) { paragraph in
                Section {
                    Text(paragraph.body)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)

                    DisclosureGroup("Change these") {
                        ForEach(memory.facts.filter { $0.kind == paragraph.kind }) { fact in
                            Button {
                                revised = fact.text
                                editing = fact
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text(fact.text)
                                        .font(Style.rowDetail)
                                        .foregroundStyle(fact.isExpired() ? .secondary : .primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "pencil")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .onDelete { offsets in
                            let facts = memory.facts.filter { $0.kind == paragraph.kind }
                            for index in offsets { memory.forget(facts[index].id) }
                        }
                    }
                    .font(Style.rowDetail)
                } header: {
                    Text(paragraph.title)
                }
            }
        }
        .navigationTitle("Memory summary")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .overlay {
            if memory.facts.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "brain",
                    description: Text("Tell Maily \"remember that I sign off as Abel\" and it will keep it.")
                )
            }
        }
        .alert("Change this", isPresented: .constant(editing != nil)) {
            TextField("", text: $revised)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let editing { memory.revise(editing.id, to: revised) }
                editing = nil
            }
        } message: {
            Text("Maily will use these words instead.")
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
                    if let id = mail.account?.id { MessageArchive.clear(mailbox: id) }
                    archiveSize = "0 KB"
                }
            } header: {
                Text("Storage")
            } footer: {
                // The same sentence the other Clear button carries. Without
                // it this reads as though it deletes mail, which is why the
                // two screens should not have disagreed about explaining it.
                Text("Clearing removes the offline copy only. Your mail stays in Gmail and returns on the next sync.")
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
                LabeledContent("Mailbox", value: mail.account?.address ?? "None")
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
        .task {
            guard let id = mail.account?.id else { return }
            archiveSize = await MessageArchive.formattedSize(mailbox: id)
        }
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
