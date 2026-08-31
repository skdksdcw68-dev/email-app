import SwiftUI
import UIKit

/// A sender's logo where one genuinely exists, and their initial where it
/// does not.
///
/// Gmail's own app shows photographs here because Google already holds your
/// Contacts and their profile pictures -- a different API and a different
/// scope than reading mail. With mail scopes alone there is no photo to show,
/// so a company gets its logo and a person gets a coloured letter.
///
/// The letter colour is a hash of the address, so a sender is always the same
/// colour and two senders rarely collide.
struct SenderAvatar: View {
    let contact: Contact
    var size: CGFloat = 40
    var isMuted: Bool = false

    @State private var icon: UIImage?

    private static let palette: [Color] = [
        Color(uiColor: .systemBlue), Color(uiColor: .systemIndigo),
        Color(uiColor: .systemPurple), Color(uiColor: .systemPink),
        Color(uiColor: .systemRed), Color(uiColor: .systemOrange),
        Color(uiColor: .systemGreen), Color(uiColor: .systemTeal),
        Color(uiColor: .systemCyan), Color(uiColor: .systemBrown),
    ]

    /// Deterministic and stable across launches. `hashValue` is seeded per
    /// process in Swift, so a sender's colour would change every cold start.
    private var color: Color {
        let key = contact.address.lowercased()
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Self.palette[Int(hash % UInt64(Self.palette.count))]
    }

    private var letter: String {
        // The display name reads better than the address, unless the name IS
        // the address, in which case skip past any leading punctuation.
        let source = contact.name.contains("@") ? contact.address : contact.name
        let first = source.first { $0.isLetter || $0.isNumber }
        return first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Group {
            if let icon {
                brandIcon(icon)
            } else {
                letterAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .opacity(isMuted ? 0.85 : 1)
        .animation(.easeOut(duration: 0.18), value: icon != nil)
        // The letter shows first and the logo replaces it if one turns up.
        // Waiting on the network before drawing anything would leave a row of
        // holes on every cold scroll.
        //
        // onAppear rather than .task: .task's closure is @Sendable and does
        // not inherit the view's MainActor, where a Task started from here
        // does, so the assignment below stays on the main actor.
        .onAppear {
            guard icon == nil, let domain = BrandIcon.domain(for: contact.address) else { return }
            Task { icon = await BrandIcon.shared.icon(for: domain) }
        }
    }

    /// On a white plate, inset like an app icon. Logos come in every shape and
    /// half of them are transparent or near-black -- drawn edge to edge on the
    /// row background, those either vanish in dark mode or sit in the list as
    /// a ragged square among circles.
    private func brandIcon(_ image: UIImage) -> some View {
        Circle()
            .fill(.white)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.19)
            }
    }

    private var letterAvatar: some View {
        Circle()
            .fill(color)
            // A light-to-dark sheen instead of a flat disc. Color.mix would be
            // tidier but is iOS 18, and this target is 17.
            .overlay {
                LinearGradient(
                    colors: [.white.opacity(0.22), .black.opacity(0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(Circle())
            }
            .opacity(isMuted ? 0.62 : 1)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(
            [
                Contact(name: "Maya Chen", address: "maya@example.com"),
                Contact(name: "Abel Amare", address: "abel@gmail.com"),
                Contact(name: "Remisnap", address: "hello@remisnap.com"),
                Contact(name: "GitHub", address: "noreply@github.com"),
                Contact(name: "Stripe", address: "billing@stripe.com"),
                Contact(name: "X", address: "info@x.com"),
            ]
        ) { contact in
            HStack(spacing: 12) {
                SenderAvatar(contact: contact)
                Text(contact.name)
            }
        }
    }
    .padding()
}
