import SwiftUI

/// The categories of this mailbox, and everything a person can do to them:
/// reorder, hide, rename, recolour, add one of their own, delete it.
///
/// Reached from Settings and from a long press on the chip row. The ten
/// built in can be hidden but not deleted -- Auto-Reply and notifications
/// still read their tags -- and a custom one can be anything.
struct CategoriesView: View {
    @Environment(MailStore.self) private var mail

    private var store: CategoryStore { .shared }
    private var usage: UsageStore { .shared }

    @State private var editing: Category?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                ForEach(store.all) { category in
                    row(category)
                        .deleteDisabled(!category.isCustom)
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    // Ids first: removing while indexing the same list is
                    // how the wrong row goes.
                    let ids = offsets.map { store.all[$0].id }
                    for id in ids {
                        store.remove(id: id)
                        mail.removeCustomTag(id)
                    }
                }
            } header: {
                Text("Inbox")
            } footer: {
                Text("Drag to reorder. A hidden category is still sorted, just not shown. The ten built in can be hidden but not deleted.")
            }

            applySection
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .hidesTabBar()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isAdding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New category")
            }
        }
        .sheet(item: $editing) { CategoryEditorView(category: $0) }
        .sheet(isPresented: $isAdding) { CategoryEditorView(category: nil) }
    }

    private func row(_ category: Category) -> some View {
        HStack(spacing: 12) {
            Button { editing = category } label: {
                HStack(spacing: 12) {
                    Image(systemName: category.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(category.color.onColor)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(category.color.color))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name)
                            .font(Style.rowTitle)
                            .foregroundStyle(.primary)
                        if category.isCustom {
                            Text(category.guidance)
                                .font(Style.rowDetail)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Shown or not. A toggle rather than a swipe: hiding is the
            // common edit, and it should be one tap in plain sight.
            Toggle("Shown", isOn: Binding(
                get: { category.isVisible },
                set: { store.setVisible(category.id, $0) }
            ))
            .labelsHidden()
        }
    }

    // MARK: - Applying to older mail

    /// A new or reworded category reaches new mail and the newest hundred on
    /// its own. The rest of the mailbox is a choice, because it costs.
    @ViewBuilder
    private var applySection: some View {
        let waiting = mail.categoryRefreshCount()
        if waiting > 0 {
            Section {
                Button {
                    store.appliesToAllMail = true
                    Task { await mail.enhanceWithAI() }
                } label: {
                    LabeledContent {
                        Text(Self.share(of: waiting, allowance: usage.spend?.allowance))
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Apply to all \(waiting) emails").font(Style.rowTitle)
                    }
                }
                .disabled(store.appliesToAllMail)
            } footer: {
                Text("New mail and the newest 100 are sorted into a new category on their own. Older mail is sorted when you ask, and the cost comes out of this month's allowance.")
            }
        }
    }

    /// As a share of the month's allowance -- never as money, which is the
    /// operator's cost and not a price. See `AIUsageView`.
    private static func share(of count: Int, allowance: Double?) -> String {
        guard let allowance, allowance > 0 else { return "" }
        let percent = Double(count) * CategoryStore.costPerMessage / allowance * 100
        if percent < 0.5 { return "under 1% of your allowance" }
        return "about \(Int(percent.rounded()))% of your allowance"
    }
}
