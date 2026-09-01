import SwiftUI
import UIKit

/// The People tab: who matters, rather than what arrived.
///
/// Anyone waiting on a reply sorts to the top -- the point of this tab is
/// noticing a person you have left hanging, which a chronological mailbox
/// hides completely. Services are filtered out by default: forty noreply
/// addresses are not relationships.
///
/// The header is drawn here rather than by the navigation bar, because the
/// navigation bar cannot do what this page needs: the title flush left on
/// the same line as the search and menu capsule, the filter chips pinned
/// underneath at all times, and on scroll the title sliding to the centre
/// while the capsule fades -- the way the App Store's tabs behave.
struct PeopleView: View {
    @Environment(MailStore.self) private var mail

    @State private var filter: PeopleFilter?
    @State private var showsServices = false
    @State private var isSearching = false
    @State private var query = ""
    @State private var scrolledAway = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Assembling people walks every message. Once per render.
        let everyone = mail.people
        let visible = everyone.filter { showsServices || $0.category.isPerson }
        let people = visible.filter { filter?.matches($0) ?? true }
        let important = people.filter { $0.isImportant }
        let waiting = people.filter { !$0.isImportant && $0.awaitingReply > 0 }
        let everyoneElse = people.filter { !$0.isImportant && $0.awaitingReply == 0 }
        let filters = PeopleFilter.available(in: visible)
        // By name, address or company, across everyone -- services included,
        // because a search is somebody looking for something specific.
        let searchResults = query.isEmpty ? [] : everyone.filter {
            $0.contact.name.localizedCaseInsensitiveContains(query)
                || $0.contact.address.localizedCaseInsensitiveContains(query)
                || ($0.organization ?? "").localizedCaseInsensitiveContains(query)
        }

        return NavigationStack {
            List {
                if isSearching {
                    Section {
                        ForEach(searchResults) { row($0) }
                    }
                } else {
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
            // The first section starts just under the chips. The list's own
            // top margin, plus a zero-height section that used to track the
            // scroll, was most of the gap that sat there before.
            .contentMargins(.top, 6, for: .scrollContent)
            .modifier(ScrollAwayTracking(isAway: $scrolledAway))
            .keyboardDismissable()
            .safeAreaInset(edge: .top, spacing: 0) {
                header(filters: filters)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("People")
            .navigationDestination(for: Person.ID.self) { PersonDetailView(address: $0) }
            .navigationDestination(for: Message.ID.self) { MessageDetailView(messageID: $0) }
            .overlay {
                if isSearching && !query.isEmpty && searchResults.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if isSearching && query.isEmpty {
                    ContentUnavailableView(
                        "Search people",
                        systemImage: "magnifyingglass",
                        description: Text("By name, email address or company.")
                    )
                } else if !isSearching && people.isEmpty {
                    emptyState
                }
            }
        }
    }

    // MARK: - Header

    /// Title row plus chips. The title row is 44pt in every state so the
    /// list underneath never shifts: at rest the title is large and left
    /// with the capsule on the right; scrolled, the title is small and
    /// centred and the capsule is gone; searching, the row is the field.
    private func header(filters: [PeopleFilter]) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Text("People")
                    .font(.headline)
                    .opacity(scrolledAway && !isSearching ? 1 : 0)

                if isSearching {
                    searchRow
                        .transition(.opacity)
                } else {
                    HStack(alignment: .center) {
                        Text("People")
                            .font(.largeTitle.weight(.bold))
                            .opacity(scrolledAway ? 0 : 1)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 0)
                        actions
                            .opacity(scrolledAway ? 0 : 1)
                            .allowsHitTesting(!scrolledAway)
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 44)
            .padding(.horizontal, 20)

            if !isSearching {
                chips(filters)
                    .transition(.opacity)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Color(uiColor: .systemGroupedBackground))
        .animation(.easeOut(duration: 0.18), value: scrolledAway)
        .animation(.snappy(duration: 0.22), value: isSearching)
    }

    /// Search and the menu in one capsule, on the same glass the system
    /// uses for its bar buttons.
    private var actions: some View {
        HStack(spacing: 0) {
            Button {
                isSearching = true
                searchFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")

            Menu {
                Toggle("Show services", isOn: $showsServices)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 48, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
        }
        .foregroundStyle(.primary)
        .barGlass(in: Capsule())
    }

    private var searchRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search people", text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))

            Button("Cancel") {
                query = ""
                searchFocused = false
                isSearching = false
            }
            .font(.body)
        }
    }

    private func chips(_ filters: [PeopleFilter]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(nil, title: "All", symbol: "person.2.fill", color: .secondary)
                ForEach(filters, id: \.self) { option in
                    chip(option, title: option.title, symbol: option.symbol, color: option.color)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ option: PeopleFilter?, title: String, symbol: String, color: Color) -> some View {
        let isSelected = filter == option
        return Button {
            withAnimation(.snappy(duration: 0.2)) { filter = isSelected ? nil : option }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : color)
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
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Rows

    private func row(_ person: Person) -> some View {
        NavigationLink(value: person.id) { PersonRow(person: person) }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            filter == nil ? "No People Yet" : "Nobody here",
            systemImage: filter?.symbol ?? "person.2",
            description: Text(
                filter == nil
                    ? "Once your inbox syncs, the people you email appear here."
                    : "Nobody is tagged \(filter?.title ?? "") yet."
            )
        )
    }
}

/// Flips `isAway` once the list has scrolled a little past where it rests.
///
/// iOS 18's scroll geometry is exact and costs nothing, and it needs no
/// sentinel row in the list -- the zero-height section that used to do this
/// job brought a whole section's worth of spacing with it. Earlier systems
/// keep the expanded header; only the collapse is lost.
private struct ScrollAwayTracking: ViewModifier {
    @Binding var isAway: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 24
            } action: { _, away in
                withAnimation(.easeOut(duration: 0.18)) { isAway = away }
            }
        } else {
            content
        }
    }
}

/// A chip on the People page: one of the categories, or a relationship the
/// user named themselves.
enum PeopleFilter: Hashable {
    case category(PersonCategory)
    case custom(String)

    var title: String {
        switch self {
        case .category(let category): category.title
        case .custom(let name):       name
        }
    }

    var symbol: String {
        switch self {
        case .category(let category): category.systemImage
        case .custom:                 "tag.fill"
        }
    }

    var color: Color {
        switch self {
        case .category(let category): category.color
        case .custom:                 Color.accentColor
        }
    }

    func matches(_ person: Person) -> Bool {
        switch self {
        case .category(let category): person.customRelationship == nil && person.category == category
        case .custom(let name):       person.customRelationship == name
        }
    }

    /// Only chips that have somebody behind them: the categories present,
    /// then every custom name in use.
    static func available(in people: [Person]) -> [PeopleFilter] {
        let categories = Set(people.filter { $0.customRelationship == nil }.map(\.category))
        let customs = Set(people.compactMap(\.customRelationship))
        return PersonCategory.allCases.filter(categories.contains).map(PeopleFilter.category)
            + customs.sorted().map(PeopleFilter.custom)
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
                    relationshipBadge
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

    /// The relationship, on the row, in the same capsule the mail tags use.
    /// Marking somebody a client and then seeing nothing change in the list
    /// was the whole complaint.
    private var relationshipBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: person.relationshipSymbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(person.relationshipColor)
            Text(person.relationshipTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }
}

#Preview {
    PeopleView()
        .environment(MailStore.connected())
        .environment(UserStore(defaults: .previews, startAt: .finished))
}
