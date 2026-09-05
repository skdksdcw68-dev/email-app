import SwiftUI

// The two controls every modal and every multi-step flow uses to get out.
//
// They started in `BulkReplyComponents`, used by one screen, while every
// other sheet in the app hand-wrote its own `Button("Cancel")` -- and one
// wrote "Not now", and another wrote "Done", and a fourth put it on the
// trailing side. Four screens, four spellings of the same idea.
//
// Words are worse than symbols here for a reason beyond consistency:
// "Cancel" reads as *undo what I just did*, and on a half-finished form
// that is a promise the button does not keep. An X says close, which is
// the truth.

/// The X that closes.
///
/// 🔴 **Drawn by the system, not by us.** It used to be a bold glyph inside a
/// hand-made grey circle with a spring animation on it -- a button that
/// *looked* like a control iOS draws and behaved like one nothing else in the
/// system does. It sat a few points off every real toolbar item, it did not
/// take the tint, and it did not grow with Dynamic Type.
///
/// A plain `Button` in a toolbar gets all of that for free, and gets it right
/// on an OS version this code has never run on.
struct FlowCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
    }
}

/// Back, for a step inside a flow that has somewhere to go back to.
///
/// ⚠️ **Only for flows that are not a `NavigationStack` push.** Where there is
/// a real push, the system's own back button is the right control and this is
/// the wrong one: the system's carries the previous screen's title, follows
/// the platform's animation, and -- the part that cannot be reproduced --
/// works with the edge-swipe gesture. Somebody swiping back on a hand-drawn
/// chevron gets nothing and concludes the app is stuck.
///
/// So this is for the multi-step sheets, where each step is a state rather
/// than a pushed screen and there is genuinely nothing for the system to draw.
struct FlowBackButton: View {
    var showsLabel = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if showsLabel {
                Label("Back", systemImage: "chevron.left")
            } else {
                Image(systemName: "chevron.left")
            }
        }
        .accessibilityLabel("Back")
    }
}

extension View {
    /// A sheet that only closes when somebody says so.
    ///
    /// Swiping down is how a sheet is dismissed by accident: a scroll that
    /// starts a few pixels too high takes the whole screen with it, and every
    /// answer on it. That is fine for a picker and wrong for anything with
    /// work in it, so the ones with work get this and the pickers keep their
    /// grabber -- a handle that no longer dismisses is a control that lies.
    func closesOnlyOnPurpose() -> some View {
        interactiveDismissDisabled()
    }
}
