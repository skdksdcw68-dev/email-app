import SwiftUI
import UIKit

/// A moving highlight, for skeletons and for text that has just been written.
///
/// Used two ways: on grey placeholder bars while a message body or summary is
/// still loading, and briefly over freshly generated text so it reads as having
/// arrived rather than having always been there.
struct Shimmer: ViewModifier {
    var active: Bool = true

    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask(content)
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmering(_ active: Bool = true) -> some View {
        modifier(Shimmer(active: active))
    }
}

/// A grey bar standing in for a line of text that has not arrived yet.
struct SkeletonLine: View {
    var width: CGFloat? = nil
    var height: CGFloat = 13

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2.5)
            .fill(Color(uiColor: .tertiarySystemFill))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .shimmering()
    }
}

/// The placeholder shown while a message body is still being fetched.
struct MessageSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SkeletonLine()
            SkeletonLine()
            SkeletonLine(width: 220)
            SkeletonLine()
            SkeletonLine(width: 160)
        }
        .accessibilityLabel("Loading message")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 24) {
        MessageSkeleton()
        Text("Freshly written text")
            .font(.body)
            .shimmering()
    }
    .padding()
}
