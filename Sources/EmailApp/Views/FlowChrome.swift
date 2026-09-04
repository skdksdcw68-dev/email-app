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

/// The X that closes: a small circled mark, the way modern sheets dismiss.
struct FlowCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
        .buttonStyle(BouncyButtonStyle())
        .accessibilityLabel("Close")
    }
}

/// Back, for any step that has somewhere to go back to. Styled like the
/// system's own back control so it reads as navigation, not cancellation.
///
/// Bare chevron by default. The word "Back" is opt-in, for the one flow that
/// fills the screen and has no navigation bar to borrow meaning from.
struct FlowBackButton: View {
    var showsLabel = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                if showsLabel { Text("Back") }
            }
            .foregroundStyle(showsLabel ? Color.accentColor : Color.primary)
        }
        .buttonStyle(BouncyButtonStyle())
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
