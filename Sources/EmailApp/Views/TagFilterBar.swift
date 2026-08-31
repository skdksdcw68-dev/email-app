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
                    .foregroundStyle(isSelected ? tag.onColor : tag.color)

                Text(tag.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isSelected ? tag.onColor : Color.primary)
                    .fixedSize()

                // The count sits in its own well, the way a badge does in
                // Mail's sidebar. Loose next to the label it read as part of
                // the title.
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isSelected ? tag.color : tag.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background {
                        Capsule().fill(isSelected ? tag.onColor : tag.color.opacity(0.16))
                    }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background {
                // Tinted with the tag's own colour rather than a neutral
                // grey. The grey fill was the thing making these read as
                // generic controls instead of as this app's tags -- Apple
                // tints the whole chip and lets the label stay legible.
                Capsule()
                    .fill(isSelected ? tag.color : tag.color.opacity(0.13))
                    .overlay {
                        Capsule()
                            .strokeBorder(tag.color.opacity(isSelected ? 0 : 0.22), lineWidth: 0.5)
                    }
            }
            // Just enough lift to read as a control sitting on the page.
            .shadow(
                color: tag.color.opacity(isSelected ? 0.28 : 0),
                radius: 6,
                y: 2
            )
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
