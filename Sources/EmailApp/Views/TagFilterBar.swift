import SwiftUI
import UIKit

/// The row of AI tag pills, pinned under the title.
///
/// Deliberately not inside a card or a section: it sits on the plain grouped
/// background the way Mail's category filters do, with no hairline and no
/// container. Boxing it was what made it read as cramped.
///
/// `count` is the number of *unread* messages behind each pill. The pill is a
/// filter and stays either way, but the number is a to-do count -- once
/// everything urgent has been read or answered, "Very Urgent 49" becomes just
/// "Very Urgent", which is the reward for having dealt with it.
struct TagFilterBar: View {
    let tags: [AITag]
    let count: (AITag) -> Int
    @Binding var selection: AITag?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Style.tight) {
                ForEach(tags) { tag in
                    Pill(tag: tag, count: count(tag), isSelected: selection == tag) {
                        withAnimation(.snappy(duration: 0.22)) {
                            selection = selection == tag ? nil : tag
                        }
                    }
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
    let tag: AITag
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tag.systemImage)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(isSelected ? tag.onColor : tag.color)

                Text(tag.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? tag.onColor : Color.primary)
                    .fixedSize()

                // Nothing unread means no number at all. A zero would say
                // "still outstanding" about work that has been done.
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? tag.onColor.opacity(0.75) : Color.secondary)
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
                        ? AnyShapeStyle(tag.color)
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
        .accessibilityLabel(count > 0 ? "\(tag.title), \(count) unread" : tag.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

#Preview {
    PreviewHost()
}

private struct PreviewHost: View {
    @State private var selection: AITag? = .urgent

    var body: some View {
        VStack(spacing: 0) {
            TagFilterBar(tags: AITag.allCases, count: { _ in 3 }, selection: $selection)
            Spacer()
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
