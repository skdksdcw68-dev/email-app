import SwiftUI
import UIKit

/// One person: what the relationship looks like, and what is outstanding.
///
/// Everything except the written summary is computed locally from mail already
/// held, so opening somebody costs nothing. The summary is one model call,
/// made only when asked for, and it is told to work from the messages it is
/// given rather than to characterise anybody.
struct PersonDetailView: View {
    let address: Person.ID

    @Environment(MailStore.self) private var mail

    @State private var summary: String?
    @State private var isSummarising = false
    @State private var summaryError: String?
    @State private var isComposing = false
    // Mirrored so the controls react instantly; the store of record is
    // PersonPreferences, which the whole priority engine reads.
    @State private var isImportant = false
    @State private var isMuted = false
    @State private var customRelationship = ""

    private var person: Person? { mail.people.first { $0.id == address } }

    private var conversations: [Message] {
        mail.messages
            .filter {
                $0.sender.address.lowercased() == address
                    || $0.recipients.contains { $0.address.lowercased() == address }
            }
            .sorted { $0.date > $1.date }
            .collapsingThreads()
    }

    private var followUps: [FollowUp] {
        mail.followUps.filter {
            $0.message.sender.address.lowercased() == address
                || $0.message.recipients.contains { $0.address.lowercased() == address }
        }
    }

    var body: some View {
        Group {
            if let person {
                content(person)
            } else {
                ContentUnavailableView("Nobody Here", systemImage: "person.slash")
            }
        }
        .navigationTitle(person?.contact.name ?? "Person")
        .navigationBarTitleDisplayMode(.inline)
        // The People root hides the bar to draw its own header; this page
        // wants the system's back.
        .toolbar(.visible, for: .navigationBar)
        // A pushed page is a full-screen context. Leaving the tab bar under
        // it stacks two navigation systems over one screen.
        .hidesTabBar()
        .onAppear {
            isImportant = PersonPreferences.isImportant(address)
            isMuted = PersonPreferences.isMuted(address)
            customRelationship = PersonPreferences.relationshipName(for: address) ?? ""
        }
        .sheet(isPresented: $isComposing) {
            // Replies to their newest incoming message when there is one, so
            // the thread stays intact; a fresh compose otherwise.
            ComposeView(replyingTo: conversations.first { $0.mailbox == .inbox })
        }
    }

    private func content(_ person: Person) -> some View {
        List {
            Section {
                header(person)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            }

            if !followUps.isEmpty {
                Section {
                    ForEach(followUps) { followUp in
                        NavigationLink(value: followUp.message.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(followUp.direction == .waitingOnYou
                                     ? "Waiting on you"
                                     : "No reply since \(followUp.ageDescription)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(followUp.isOverdue ? Color.orange : Color.primary)
                                Text(followUp.message.subject)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Text("Outstanding")
                }
            }

            Section("Summary") { summarySection(person) }

            Section {
                Toggle(isOn: $isImportant) {
                    Label("Important", systemImage: "star.fill")
                }
                .onChange(of: isImportant) { _, value in
                    PersonPreferences.setImportant(value, for: address)
                    if value { isMuted = false }
                    mail.notePreferencesChanged()
                }

                Toggle(isOn: $isMuted) {
                    Label("Mute", systemImage: "bell.slash.fill")
                }
                .onChange(of: isMuted) { _, value in
                    PersonPreferences.setMuted(value, for: address)
                    if value { isImportant = false }
                    mail.notePreferencesChanged()
                }

                Picker(selection: categoryBinding) {
                    ForEach(PersonCategory.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                } label: {
                    Label("Relationship", systemImage: "person.text.rectangle")
                }

                // The user's own word for it, when none of the categories is
                // it. Saved as typed; shown everywhere in place of the
                // category and offered as its own filter on the People page.
                HStack(spacing: 12) {
                    Label("Call them", systemImage: "tag")
                    TextField("Freelancer, landlord, coach", text: $customRelationship)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onChange(of: customRelationship) { _, value in
                            PersonPreferences.setRelationshipName(value, for: address)
                            mail.notePreferencesChanged()
                        }
                }
            } footer: {
                Text("Important mail scores higher; muted mail never reads as urgent. Your choice always beats what Maily worked out, and a name you type beats the relationship.")
            }

            if !conversations.isEmpty {
                Section("Conversations") {
                    ForEach(conversations.prefix(20)) { message in
                        NavigationLink(value: message.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.subject)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(message.listDate)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Centred, and balanced: the three numbers get a third of the width
    /// each, so a long word under one of them never shoves the others.
    private func header(_ person: Person) -> some View {
        VStack(spacing: 14) {
            SenderAvatar(contact: person.contact, size: 96)

            VStack(spacing: 4) {
                Text(person.contact.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(person.contact.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Label(person.relationshipTitle, systemImage: person.relationshipSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(person.relationshipColor)
                if let organization = person.organization {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(organization)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                stat("\(person.conversationCount)", person.conversationCount == 1 ? "conversation" : "conversations")
                stat("\(person.messageCount)", person.messageCount == 1 ? "message" : "messages")
                stat(person.lastContactedDescription, "last heard")
            }
            .padding(.top, 4)

            if let initiator = person.initiator {
                Text(initiator)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                isComposing = true
            } label: {
                Label("Write to \(firstName(of: person))", systemImage: "square.and.pencil")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Capsule().fill(Color.accentColor))
            }
            .buttonStyle(PressButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    /// "Write to Sara" rather than "Write to Sara Bekele". Falls back to the
    /// whole name when there is no space to split on.
    private func firstName(of person: Person) -> String {
        let parts = person.contact.name.split(separator: " ")
        guard let first = parts.first, !first.contains("@") else {
            return person.contact.name
        }
        return String(first)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func summarySection(_ person: Person) -> some View {
        if let summary {
            // Selectable a sentence at a time, like every other piece of
            // text the assistant writes.
            SelectableText(summary, font: .preferredFont(forTextStyle: .subheadline))
        } else if isSummarising {
            VStack(alignment: .leading, spacing: 8) {
                SkeletonLine()
                SkeletonLine(width: 220)
            }
        } else if let summaryError {
            Label(summaryError, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        } else {
            // Not generated on open. Costing a model call every time a person
            // is tapped would make browsing the tab expensive for no reason.
            Button {
                Task { await summarise(person) }
            } label: {
                Label("Summarise this relationship", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var categoryBinding: Binding<PersonCategory> {
        Binding(
            get: { person?.category ?? .external },
            set: {
                PersonPreferences.setCategory($0, for: address)
                mail.notePreferencesChanged()
            }
        )
    }

    private func summarise(_ person: Person) async {
        isSummarising = true
        summaryError = nil
        defer { isSummarising = false }

        let context = Array(conversations.prefix(12))
        let question = """
        Summarise my relationship with \(person.contact.name) in two or three \
        sentences: what we have been discussing and what is outstanding. Do not \
        characterise them as a person.
        """

        do {
            summary = try await AIService.ask(question: question, context: context).answer
        } catch {
            summaryError = error.localizedDescription
        }
    }
}
