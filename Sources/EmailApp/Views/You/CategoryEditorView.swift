import SwiftUI

/// One category: its name, icon, colour, and what Maily is told belongs in
/// it. The same sheet makes a new one and edits an old one.
struct CategoryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MailStore.self) private var mail

    private var store: CategoryStore { .shared }

    private let existing: Category?

    @State private var name: String
    @State private var symbol: String
    @State private var color: CategoryColor
    @State private var guidance: String
    @State private var isConfirmingDelete = false

    init(category: Category?) {
        existing = category
        _name = State(initialValue: category?.name ?? "")
        _symbol = State(initialValue: category?.symbol ?? "tag.fill")
        _color = State(initialValue: category?.color ?? .blue)
        _guidance = State(initialValue: category?.guidance ?? "")
    }

    private var isCustom: Bool { existing?.isCustom ?? true }

    /// A custom category has to say what it is: without that the model has
    /// nothing to sort by, and a label that never fills is a broken one.
    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGuidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty && (!isCustom || !trimmedGuidance.isEmpty)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }

                Section("Icon") {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Category.symbols, id: \.self) { candidate in
                            Button { symbol = candidate } label: {
                                Image(systemName: candidate)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(candidate == symbol ? color.onColor : Color.primary)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        Circle().fill(
                                            candidate == symbol
                                                ? AnyShapeStyle(color.color)
                                                : AnyShapeStyle(Color(uiColor: .tertiarySystemFill))
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(candidate)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Colour") {
                    HStack(spacing: 0) {
                        ForEach(CategoryColor.allCases) { candidate in
                            Circle()
                                .fill(candidate.color)
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if candidate == color {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(candidate.onColor)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture { color = candidate }
                                .accessibilityLabel(candidate.rawValue)
                                .accessibilityAddTraits(candidate == color ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField(
                        isCustom
                            ? "Customers writing to support about an order"
                            : "Newsletters from my bank are Important",
                        text: $guidance,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                } header: {
                    Text(isCustom ? "What belongs here" : "Note to Maily")
                } footer: {
                    Text(isCustom
                         ? "Maily reads this when it sorts each email, exactly as written, so say it the way you would to a colleague. It applies to mail from people; newsletters and automatic mail are sorted on the phone and are never sent."
                         : "Optional. Added to what Maily already knows this category means.")
                }

                if let existing, existing.isCustom {
                    Section {
                        Button("Delete category", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Delete this category?", isPresented: $isConfirmingDelete, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let existing {
                        store.remove(id: existing.id)
                        mail.removeCustomTag(existing.id)
                    }
                    dismiss()
                }
            } message: {
                Text("Mail sorted into it stays where it is; only the label goes.")
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGuidance = guidance.trimmingCharacters(in: .whitespacesAndNewlines)

        if var updated = existing {
            updated.name = trimmedName
            updated.symbol = symbol
            updated.color = color
            updated.guidance = trimmedGuidance
            store.update(updated)
        } else {
            store.add(.custom(name: trimmedName, symbol: symbol, color: color, guidance: trimmedGuidance))
        }
        // The newest hundred straight away; see `CategoryStore.refreshDepth`.
        Task { await mail.enhanceWithAI() }
        dismiss()
    }
}
