import SwiftUI

/// A sender's brand mark where one exists, initials otherwise.
///
/// Gmail's API returns no sender photo, so a real person's face is not
/// available to us at all. What *is* available is the domain, and a company
/// that sends mail has a favicon. GitHub, Apple and Stripe get their actual
/// logo; a human keeps initials.
///
/// Consumer mail domains are excluded deliberately -- every gmail.com sender
/// would otherwise wear the same Gmail icon, which is worse than nothing.
struct SenderAvatar: View {
    let contact: Contact
    var size: CGFloat = 40
    var tintOpacity: Double = 0.18

    private static let consumerDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
        "yahoo.com", "icloud.com", "me.com", "mac.com", "proton.me",
        "protonmail.com", "aol.com", "gmx.com", "zoho.com", "yandex.com",
    ]

    private var brandURL: URL? {
        guard let domain = contact.address.split(separator: "@").last?.lowercased(),
              !Self.consumerDomains.contains(String(domain)),
              domain.contains(".")
        else { return nil }

        return URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(domain)")
    }

    var body: some View {
        Group {
            if let brandURL {
                AsyncImage(url: brandURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        // Loading and failure both fall back to initials rather
                        // than a blank circle or a generic globe.
                        initials
                    }
                }
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: some View {
        Circle()
            .fill(Color.accentColor.opacity(tintOpacity))
            .overlay {
                Text(contact.initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.tint)
            }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 14) {
        SenderAvatar(contact: Contact(name: "GitHub", address: "noreply@github.com"))
        SenderAvatar(contact: Contact(name: "Apple", address: "no-reply@apple.com"))
        SenderAvatar(contact: Contact(name: "Sara Bekele", address: "sara@gmail.com"))
        SenderAvatar(contact: Contact(name: "Dawit Haile", address: "dawit@example.com"))
    }
    .padding()
}
