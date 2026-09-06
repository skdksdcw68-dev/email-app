import SwiftUI
import UIKit

/// Small tag capsule shown on message rows and in the detail header.
///
/// The colour lives on the symbol, not the text: system yellow as label text
/// is unreadable on a light background. Apple does the same in Reminders and
/// Finder tags -- coloured glyph, adaptive label.
struct TagBadge: View {
    let tag: AITag
    var showsTitle = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tag.systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tag.color)
            if showsTitle {
                Text(tag.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, showsTitle ? 7 : 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }
}

/// The same capsule for a category -- a built-in under the name the person
/// gave it, or one they made.
struct CategoryBadge: View {
    let category: Category
    var showsTitle = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(category.color.color)
            if showsTitle {
                Text(category.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, showsTitle ? 7 : 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
    }
}

#Preview("Light") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(AITag.allCases) { TagBadge(tag: $0) }
    }
    .padding()
}

#Preview("Dark") {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(AITag.allCases) { TagBadge(tag: $0) }
    }
    .padding()
    .preferredColorScheme(.dark)
}
