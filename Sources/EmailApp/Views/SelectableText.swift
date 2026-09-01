import SwiftUI
import UIKit

/// Text you can select a *part* of.
///
/// SwiftUI's `textSelection` selects a whole Text at once and offers Copy;
/// it has no handles and no way to take one sentence out of a paragraph.
/// A read-only UITextView has the platform's real selection: press and hold,
/// drag the handles, copy exactly the words you chose, with the system's
/// edit menu. That is what an answer, a summary and an email body deserve.
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString

    init(_ attributed: NSAttributedString) {
        self.attributed = attributed
    }

    /// Plain text in one font, with the line spacing the SwiftUI text used.
    init(
        _ string: String,
        font: UIFont = .preferredFont(forTextStyle: .body),
        color: UIColor = .label,
        lineSpacing: CGFloat = 3
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        attributed = NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link, .phoneNumber]
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if !view.attributedText.isEqual(to: attributed) {
            view.attributedText = attributed
        }
    }

    /// Exactly as tall as the text needs at the width offered, so it sits in
    /// a stack like any other view instead of asking to scroll.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}
