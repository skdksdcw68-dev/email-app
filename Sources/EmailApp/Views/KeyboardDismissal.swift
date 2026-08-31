import SwiftUI
import UIKit

/// Puts the keyboard away, from anywhere.
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
    )
}

extension View {
    /// Everything a screen with a keyboard needs in order to let it go.
    ///
    /// Two mechanisms, because neither alone covers a real screen:
    ///
    /// - `scrollDismissesKeyboard` handles the scrolling part, which is most
    ///   of a List or a Form. A tap gesture cannot reach those: the rows are
    ///   on top of any background and swallow it.
    /// - A tap on the background catches the empty space around and below the
    ///   content, which is where people actually tap to get rid of it.
    ///
    /// Deliberately NOT a `simultaneousGesture` across the whole view. That
    /// was tried, and it fired when tapping into a field, and its recogniser
    /// fought the hold-to-record drag until recording stopped working. A
    /// gesture behind the content cannot conflict with a control on top of it.
    func keyboardDismissable() -> some View {
        self
            .scrollDismissesKeyboard(.interactively)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
            }
    }

    /// Older name, kept so existing call sites keep working.
    func dismissesKeyboardOnBackgroundTap() -> some View {
        keyboardDismissable()
    }
}
