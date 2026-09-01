import SwiftUI

/// The empty chat, in Perplexity's shape: nothing on the page but the name,
/// with a slow light moving through the letters.
///
/// It is a background, not content. That is what keeps it still: the
/// ScrollView it sits behind absorbs the keyboard by changing its insets,
/// not its frame, and the wordmark also ignores the keyboard safe area
/// outright, so opening or closing the keyboard never moves it a point.
struct MailyWordmark: View {
    @State private var phase: CGFloat = -1

    private var glyphs: Text {
        Text("maily")
            .font(.system(size: 46, weight: .medium))
            .tracking(-1.2)
    }

    var body: some View {
        glyphs
            .foregroundStyle(Color.secondary.opacity(0.55))
            .overlay {
                // A soft band of light crossing the word every few seconds.
                // Slow on purpose; the fast skeleton shimmer reads as
                // "loading", and nothing here is loading.
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.5), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.55)
                    .offset(x: phase * proxy.size.width * 1.6)
                    .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
            }
            .mask(glyphs)
            .onAppear {
                withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("Maily")
    }
}

#Preview {
    MailyWordmark()
        .background(Color.black)
        .preferredColorScheme(.dark)
}
