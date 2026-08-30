import SwiftUI
import UIKit

/// The People tab: relationships rather than individual emails.
///
/// Anyone waiting on a reply sorts to the top -- the point of this tab is
/// noticing a person you have left hanging, which a chronological mailbox
/// hides completely.
struct PeopleView: View {
    @Environment(MailStore.self) private var mail

    @State private var query = ""

    private var people: [Person] {
        let all = mail.people
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.contact.name.localizedCaseInsensitiveContains(query)
                || $0.contact.address.localizedCaseInsensitiveContains(query)
        }
    }

    private var waiting: [Person] { people.filter { $0.awaitingReply > 0 } }
    private var everyoneElse: [Person] { people.filter { $0.awaitingReply == 0 } }

    var body: some View {
        NavigationStack {
            List {
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { PersonRow(person: $0) }
                    } header: {
                        Text("Waiting on you")
                    } footer: {
                        Text("These people sent something that still needs a reply.")
                    }
                }

                if !everyoneElse.isEmpty {
                    Section("Recent") {
                        ForEach(everyoneElse) { PersonRow(person: $0) }
                    }
                }
            }
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Search people")
            .overlay {
                if people.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No People Yet" : "No Results",
                        systemImage: query.isEmpty ? "person.2" : "magnifyingglass",
                        description: Text(
                            query.isEmpty
                                ? "Once your inbox syncs, the people you email appear here."
                                : "Nobody matches \u{201C}\(query)\u{201D}."
                        )
                    )
                }
            }
        }
    }
}

private struct PersonRow: View {
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 44, height: 44)
                .overlay {
                    Text(person.contact.initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.contact.name)
                        .font(.headline)
                    if person.isPriority {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Text(person.contact.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Label("\(person.conversationCount)", systemImage: "bubble.left.and.bubble.right.fill")
                    Label(person.lastContactedDescription, systemImage: "clock")
                    if person.awaitingReply > 0 {
                        Label("\(person.awaitingReply) unanswered", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(Color(uiColor: .systemBlue))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    PeopleView().environment(MailStore.connected())
}
