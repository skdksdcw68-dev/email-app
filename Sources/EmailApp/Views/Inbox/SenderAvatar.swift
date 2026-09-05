import SwiftUI
import UIKit

/// A sender's face where there is one, their company's logo where there is
/// not, and their initial otherwise.
///
/// The three tiers are in that order for a reason: a photograph of the person
/// beats their employer's mark, and both beat a letter.
///
/// ## Where the photograph comes from
///
/// Gmail's own app shows faces because Google already holds your Contacts and
/// their pictures -- a different API and a different permission from reading
/// mail. Maily now asks for that permission too, optionally, so this tier
/// exists for anybody who granted it. See `PeopleDirectory`.
///
/// ⚠️ It covers people **in** your contacts, which is not most of an inbox.
/// Newsletters and no-reply addresses are not contacts of anybody's, and
/// Google's auto-collected "Other contacts" list carries no photos at all. So
/// the logo and the letter are not fallbacks for a rare failure -- they remain
/// what most rows show.
///
/// The letter colour is a hash of the address, so a sender is always the same
/// colour and two senders rarely collide.
struct SenderAvatar: View {
    let contact: Contact
    var size: CGFloat = 40
    var isMuted: Bool = false

    /// Whether to fall through to the sender's *domain* logo.
    ///
    /// 🔴 Right for a sender, wrong for you. A message from
    /// `billing@stripe.com` is from Stripe, and Stripe's mark is the most
    /// useful thing to draw. Your own mailbox at your own domain is not from
    /// your host -- and drawing your host's favicon next to your own name is
    /// how signing in as yourself came to show you Hostinger's logo.
    ///
    /// A letter is the better answer there: it is at least *your* letter.
    var allowsBrandIcon: Bool = true

    @State private var icon: UIImage?
    /// Whether `icon` is a photograph of a person rather than a company mark.
    /// A logo wants a white plate and an inset; a face wants to fill the
    /// circle, and treating a Gravatar as a logo puts somebody's head in a
    /// little box.
    @State private var iconIsPhoto = false

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

    private var people: PeopleDirectory { .shared }
    private var avatars: AvatarStore { .shared }

    /// The person's own photograph, if Contacts had one and it has been
    /// downloaded. Both stores are read here so this view redraws when either
    /// the contact list or the image lands.
    private var face: UIImage? {
        let _ = people.generation
        let _ = avatars.generation
        guard people.photo(for: contact.address) != nil else { return nil }
        return avatars.image(for: Self.key(for: contact.address))
    }

    /// Namespaced, so a person's face and a mailbox's cannot collide in the
    /// avatar folder -- the same address can be both.
    private static func key(for address: String) -> String {
        "person-\(address.lowercased())"
    }

    var body: some View {
        Group {
            if let face {
                photo(face)
            } else if let icon {
                iconIsPhoto ? AnyView(photo(icon)) : AnyView(brandIcon(icon))
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
            // The face first, and it is free to ask for: the contact list is
            // already in memory, and `ensure` returns immediately once the
            // image is on disk.
            if let photo = people.photo(for: contact.address) {
                avatars.ensure(key: Self.key(for: contact.address), url: photo)
                // A person with a photograph has no use for their employer's
                // logo, so nothing below is even started.
                return
            }

            guard allowsBrandIcon, icon == nil else { return }

            if let domain = BrandIcon.domain(for: contact.address) {
                Task { icon = await BrandIcon.shared.icon(for: domain) }
            } else {
                // No company to look up, which means a personal address --
                // gmail, icloud, a mail server of their own. Gravatar is the
                // one place a person publishes a picture that can be found
                // from an address alone, and it costs no permission to ask.
                let address = contact.address
                Task {
                    if let found = await BrandIcon.shared.gravatar(for: address) {
                        iconIsPhoto = true
                        icon = found
                    }
                }
            }
        }
    }

    /// A face, filling the circle. No plate and no inset -- those are for
    /// marks that have to survive being any shape.
    private func photo(_ image: UIImage) -> some View {
        // No `isMuted` fade here: the `Group` in `body` already applies it to
        // whichever tier drew, and doing it twice compounds to 0.72 rather
        // than the 0.85 a read message is meant to sit at.
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
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
