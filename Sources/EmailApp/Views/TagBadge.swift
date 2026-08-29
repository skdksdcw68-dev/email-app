import SwiftUI

/// Small tinted capsule shown on message rows and in the detail header.
struct TagBadge: View {
    let tag: AITag
    var showsTitle = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tag.systemImage)
                .font(.system(size: 9, weight: .bold))
            if showsTitle {
                Text(tag.title)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(tag.color)
        .padding(.horizontal, showsTitle ? 7 : 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(tag.color.opacity(0.13)))
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(AITag.allCases) { TagBadge(tag: $0) }
    }
    .padding()
}
