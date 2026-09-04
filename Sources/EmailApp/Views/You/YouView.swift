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

    @State private var isAddingMailbox = false
    @State private var appearance = AppSettings.appearance
    /// The mailbox a swipe is offering to sign out of.
    @State private var signingOut: MailAccount?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                    // A page, not a sheet. It is where the picture is set and
                    // where the account itself is signed out of, and neither
                    // of those is a thing you dismiss with a swipe.
                    NavigationLink("Edit profile") { EditProfileView() }
                        .font(.subheadline)
                }

                accounts

                Section {
                    SettingsRow("Usage",
                                value: AIUsage.total == 0 ? "None" : "\(AIUsage.total)") {
                        AIUsageView()
                    }
                    SettingsRow("Preferences") { AIPreferencesView() }
                    SettingsRow("Writing", value: user.writingToneTitle) {
                        WritingStyleView()
                    }
                    SettingsRow("Personalization") { PersonalizationView() }
                } header: {
                    Text("AI")
                }

                // Its own section rather than a row among the others. It is
                // the one feature that acts on somebody's behalf, and how
                // much of it is running should be readable without opening
                // anything. What it is *configured* to do is in Settings;
                // this is only whether it is running and what is waiting.
                Section {
                    SettingsRow("Auto-Reply",
                                value: autoReplyValue, badge: autoReplyQueue.waiting.count) {
                        AutoReplyView()
                    }
                } header: {
                    Text("Auto-Reply")
                } footer: {
                    Text(autoReplyFooter)
                }

                appearanceSection

                Section {
                    SettingsRow("Settings") { AppSettingsView() }
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $isAddingMailbox) { AddMailboxFlow() }
            .alert(item: $signingOut) { account in
                Alert(
                    title: Text("Sign out of \(account.address)?"),
                    message: Text("Its mail, read state, snoozes and drafts go from this phone, and Maily's access to it ends. Nothing on \(account.provider.inSentence) is touched."),
                    primaryButton: .destructive(Text("Sign out")) {
                        // Never the active one -- this list only holds the
                        // others -- so `forget` is always the right call and
                        // `disconnect` never is.
                        mail.registry.forget(account.id)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: - Header

    /// Picture on the left, three lines beside it.
    ///
    /// Centring it made a poster of the top of a settings screen. Read down
    /// the left edge like every row under it, a person is a row too -- and
    /// the three lines can then be a hierarchy rather than a stack of
    /// centred captions.
    private var header: some View {
        HStack(spacing: 14) {
            ProfileAvatar(
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
            if mail.account == nil {
                Label("No mailbox connected", systemImage: "envelope.badge.shield.half.filled")
                    .font(Style.rowTitle)
                    .foregroundStyle(.secondary)
            }
            // No "Current" row: this section is the mailboxes you can move
            // *to*, not a list of every mailbox with one of them ticked.
            //
            // A row you cannot tap, sitting among rows that exist to be
            // tapped, has to explain itself -- and it was doing that with a
            // blue "Current" label, which is a caption apologising for a
            // control. Which mailbox is active is said by the avatar in the
            // inbox toolbar and by the card at the top of Manage accounts.
            //
            // (The header above is the *Maily* account -- the Apple identity
            // everything is saved under. That is a different thing from the
            // mailbox, which is why removing this row loses nothing that was
            // already on screen.)
            otherMailboxes

            // Two rows, and finally two destinations. They pushed the same
            // page as each other for months, which is why adding an account
            // appeared to do nothing.
            Button {
                isAddingMailbox = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.blue))
                    Text("Add account")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            NavigationLink { MailboxListView() } label: {
                Text("Manage accounts")
                    .font(.subheadline)
            }
        } header: {
            Text("Accounts")
        }
    }

    /// The mailboxes that are not in front of you, one per row.
    ///
    /// They were a horizontal strip of faces, which is a shape for *many* of
    /// something you scan -- a story tray, a reaction bar. Two or three
    /// mailboxes is not that. It also had nowhere to put an address, so two
    /// accounts at the same company showed as two identical names, and the
    /// only thing you could do to one was tap it.
    ///
    /// Rows, like Telegram's account list. There is room for the address, and
    /// room for a swipe.
    @ViewBuilder
    private var otherMailboxes: some View {
        ForEach(mail.registry.accounts.filter { $0.id != mail.account?.id }) { account in
            Button {
                Task { await mail.activate(account) }
            } label: {
                HStack(spacing: 12) {
                    SenderAvatar(contact: account.contact, size: 38)
                        .overlay { Circle().strokeBorder(account.tint.color, lineWidth: 2) }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                            .font(Style.rowTitle)
                            .foregroundStyle(.primary)
                        Text(account.address)
                            .font(Style.rowDetail)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)

                    if account.needsAttention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.warning)
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { signingOut = account } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
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

/// One row: a word, and what it is set to.
///
/// No icon. A glyph beside every row is a column of decoration down the left
/// edge that has to be read past to get to the word, and twenty of them in
/// two screens never cohered into a set -- they were twenty pictures of
/// twenty different things at twenty different weights. iOS itself only puts
/// icons where they group (Wi-Fi, Bluetooth, Cellular); a settings list of
/// unrelated single words reads faster without them.
///
/// The value on the right is the point. "Appearance — System" tells somebody
/// what they came to find out without opening anything, where a sentence
/// underneath the label only tells them what the label already said.
struct SettingsRow<Destination: View>: View {
    let title: String
    var value: String?
    var badge: Int = 0
    @ViewBuilder let destination: Destination

    init(
        _ title: String,
        value: String? = nil,
        badge: Int = 0,
        @ViewBuilder destination: () -> Destination
    ) {
        self.title = title
        self.value = value
        self.badge = badge
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
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
            .padding(.vertical, 2)
        }
    }
}

#Preview {
    YouView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
        .environment(AutoReplyStore(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply.json")))
        .environment(AutoReplyQueue(fileURL: FileManager.default.temporaryDirectory.appending(path: "preview-autoreply-queue.json")))
}
