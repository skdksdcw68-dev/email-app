import SwiftUI
import UIKit

/// A sender's initial on a colour derived from their address.
///
/// There is no photo to show. Gmail's API returns no sender image at all --
/// Gmail's own app has them because Google already holds your Contacts and
/// their profile pictures, which is a different API and a different scope.
///
/// A favicon lookup was tried and removed: most domains return a generic globe,
/// so the list filled up with identical grey planets. Gmail's own fallback is a
/// coloured letter, and doing that consistently looks far better than doing
/// logos badly for one sender in ten.
///
/// The colour is a hash of the address, so a sender is always the same colour
/// and two different senders rarely collide.
struct SenderAvatar: View {
    let contact: Contact
    var size: CGFloat = 40
    var isMuted: Bool = false

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
        Circle()
            .fill(color.opacity(isMuted ? 0.55 : 1))
            .frame(width: size, height: size)
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
                Contact(name: "Avery Collins", address: "avery.collins@example.com"),
                Contact(name: "Dad", address: "dad@gmail.com"),
                Contact(name: "Jordan Bell", address: "jordan@bell.io"),
                Contact(name: "Render Billing", address: "billing@render.com"),
                Contact(name: "noreply@github.com", address: "noreply@github.com"),
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
