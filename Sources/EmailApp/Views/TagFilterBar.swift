import SwiftUI
import UIKit

/// The row of AI tag pills, pinned under the title.
///
/// Deliberately not inside a card or a section: it sits on the plain grouped
/// background the way Mail's category filters do, with no hairline and no
/// container. Boxing it was what made it read as cramped.
struct TagFilterBar: View {
    let tags: [AITag]
    let count: (AITag) -> Int
    @Binding var selection: AITag?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(tags) { tag in
                    Pill(tag: tag, count: count(tag), isSelected: selection == tag) {
                        withAnimation(.snappy(duration: 0.22)) {
                            selection = selection == tag ? nil : tag
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
                    // Unselected the colour lives on the glyph, so the label
                    // stays readable; selected, the pill is the colour.
                    .foregroundStyle(isSelected ? tag.onColor : tag.color)

                Text(tag.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? tag.onColor : Color.primary)
                    .fixedSize()

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? tag.onColor.opacity(0.7) : Color.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isSelected ? tag.color : Color(uiColor: .tertiarySystemFill))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tag.title), \(count) messages")
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
