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
    // Mirrored so the toggles react instantly; the store of record is
    // PersonPreferences, which the whole priority engine reads.
    @State private var isImportant = false
    @State private var isMuted = false

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
        .onAppear {
            isImportant = PersonPreferences.isImportant(address)
            isMuted = PersonPreferences.isMuted(address)
        }
        .sheet(isPresented: $isComposing) {
            // Replies to their newest incoming message when there is one, so
            // the thread stays intact; a fresh compose otherwise.
            ComposeView(replyingTo: conversations.first { $0.mailbox == .inbox })
        }
    }

    private func content(_ person: Person) -> some View {
        List {
            Section { header(person) }

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
                }

                Toggle(isOn: $isMuted) {
                    Label("Mute", systemImage: "bell.slash.fill")
                }
                .onChange(of: isMuted) { _, value in
                    PersonPreferences.setMuted(value, for: address)
                    if value { isImportant = false }
                }

                Picker(selection: categoryBinding) {
                    ForEach(PersonCategory.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                } label: {
                    Label("Relationship", systemImage: "person.text.rectangle")
                }
            } footer: {
                Text("Important mail scores higher; muted mail never reads as urgent. Your choice always beats what Maily worked out.")
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

    private func header(_ person: Person) -> some View {
        VStack(spacing: 12) {
            SenderAvatar(contact: person.contact, size: 68)

            VStack(spacing: 3) {
                Text(person.contact.name)
                    .font(.title3.weight(.bold))
                Text(person.contact.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Label(person.category.title, systemImage: person.category.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(person.category.color)
                if let organization = person.organization {
                    Text("· \(organization)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 18) {
                stat("\(person.conversationCount)", "conversations")
                stat("\(person.messageCount)", "messages")
                stat(person.lastContactedDescription, "last")
            }
            .padding(.top, 2)

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
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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
        VStack(spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summarySection(_ person: Person) -> some View {
        if let summary {
            Text(summary)
                .font(.subheadline)
                .textSelection(.enabled)
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
            set: { PersonPreferences.setCategory($0, for: address) }
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
