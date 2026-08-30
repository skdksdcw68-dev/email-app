import SwiftUI
import UIKit

/// The row of AI tag chips. Tapping the selected chip clears the filter.
///
/// Lives inside the summary card rather than in its own pinned bar under a
/// hairline -- that separation was what made it look cramped and bolted on.
struct TagFilterBar: View {
    let tags: [AITag]
    let count: (AITag) -> Int
    @Binding var selection: AITag?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(tags) { tag in
                    Chip(
                        tag: tag,
                        count: count(tag),
                        isSelected: selection == tag
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            selection = selection == tag ? nil : tag
                        }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct Chip: View {
    let tag: AITag
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tag.systemImage)
                    .font(.caption2.weight(.bold))
                    // Unselected: the colour lives on the glyph so the label
                    // stays readable. Selected: the capsule is the colour, so
                    // the glyph takes the contrasting foreground.
                    .foregroundStyle(isSelected ? tag.onColor : tag.color)

                Text(tag.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isSelected ? tag.onColor : Color.primary)
                    .fixedSize()

                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? tag.onColor.opacity(0.75) : Color.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
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
        TagFilterBar(tags: AITag.allCases, count: { _ in 3 }, selection: $selection)
            .padding()
    }
}
