import SwiftUI
import UIKit

/// Brand moment, not a logo card. No buttons, no questions -- it says the name
/// and the promise, then gets out of the way on its own.
struct SplashView: View {
    @Environment(UserStore.self) private var user

    @State private var nameShown = false
    @State private var taglineShown = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("Maily")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .opacity(nameShown ? 1 : 0)
                    .scaleEffect(nameShown ? 1 : 0.92)

                Text("Your inbox. Under control.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .opacity(taglineShown ? 1 : 0)
                    .offset(y: taglineShown ? 0 : 6)
            }
        }
        // .onAppear rather than .task: .task takes a @Sendable closure, which
        // does NOT inherit @MainActor, so calling into the store from it fails
        // to compile. A Task created inside .onAppear inherits MainActor.
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { nameShown = true }
            withAnimation(.easeOut(duration: 0.55).delay(0.25)) { taglineShown = true }

            Task {
                try? await Task.sleep(for: .seconds(1.7))
                user.advanceFromSplash()
            }
        }
    }
}

#Preview {
    SplashView().environment(UserStore(defaults: .previews, startAt: .splash))
}
