import Foundation

struct Contact: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var address: String

    /// Up to two letters, used for the avatar bubble in the message list.
    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

extension Contact {
    static let me = Contact(name: "Abel Amare", address: "abelamare1633@gmail.com")
}
