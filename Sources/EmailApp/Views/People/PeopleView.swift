import SwiftUI
import UIKit

/// The People tab: who matters, rather than what arrived.
///
/// Anyone waiting on a reply sorts to the top -- the point of this tab is
/// noticing a person you have left hanging, which a chronological mailbox
/// hides completely. Services are filtered out by default: forty noreply
/// addresses are not relationships.
struct PeopleView: View {
    @Environment(MailStore.self) private var mail

    @State private var query = ""
    @State private var category: PersonCategory?
    @State private var showsServices = false

    private var people: [Person] {
        mail.people
            .filter { showsServices || $0.category.isPerson }
            .filter { category == nil || $0.category == category }
            .filter {
                query.isEmpty
                    || $0.contact.name.localizedCaseInsensitiveContains(query)
                    || $0.contact.address.localizedCaseInsensitiveContains(query)
                    || ($0.organization ?? "").localizedCaseInsensitiveContains(query)
            }
    }

    private var important: [Person] { people.filter { $0.isImportant } }
    private var waiting: [Person] { people.filter { !$0.isImportant && $0.awaitingReply > 0 } }
    private var everyoneElse: [Person] { people.filter { !$0.isImportant && $0.awaitingReply == 0 } }

    /// Only offer a filter for categories that actually have somebody in them.
    private var availableCategories: [PersonCategory] {
        let present = Set(mail.people.filter { showsServices || $0.category.isPerson }.map(\.category))
        return PersonCategory.allCases.filter(present.contains)
    }

    var body: some View {
        NavigationStack {
            List {
                if availableCategories.count > 1 {
                    categoryBar
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !important.isEmpty {
                    Section {
                        ForEach(important) { row($0) }
                    } header: {
                        Text("Important")
                    } footer: {
                        Text("Mail from these people carries more weight when Maily judges priority.")
                    }
                }

                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { row($0) }
                    } header: {
                        Text("Waiting on you")
                    } footer: {
                        Text("These people sent something that still needs a reply.")
                    }
                }

                if !everyoneElse.isEmpty {
                    Section("Everyone else") {
                        ForEach(everyoneElse) { row($0) }
                    }
                }
            }
            .navigationTitle("People")
            .searchable(text: $query, prompt: "Search people")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show services", isOn: $showsServices)
                    } label: {
                        Label("Options", systemImage: "ellipsis")
                    }
                }
            }
            .navigationDestination(for: Person.ID.self) { PersonDetailView(address: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
            .overlay {
                if people.isEmpty { emptyState }
            }
        }
    }

    private func row(_ person: Person) -> some View {
        NavigationLink(value: person.id) { PersonRow(person: person) }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                categoryChip(nil, title: "All", symbol: "person.2.fill")
                ForEach(availableCategories) { option in
                    categoryChip(option, title: option.title, symbol: option.systemImage)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
    }

    private func categoryChip(_ option: PersonCategory?, title: String, symbol: String) -> some View {
        let isSelected = category == option
        return Button {
            withAnimation(.snappy(duration: 0.2)) { category = isSelected ? nil : option }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : (option?.color ?? .secondary))
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(option?.color ?? Color.accentColor)
                        : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
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

struct PersonRow: View {
    let person: Person

    var body: some View {
        HStack(spacing: 12) {
            SenderAvatar(contact: person.contact, size: 44, isMuted: person.isMuted)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(person.contact.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if person.isImportant {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if person.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(person.organization ?? person.contact.address)
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
        .opacity(person.isMuted ? 0.6 : 1)
    }
}

#Preview {
    PeopleView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
