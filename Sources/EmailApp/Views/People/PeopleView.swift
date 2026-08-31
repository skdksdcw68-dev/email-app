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

    private var people: [Person] {
        mail.people
            .filter { showsServices || $0.category.isPerson }
            .filter { category == nil || $0.category == category }
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if availableCategories.count > 1 { categoryBar }
            }
            .keyboardDismissable()
            .navigationTitle("People")
            .toolbar {
                // Search and the menu together in the corner, so the list
                // starts at the top of the screen instead of under a bar.
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isSearching = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }

                    Menu {
                        Toggle("Show services", isOn: $showsServices)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $isSearching) {
                PeopleSearchView()
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
        .background(Color(uiColor: .systemGroupedBackground))
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

/// Searching people, in a sheet rather than a bar pinned above the list.
///
/// A permanent search field cost a whole row of the screen to something used
/// occasionally, and pushed the filter chips and the first person down with
/// it. In the corner it costs a button.
struct PeopleSearchView: View {
    @Environment(MailStore.self) private var mail
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var results: [Person] {
        guard !text.isEmpty else { return [] }
        return mail.people.filter {
            $0.contact.name.localizedCaseInsensitiveContains(text)
                || $0.contact.address.localizedCaseInsensitiveContains(text)
                || ($0.organization ?? "").localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { person in
                    NavigationLink(value: person.id) { PersonRow(person: person) }
                }
            }
            .listStyle(.plain)
            .keyboardDismissable()
            .searchable(text: $text, isPresented: .constant(true), prompt: "Search people")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Person.ID.self) { PersonDetailView(address: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if text.isEmpty {
                    ContentUnavailableView(
                        "Search people",
                        systemImage: "magnifyingglass",
                        description: Text("By name, email address or company.")
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: text)
                }
            }
        }
    }
}
