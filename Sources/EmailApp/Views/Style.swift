import SwiftUI

/// The numbers, written down once.
///
/// This is not a new look. Counting what the app already does turns up two
/// padding values covering half of it and one corner radius covering two
/// thirds -- there *is* a system here, it was simply never stated, so every
/// screen re-decided and about a third of them drifted. Eighteen horizontal
/// padding values. Seven corner radii. `.title2.bold()` in one file and
/// `.title2.weight(.bold)` in the next, which are the same thing.
///
/// So the names below are the majority answer, not an opinion. Most screens
/// are already right; what this does is make the ones that are not obvious.
///
/// Roles rather than sizes, deliberately. `Style.rowTitle` survives somebody
/// deciding rows should be a shade larger; `.subheadline` repeated
/// eighty-four times does not.
enum Style {

    // MARK: - Space

    /// The screen edge. What content is inset by when the app draws the
    /// container itself.
    static let gutter: CGFloat = 20
    /// Inside a `List` row, where the system has already inset things.
    static let rowGutter: CGFloat = 16
    /// Between things that belong together.
    static let tight: CGFloat = 8
    /// Between things that do not.
    static let loose: CGFloat = 32

    // MARK: - Shape

    /// Cards, tiles, grouped blocks.
    static let card: CGFloat = 14
    /// Anything that should read as a control rather than a container.
    static let pill: CGFloat = 22

    // MARK: - Type
    //
    // Each of these is what the majority of the app already uses for the
    // job. Changing one here changes it everywhere, which is the point.

    /// The line you read first in a row.
    static let rowTitle = Font.subheadline
    /// The same, when it needs to carry weight.
    static let rowTitleStrong = Font.subheadline.weight(.semibold)
    /// What a row is set to, on the right.
    static let rowValue = Font.subheadline
    /// The line under a title that explains it.
    static let rowDetail = Font.caption
    /// A row's third line -- the opening of the mail, the gist of the thing.
    static let rowPreview = Font.footnote
    /// A section's name.
    static let sectionHeader = Font.footnote.weight(.semibold)
    /// The small print under a section, where the reasoning goes.
    static let sectionFooter = Font.footnote
    /// The quietest thing on screen.
    static let caption = Font.caption2
    /// A screen's own title, where it is drawn rather than in a nav bar.
    static let screenTitle = Font.title3.weight(.bold)
    /// The big one, for a step in a flow.
    static let stepTitle = Font.title2.weight(.bold)
}

// MARK: - Meaning

/// Colours that mean something, rather than colours that look like something.
///
/// ⚠️ The reason for this is *not* dark mode, and it is worth being exact
/// because the obvious reason is wrong: SwiftUI's `Color.red` and
/// `Color(uiColor: .systemRed)` are the same adaptive system colour and both
/// already handle it. Nothing is broken.
///
/// The reason is that the app says the same thing two ways -- eleven
/// `Color(uiColor: .systemGreen)` beside four `.green`, six `.systemRed`
/// beside fourteen `.red` -- so there is no one place to change what
/// "urgent" looks like, and no way to tell a colour that carries meaning
/// from a colour somebody liked.
///
/// They resolve to the system's answer today. Naming them is what makes it
/// possible to disagree with the system later, in one place.
extension Color {
    /// Needs attention now. Also destructive actions.
    static let urgent = Color(uiColor: .systemRed)
    /// Flagged by hand.
    static let flagged = Color(uiColor: .systemOrange)
    /// Something did not work, but nothing was lost by it.
    ///
    /// The same orange as `flagged` today, and named apart on purpose: they
    /// are two meanings that happen to share a colour, and one of them will
    /// eventually want to stop.
    static let warning = Color(uiColor: .systemOrange)
    /// Put away until later.
    static let snoozed = Color(uiColor: .systemIndigo)
    /// Connected, saved, safe.
    static let ok = Color(uiColor: .systemGreen)
}

// MARK: - Applying it

extension View {
    /// Content inset from the screen edge.
    func screenGutter() -> some View {
        padding(.horizontal, Style.gutter)
    }

    /// A card: the app's one corner radius, on the app's one card colour.
    ///
    /// Twenty-nine places build this by hand and six of them use a different
    /// radius, which is exactly the kind of difference nobody sees on one
    /// screen and everybody feels across ten.
    func cardBackground(_ fill: Color = Color(uiColor: .secondarySystemBackground)) -> some View {
        background {
            RoundedRectangle(cornerRadius: Style.card, style: .continuous).fill(fill)
        }
    }
}
