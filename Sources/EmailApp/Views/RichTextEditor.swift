import SwiftUI
import UIKit

/// A text editor that can carry bold, italic and underline.
///
/// SwiftUI's own TextEditor is plain-text only on iOS 17 -- it binds to a
/// String, so there is nowhere for formatting to live. UITextView with
/// `allowsEditingTextAttributes` gets the system's Format menu on a selection
/// for free, which is the same B/I/U that Mail and Gmail show.
struct RichTextEditor: UIViewRepresentable {
    @Binding var text: NSAttributedString
    /// Applied to the whole view. Only ever used to flash an AI draft as it
    /// lands, which is safe because generated text carries no formatting of
    /// its own to overwrite.
    var textColor: UIColor = .label

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.allowsEditingTextAttributes = true
        view.isEditable = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.typingAttributes = Self.defaultAttributes(color: textColor)
        // Dismissing the keyboard by dragging the text, the way Messages does.
        view.keyboardDismissMode = .interactive
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Only write back when it genuinely differs, or every keystroke would
        // reset the caret to the end of the text.
        if !view.attributedText.isEqual(to: text) {
            let selected = view.selectedRange
            view.attributedText = text
            // Clamp: a programmatic replacement is usually shorter or longer
            // than what was there, and an out-of-range selection crashes.
            let limit = view.attributedText.length
            view.selectedRange = NSRange(
                location: min(selected.location, limit),
                length: min(selected.length, max(0, limit - min(selected.location, limit)))
            )
        }
        if view.textColor != textColor {
            view.textColor = textColor
            view.typingAttributes = Self.defaultAttributes(color: textColor)
        }
    }

    static func defaultAttributes(color: UIColor = .label) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: color,
        ]
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: RichTextEditor

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.attributedText
        }
    }
}

extension NSAttributedString {
    /// Plain text as it would read with no markup at all.
    var plainText: String { string }

    /// Whether the user actually applied any formatting.
    ///
    /// Worth checking: a message with no bold or italic in it should go out as
    /// plain text rather than dragging a document's worth of generated CSS
    /// behind it.
    var hasFormatting: Bool {
        var found = false
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, _, stop in
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.traitBold) || traits.contains(.traitItalic) {
                    found = true
                    stop.pointee = true
                    return
                }
            }
            if attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    /// An HTML rendering, for the alternative part of a sent message.
    ///
    /// Must run on the main thread: the HTML writer is not thread-safe and
    /// silently misbehaves off it.
    @MainActor
    func htmlBody() -> String? {
        guard length > 0 else { return nil }
        let options: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let data = try? data(
            from: NSRange(location: 0, length: length),
            documentAttributes: options
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
