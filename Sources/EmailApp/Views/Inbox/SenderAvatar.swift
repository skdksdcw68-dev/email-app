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
/// Gmail's own app shows faces because Google holds the profile photo of
/// every Google account, and the list of everyone you have ever written to.
/// Both are reachable with the two Contacts scopes, which Maily asks for
/// optionally -- see `PeopleDirectory` for the exact call, and for the
/// profile merge without which the list comes back with no faces at all.
///
/// ⚠️ It covers senders that are Google accounts with a photo set. Most
/// newsletters and no-reply addresses are not, so the logo and the letter are
/// not fallbacks for a rare failure -- they remain what most rows show.
///
/// The letter colour follows the letter, as it does in Gmail: every G is the
/// same purple and every B the same amber, so one company stays one colour
/// however many hosts it mails from.
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

    private var logos: LogoDirectory { .shared }

    /// 🔴 Keyed on the **letter**, not the address.
    ///
    /// It used to be a hash of the address, and Google -- which mails from
    /// `accounts.google.com`, `google.com` and a Play host -- was purple, blue,
    /// orange and red in a single screen. Gmail's rule is one colour per
    /// letter, so the same company reads as one thing all the way down.
    ///
    /// G and B are sampled from Gmail's own list (`#9254EA`, `#FCBD00`). The
    /// other letters are Google's palette, one each, and any of them can be
    /// swapped for a sampled value without touching anything else.
    private static let letterColors: [Character: Color] = [
        "A": rgb(0xEA4335), "B": rgb(0xFCBD00), "C": rgb(0x12B5CB),
        "D": rgb(0x34A853), "E": rgb(0xFA7B17), "F": rgb(0x5C6BC0),
        "G": rgb(0x9254EA), "H": rgb(0xF538A0), "I": rgb(0x4285F4),
        "J": rgb(0x00897B), "K": rgb(0xE8710A), "L": rgb(0xD81B60),
        "M": rgb(0x1E8E3E), "N": rgb(0x039BE5), "O": rgb(0xC5221F),
        "P": rgb(0x7627BB), "Q": rgb(0x6D4C41), "R": rgb(0x3949AB),
        "S": rgb(0x009688), "T": rgb(0x43A047), "U": rgb(0x546E7A),
        "V": rgb(0xD93025), "W": rgb(0xFF7043), "X": rgb(0x5E35B1),
        "Y": rgb(0x00ACC1), "Z": rgb(0x8E24AA),
    ]

    /// Digits, and a sender with nothing to take a letter from. Gmail's grey.
    private static let otherColor = rgb(0x5F6368)

    private static func rgb(_ hex: UInt32) -> Color {
        Color(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Stable across launches and across every address a company mails from.
    static func color(for contact: Contact) -> Color {
        // `.first` rather than `Character(_:)`: uppercasing "ß" gives "SS",
        // and a two-character string would trap the Character initialiser.
        guard let first = letter(for: contact).first else { return otherColor }
        return letterColors[first] ?? otherColor
    }

    static func letter(for contact: Contact) -> String {
        // The display name reads better than the address, unless the name IS
        // the address, in which case skip past any leading punctuation.
        let source = contact.name.contains("@") ? contact.address : contact.name
        let first = source.first { $0.isLetter || $0.isNumber }
        return first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color { Self.color(for: contact) }
    private var letter: String { Self.letter(for: contact) }

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

    /// The company's logo, once the server has said which one and the bytes
    /// have arrived.
    private var logo: UIImage? {
        let _ = logos.generation
        let _ = avatars.generation
        guard let key = logoKey else { return nil }
        return avatars.image(for: key)
    }

    /// Where the company's logo lives in the image cache, if the server has
    /// named one. Depends on the URL, so a better answer is a new key.
    private var logoKey: String? {
        guard allowsBrandIcon,
              let domain = BrandIcon.domain(for: contact.address),
              let url = logos.url(for: domain)
        else { return nil }
        return LogoDirectory.key(for: domain, url: url)
    }

    /// A Gravatar, for a personal address with no company behind it.
    private var gravatar: UIImage? {
        let _ = avatars.generation
        guard allowsBrandIcon, BrandIcon.domain(for: contact.address) == nil else { return nil }
        return avatars.image(for: BrandIcon.gravatarKey(for: contact.address))
    }

    var body: some View {
        // Read once per draw -- each is a dictionary lookup -- because the
        // tier decides both what is drawn and what animates.
        let face = self.face
        let logo = self.logo
        let gravatar = self.gravatar
        let tier = face != nil ? 3 : logo != nil ? 2 : gravatar != nil ? 1 : 0

        return Group {
            // In order: the person, then their company, then whatever they
            // published themselves, then a letter.
            if let face {
                photo(face)
            } else if let logo, let key = logoKey {
                brandIcon(logo, key: key)
            } else if let gravatar {
                photo(gravatar)
            } else {
                letterAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .opacity(isMuted ? 0.85 : 1)
        // Fades between tiers: a logo over a letter, a face over either. It
        // used to watch the logo alone, so a face popped in with no fade.
        .animation(.easeOut(duration: 0.18), value: tier)
        // 🔴 Nothing is fetched here any more.
        //
        // This used to start a DNS lookup and up to three image requests, per
        // row, on every appearance. All of that is one batched call to the
        // server now: `need` says "this domain is on screen", the requests are
        // collected for a moment, and one round trip answers the whole list.
        //
        // onAppear rather than .task: .task's closure is @Sendable and does
        // not inherit the view's MainActor, and every store touched here is
        // main-actor isolated.
        .onAppear { ask() }
    }

    private func ask() {
        // The face first. Free to check -- the contact list is already in
        // memory -- and somebody with a photograph has no use for their
        // employer's logo, so nothing else is started.
        if let photo = people.photo(for: contact.address) {
            avatars.ensure(key: Self.key(for: contact.address), url: photo)
            return
        }

        guard allowsBrandIcon else { return }

        if let domain = BrandIcon.domain(for: contact.address) {
            // Enqueues, and the batch goes out once the list settles.
            logos.need(domain)
            if let url = logos.url(for: domain) {
                avatars.ensure(key: LogoDirectory.key(for: domain, url: url), url: url)
            }
        } else if let url = BrandIcon.gravatarURL(for: contact.address) {
            // A personal address -- gmail, icloud, their own mail server.
            // ⚠️ Deliberately not routed through Maily's server: that would
            // mean sending a list of who writes to somebody to a server with
            // no other reason to know it. The hash is made on the phone and
            // goes straight to Gravatar.
            avatars.ensure(key: BrandIcon.gravatarKey(for: contact.address), url: url)
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

    /// A mark drawn like a photograph -- edge to edge, cropped to the circle
    /// -- when it fills its own frame, which an app icon or a BIMI mark does.
    /// That is how Gmail draws a BIMI logo, and it is the difference between
    /// "Supabase" and "a favicon of Supabase on a plate".
    ///
    /// A glyph on nothing -- a transparent PNG with the mark floating in it --
    /// keeps the white plate and the inset. Drawn edge to edge it would vanish
    /// in dark mode, or sit in the list as a ragged shape among circles.
    private func brandIcon(_ image: UIImage, key: String) -> some View {
        Group {
            if avatars.fillsFrame(key) {
                photo(image)
            } else {
                Circle()
                    .fill(.white)
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.19)
                    }
            }
        }
    }

    private var letterAvatar: some View {
        // Flat, as Gmail draws it. The sheen this used to carry was fine on
        // its own and, next to Gmail's list, read as a different kind of
        // object from every other avatar on the screen.
        Circle()
            .fill(color)
            .opacity(isMuted ? 0.62 : 1)
            .overlay {
                Text(letter)
                    // Gmail's proportion: a ~24pt letter in a 40pt circle,
                    // plain sans, a shade heavier than regular. Medium in SF
                    // sits closest to Google Sans's stroke.
                    .font(.system(size: size * 0.6, weight: .medium))
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
