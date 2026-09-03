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
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var occupation = ""

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
                } footer: {
                    Text("Your email comes from the account you signed in with and cannot be changed here.")
                }
            }
            .keyboardDismissable()
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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
        }
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
