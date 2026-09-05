import PhotosUI
import SwiftUI
import UIKit

/// Who you are, as far as Maily is concerned.
///
/// Two fields, and only two, because only two of them change anything. The
/// name is what replies go out under. What you do is the single most useful
/// sentence about somebody when the assistant is deciding what matters in
/// their inbox and how to write for them -- one line, where Auto-Reply asks
/// eleven questions.
///
/// Everything below them is shown rather than offered: the email is whoever
/// signed in, and pretending it is editable would be a field that fails.
struct EditProfileView: View {
    @Environment(UserStore.self) private var user
    @Environment(MailStore.self) private var mail
    @Environment(AIMemory.self) private var memory
    @Environment(ChatHistory.self) private var chats
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var occupation = ""
    @State private var picked: PhotosPickerItem?
    @State private var isSigningOut = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // A page now, pushed from You, rather than a sheet with a drawn ✕ in the
    // corner. Two reasons, and the second is the real one: it is where the
    // picture is chosen and where the whole account is signed out of, and
    // neither is a thing that should vanish because a finger moved. A sheet
    // also cannot show a back chevron, so the way out had to be hand-drawn.
    var body: some View {
        List {
            Section {
                picture
            }

            Section {
                TextField("Your name", text: $name)
                    .textContentType(.name)
            } header: {
                Text("Name")
            } footer: {
                Text("How Maily addresses you, and the name your replies go out under.")
            }

            Section {
                TextField("Freelance iOS developer", text: $occupation, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("What you do")
            } footer: {
                Text("One line, in your own words. Maily uses it to judge what matters in your inbox and how to sound when it writes for you. Leave it blank and it simply won't be used.")
            }

            Section {
                LabeledContent("Email", value: user.account?.email ?? "Not signed in")
                if let provider = user.account?.provider {
                    LabeledContent("Signed in with", value: provider.title)
                }
                if let joined = user.account?.createdAt {
                    LabeledContent("With Maily since",
                                   value: joined.formatted(.dateTime.month(.wide).year()))
                }
            } header: {
                Text("Your Maily account")
            } footer: {
                Text("Your email comes from the account you signed in with and cannot be changed here.")
            }

            mailboxes
            signOut
        }
        .keyboardDismissable()
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    user.setDisplayName(name)
                    user.setOccupation(occupation)
                    // Straight up, not on the four-second debounce. Somebody
                    // who presses Save and closes the app a second later has
                    // every right to expect it saved -- and the debounce is
                    // there for a burst of stars in the People tab, not for a
                    // button somebody deliberately pressed once.
                    Task { await SettingsSync.shared.pushNow(.profile) }
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            name = user.account?.displayName ?? ""
            occupation = user.account?.occupation ?? ""
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await adopt(item) }
        }
        .alert("Sign out of Maily?", isPresented: $isSigningOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) { signOutCompletely() }
        } message: {
            Text("Signs you out of Maily and removes every mailbox, the offline copy of your mail, and your saved preferences from this phone. Nothing at Google or your mail provider is touched.")
        }
    }

    // MARK: - Picture

    private var picture: some View {
        HStack(spacing: 16) {
            ProfileAvatar(
                contact: Contact(
                    name: user.account?.displayName ?? "You",
                    address: user.account?.email ?? ""
                ),
                size: 64,
                photoURL: user.account?.photoURL,
                photoKey: user.account.map { "app-\($0.id.uuidString)" }
            )

            VStack(alignment: .leading, spacing: 6) {
                // `PhotosPicker` reads one chosen image through the system's
                // own picker process, so it needs no photo-library permission
                // and never sees the rest of the library.
                PhotosPicker(selection: $picked, matching: .images) {
                    Text(ProfilePhoto.image == nil ? "Add a photo" : "Change photo")
                        .font(Style.rowTitle)
                }

                if ProfilePhoto.image != nil {
                    Button("Remove", role: .destructive) { ProfilePhoto.remove() }
                        .font(Style.rowDetail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func adopt(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return }
        ProfilePhoto.set(image)
        picked = nil
    }

    // MARK: - Mailboxes

    /// The mail this account reaches, and how each one is signed in.
    ///
    /// Shown here because "your Maily account" and "the mailboxes on it" are
    /// two different things that people reasonably confuse -- and the sign-out
    /// below removes all of them, which is easier to mean when they are listed
    /// directly above it.
    @ViewBuilder
    private var mailboxes: some View {
        if !mail.registry.accounts.isEmpty {
            Section {
                ForEach(mail.registry.accounts) { account in
                    HStack(spacing: 12) {
                        MailboxAvatar(account: account, size: 32)
                            .overlay { Circle().strokeBorder(account.tint.color, lineWidth: 1.5) }

                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.address)
                                .font(Style.rowTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Signed in with \(account.provider.title) · since \(account.connectedAt.formatted(.dateTime.month(.abbreviated).year()))")
                                .font(Style.rowDetail)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Your email in Maily")
            }
        }
    }

    // MARK: - Signing out

    /// The account-level sign-out, and the only one.
    ///
    /// Settings has a "Log out" too, and the two used to do quietly different
    /// things under the same word -- that one cleared three keys and never
    /// even called `AuthService.signOut()`. It now signs out of the current
    /// *mailbox*. This is the one that ends the Maily account, and it says so.
    private var signOut: some View {
        Section {
            Button(role: .destructive) {
                isSigningOut = true
            } label: {
                Text("Sign out of Maily")
                    .font(Style.rowTitle)
                    .foregroundStyle(Color.urgent)
            }
        } footer: {
            Text("Everything on this phone. Your mail itself stays where it is.")
        }
    }

    private func signOutCompletely() {
        mail.disconnect()
        PersonPreferences.clearAll()
        FollowUpPreferences.clearAll()
        // Memory is about the person rather than the mailbox, so disconnecting
        // an inbox keeps it. Signing out of the account does not.
        memory.forgetAll()
        chats.clearAll()
        ProfilePhoto.clearAll()
        // Both kinds of face: the one they chose, above, and every one a
        // provider supplied. All of them, because `disconnect()` only takes
        // the active mailbox and a picture whose account has already been
        // deleted is the one nothing would think to remove.
        AvatarStore.shared.forgetAll()
        // And the contact list those faces were matched against. It is
        // somebody's address book; it does not outlive their account.
        PeopleDirectory.shared.forgetAll()
        // The domain-to-logo map too. It holds no addresses -- only which
        // companies write to this phone -- but that is still a list about
        // somebody, and signing out means leaving nothing behind.
        LogoDirectory.shared.forgetAll()
        user.signOut()
        Task { await AuthService.signOut() }
    }
}

// The accounts screens moved to Views/Accounts: MailboxListView for the
// list, MailboxDetailView for one of them. This page could only ever show a
// single mailbox, and its "Add another account" button was disabled with a
// footer saying so.

// Appearance had a page here once. It is a segmented control on You now --
// three options are not a destination, and a tap to see two of them is a tap
// spent finding out what the choices are.

/// Writing style on its own, as the plan has it.
///
/// Held in `@State` and written on Save, rather than saved on every keystroke.
/// The old version wrote `AppSettings.customInstructions` on **every character
/// typed**, which means there was never a draft: half a sentence somebody was
/// still thinking about was already the instruction the model would be given,
/// and there was no way to change your mind except to delete it again.
struct WritingStyleView: View {
    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var tone: WritingTone = .matchMe
    @State private var instructions = ""
    @State private var isDiscarding = false
    @FocusState private var isTyping: Bool

    private var hasChanges: Bool {
        tone != user.chosenTone || instructions != AppSettings.customInstructions
    }

    var body: some View {
        List {
            Section {
                ForEach(WritingTone.allCases) { option in
                    Button {
                        tone = option
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(Style.rowTitle)
                                    .foregroundStyle(.primary)
                                Text(option.detail)
                                    .font(Style.rowDetail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            if tone == option {
                                Image(systemName: "checkmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.tint)
                                    .padding(.top, 2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            } header: {
                Text("Tone")
            } footer: {
                Text("How Maily sounds when it writes on your behalf.")
            }

            Section {
                TextField(
                    "Keep my emails short. Never use exclamation marks. Sign off with just my first name.",
                    text: $instructions,
                    axis: .vertical
                )
                .lineLimit(4...10)
                .focused($isTyping)
            } header: {
                Text("Custom instructions")
            } footer: {
                Text("Anything you want Maily to remember whenever it writes for you. Written in your own words — it is passed to the model as you type it.")
            }
        }
        .navigationTitle("Writing")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        // 🔴 `keyboardDismissable()` does not work on a `List`. It puts the tap
        // gesture on a *background*, which sits behind the rows and never gets
        // the tap -- so on this screen the keyboard covered the box somebody
        // was typing into with no way to get rid of it.
        //
        // A Done button above the keyboard is the answer iOS already has, and
        // it works regardless of what is underneath.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isTyping = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!hasChanges)
            }
        }
        .onAppear {
            tone = user.chosenTone
            instructions = AppSettings.customInstructions
        }
        // Leaving with unsaved edits used to be impossible to do wrong,
        // because there was nothing to save. Now there is.
        .navigationBarBackButtonHidden(hasChanges)
        .toolbar {
            if hasChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { isDiscarding = true }
                }
            }
        }
        .alert("Save your changes?", isPresented: $isDiscarding) {
            Button("Save") { save(); dismiss() }
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private func save() {
        user.setTone(tone.rawValue)
        AppSettings.customInstructions = instructions
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
        .hidesTabBar()
    }
}

/// The plan.
///
/// 🔴 **The plan comes from the server, and from nowhere else.**
///
/// This page said "Free while Maily is in testing" and Settings said the
/// literal string "Free" in the row that opened it -- so a Max subscriber was
/// told twice that they were on the free plan while the paywall, three taps
/// away, correctly showed Max as current. Two screens disagreeing about
/// something somebody pays for is not a cosmetic bug.
///
/// It asks `my_spend()`, which is the same verdict a request is refused on.
/// StoreKit is deliberately *not* consulted here: a device's cache says yes
/// for days after a subscription lapses and says no on the phone somebody
/// restored to five minutes ago, and both of those are wrong in the direction
/// that costs somebody something.
struct PlanView: View {
    @State private var usage = UsageStore()
    @State private var isShowingPlans = false

    private var plan: Plan { usage.spend?.tier ?? .free }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan == .free ? "Free" : plan.title)
                        .font(.title3.weight(.bold))
                    Text(Self.blurb(for: plan))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let renews = usage.spend?.renews_at {
                        // The *billing* date, which is the subscription's own
                        // anniversary -- not the 1st, when the allowance comes
                        // back. Two different dates, on two different screens,
                        // each labelled for what it is.
                        Text("Renews \(renews.formatted(.dateTime.day().month(.abbreviated).year()))")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    if usage.spend?.is_in_grace == true {
                        Label("Your last payment did not go through.",
                              systemImage: "creditcard.trianglebadge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(Color.warning)
                    }
                }
                .padding(.vertical, 4)

                Button {
                    isShowingPlans = true
                } label: {
                    Text(plan == .free ? "See plans" : "Change plan")
                }
            } header: {
                Text("Current plan")
            } footer: {
                if let failure = usage.failure {
                    Text(failure)
                }
            }

            Section {
                Label("Bulk mail is sorted by rules on this phone, at no cost", systemImage: "bolt.slash")
                Label("Results are cached, so nothing is answered twice", systemImage: "arrow.clockwise")
                Label("Reading uses the cheap model; questions and drafts do not", systemImage: "creditcard")
            } header: {
                Text("What Maily does to keep it cheap")
            } footer: {
                Text("What you have used is on the Usage screen.")
            }
        }
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .refreshable { await usage.refresh() }
        .task { await usage.refresh() }
        .sheet(isPresented: $isShowingPlans) { PlansView() }
    }

    private static func blurb(for plan: Plan) -> String {
        switch plan {
        case .free:
            "One mailbox, and a small amount of AI each month. A plan raises both."
        case .pro:
            "Up to three mailboxes, with sorting, summaries and drafting."
        case .max:
            "Unlimited mailboxes, the faster model, and the largest monthly allowance."
        }
    }
}
