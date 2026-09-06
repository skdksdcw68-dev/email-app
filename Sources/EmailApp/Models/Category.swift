import SwiftUI
import UIKit

/// A label mail is sorted into: one of the ten built in, or one the person
/// made themselves.
///
/// The ten built-ins are `AITag` cases and keep everything that reads them
/// -- Auto-Reply, notifications, "needs your attention" -- exactly as it was.
/// This wraps each in something a person can rename, recolour, hide and
/// reorder, and lets them add their own beside it: "Support requests",
/// described in a sentence, sorted by the same call that already reads every
/// email.
struct Category: Identifiable, Codable, Hashable {
    /// The `AITag` raw value for a built-in; `c-<uuid>` for one the person made.
    var id: String
    var name: String
    var symbol: String
    var color: CategoryColor
    /// What the AI is told belongs here. Required for a custom category; on a
    /// built-in it is a note added to the definition the server already has
    /// -- "newsletters from my bank are Important".
    var guidance: String = ""
    var isVisible: Bool = true
    /// Bumped when the name or the guidance changes, so a message sorted
    /// under the old wording can be told apart from one sorted under the new.
    var revision: Int = 1

    var builtIn: AITag? { AITag(rawValue: id) }
    var isCustom: Bool { builtIn == nil }

    /// Whether the AI has to be told anything about this one at all.
    var speaksToTheModel: Bool {
        isCustom || !guidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func builtIn(_ tag: AITag) -> Category {
        Category(id: tag.rawValue, name: tag.title, symbol: tag.systemImage, color: CategoryColor(tag: tag))
    }

    /// The ten, in the order the chip row has always shown them.
    static var defaults: [Category] { AITag.allCases.map(builtIn) }

    static func custom(name: String, symbol: String, color: CategoryColor, guidance: String) -> Category {
        Category(
            id: "c-\(UUID().uuidString.lowercased())",
            name: name, symbol: symbol, color: color, guidance: guidance
        )
    }

    /// The symbols the editor offers. Enough to say what a category is,
    /// few enough to pick from in one look.
    static let symbols: [String] = [
        "tag.fill", "star.fill", "flame.fill", "bolt.fill", "bell.fill", "flag.fill",
        "envelope.fill", "person.fill", "person.2.fill", "briefcase.fill", "building.2.fill", "creditcard.fill",
        "cart.fill", "shippingbox.fill", "airplane", "car.fill", "house.fill", "heart.fill",
        "graduationcap.fill", "wrench.and.screwdriver.fill", "lifepreserver.fill", "questionmark.circle.fill", "doc.text.fill", "calendar",
    ]
}

/// A colour a category can be, by name.
///
/// Named rather than stored as a colour so it survives a change of palette,
/// encodes as a word, and stays an Apple system colour -- which shifts
/// between light and dark on its own so contrast holds in both.
enum CategoryColor: String, Codable, CaseIterable, Identifiable, Hashable {
    case red, orange, yellow, green, teal, blue, indigo, purple, pink, brown

    var id: Self { self }

    var color: Color {
        switch self {
        case .red:    Color(uiColor: .systemRed)
        case .orange: Color(uiColor: .systemOrange)
        case .yellow: Color(uiColor: .systemYellow)
        case .green:  Color(uiColor: .systemGreen)
        case .teal:   Color(uiColor: .systemTeal)
        case .blue:   Color(uiColor: .systemBlue)
        case .indigo: Color(uiColor: .systemIndigo)
        case .purple: Color(uiColor: .systemPurple)
        case .pink:   Color(uiColor: .systemPink)
        case .brown:  Color(uiColor: .systemBrown)
        }
    }

    /// Readable on top of `color` used as a fill. Yellow is the one that
    /// needs black.
    var onColor: Color { self == .yellow ? .black : .white }

    /// The colour each built-in has always had.
    init(tag: AITag) {
        switch tag {
        case .urgent:        self = .red
        case .veryImportant: self = .orange
        case .important:     self = .yellow
        case .needsReply:    self = .blue
        case .noReplyNeeded: self = .green
        case .meeting:       self = .purple
        case .finance:       self = .teal
        case .security:      self = .indigo
        case .newsletter:    self = .brown
        case .promotion:     self = .pink
        }
    }
}
