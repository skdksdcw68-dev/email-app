import SwiftUI

/// The one thing you come to the inbox to *do*.
///
/// It was a glyph in the top-right corner, the same size and weight as
/// search, which said writing an email was one option among several. It is
/// not -- everything else on this screen is a way of finding something, and
/// this is the only way of making something.
///
/// So it is bigger, it is blue, and it is at the bottom where a thumb already
/// is. The top corners of a phone this size are the hardest place to reach
/// and the worst home for the most-used control on the screen.
///
/// Floating over the list rather than pinned under it: a bar would take a
/// row of mail away permanently, and this only needs the space it covers.
struct ComposeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background {
                    Circle()
                        .fill(Color.accentColor)
                        // Enough to lift it off the mail behind it without
                        // becoming a card sitting on the screen.
                        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                }
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("Write a new email")
        .padding(.trailing, Style.gutter)
        .padding(.bottom, Style.rowGutter)
    }
}

#Preview {
    ZStack(alignment: .bottomTrailing) {
        Color(uiColor: .systemBackground)
        ComposeButton {}
    }
}
