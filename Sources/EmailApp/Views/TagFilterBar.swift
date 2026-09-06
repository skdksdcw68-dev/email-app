import SwiftUI
import UIKit

/// The row of category pills, pinned under the title.
///
/// Deliberately not inside a card or a section: it sits on the plain grouped
/// background the way Mail's category filters do, with no hairline and no
/// container. Boxing it was what made it read as cramped.
///
/// `count` is the number of *unread* messages behind each pill. The pill is a
/// filter and stays either way, but the number is a to-do count -- once
/// everything urgent has been read or answered, "Very Urgent 49" becomes just
/// "Very Urgent", which is the reward for having dealt with it.
///
/// The pills are the person's categories, in their order and under their
/// names: the ten built in, and any they made. A long press on any pill, or
/// the trailing slider, opens the screen that manages them.
struct TagFilterBar: View {
    let categories: [Category]
    let count: (Category) -> Int
    @Binding var selection: Category?
    var onManage: (() -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Style.tight) {
                ForEach(categories) { category in
                    Pill(
                        category: category,
                        count: count(category),
                        isSelected: selection?.id == category.id
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            selection = selection?.id == category.id ? nil : category
                        }
                    }
                    .onLongPressGesture { onManage?() }
                }

                if let onManage {
                    ManagePill(action: onManage)
                }
            }
            .padding(.horizontal, Style.rowGutter)
            .padding(.vertical, Style.tight)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
    }
}

private struct Pill: View {
    let category: Category
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(isSelected ? category.color.onColor : category.color.color)

                Text(category.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? category.color.onColor : Color.primary)
                    .fixedSize()

                // Nothing unread means no number at all. A zero would say
                // "still outstanding" about work that has been done.
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? category.color.onColor.opacity(0.75) : Color.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                // Clean and neutral, with the colour carried by the glyph
                // alone. A tinted fill behind every chip was tried and
                // reverted: ten differently-coloured capsules in one row is
                // noise, not information.
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(category.color.color)
                        : AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                )
            }
            .overlay {
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Color(uiColor: .separator).opacity(0.5),
                    lineWidth: 0.5
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(category.name), \(count) unread" : category.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The way in to managing the row, at its end. A glyph alone: it is not a
/// filter and must not read as one.
private struct ManagePill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                .overlay {
                    Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Manage categories")
    }
}

#Preview {
    PreviewHost()
}

private struct PreviewHost: View {
    @State private var selection: Category? = .builtIn(.urgent)

    var body: some View {
        VStack(spacing: 0) {
            TagFilterBar(
                categories: Category.defaults, count: { _ in 3 }, selection: $selection, onManage: {}
            )
            Spacer()
        }
    }
}
