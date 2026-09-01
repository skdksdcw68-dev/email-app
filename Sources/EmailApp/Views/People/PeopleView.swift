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

    @State private var category: PersonCategory?
    @State private var showsServices = false
    @State private var isSearching = false
    @State private var query = ""

    var body: some View {
        // Assembling people walks every message. Once per render -- the
        // earlier version did it five times, once per derived list.
        let everyone = mail.people
        let visible = everyone.filter { showsServices || $0.category.isPerson }
        let people = visible.filter { category == nil || $0.category == category }
        let important = people.filter { $0.isImportant }
        let waiting = people.filter { !$0.isImportant && $0.awaitingReply > 0 }
        let everyoneElse = people.filter { !$0.isImportant && $0.awaitingReply == 0 }
        // Only offer a filter for categories that actually have somebody.
        let present = Set(visible.map(\.category))
        let availableCategories = PersonCategory.allCases.filter(present.contains)
        // By name, address or company, across everyone -- services included,
        // because a search is somebody looking for something specific.
        let searchResults = query.isEmpty ? [] : everyone.filter {
            $0.contact.name.localizedCaseInsensitiveContains(query)
                || $0.contact.address.localizedCaseInsensitiveContains(query)
                || ($0.organization ?? "").localizedCaseInsensitiveContains(query)
        }

        return NavigationStack {
            List {
                if !query.isEmpty {
                    Section {
                        ForEach(searchResults) { row($0) }
                    }
                } else {
                    if availableCategories.count > 1 {
                        Section {
                            categoryBar(availableCategories)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
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
            }
            .modifier(SearchWhenAsked(query: $query, isPresented: $isSearching, prompt: "Search people"))
            .keyboardDismissable()
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The title on the buttons' line and flush left, the way the
                // App Store's Search page sets its title beside the avatar.
                // A principal item stretched to the available width puts the
                // large text where an inline title would be centred.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 0) {
                        Text("People")
                            .font(.system(size: 28, weight: .bold))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search")

                    Menu {
                        Toggle("Show services", isOn: $showsServices)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More options")
                }
            }
            .navigationDestination(for: Person.ID.self) { PersonDetailView(address: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
            .overlay {
                if !query.isEmpty && searchResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if query.isEmpty && people.isEmpty {
                    emptyState
                }
            }
        }
    }

    private func row(_ person: Person) -> some View {
        NavigationLink(value: person.id) { PersonRow(person: person) }
    }

    private func categoryBar(_ availableCategories: [PersonCategory]) -> some View {
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
            category == nil ? "No People Yet" : "Nobody here",
            systemImage: category?.systemImage ?? "person.2",
            description: Text(
                category == nil
                    ? "Once your inbox syncs, the people you email appear here."
                    : "No \(category?.title.lowercased() ?? "") contacts yet."
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
