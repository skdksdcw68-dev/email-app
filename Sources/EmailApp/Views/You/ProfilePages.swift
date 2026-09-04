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
                size: 64
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
                        SenderAvatar(contact: account.contact, size: 32)
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
        .keyboardDismissable()
        .navigationTitle("Writing style")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
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
        .hidesTabBar()
    }
}
