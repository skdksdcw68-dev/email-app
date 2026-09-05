import SwiftUI

/// A mailbox's own face.
///
/// 🔴 The distinction this exists to draw: **a mailbox is a person you have
/// signed in as, and a sender is not.**
///
/// `SenderAvatar` is right to show a company logo or a coloured letter -- for
/// somebody who wrote to you there genuinely is no photo, because that would
/// need their Contacts entry and a scope Maily does not ask for. But every
/// account row in the app was using it too, and that was wrong for a reason
/// nobody spotted: the person *has already handed the picture over*. It comes
/// back on the same `profile` scope that supplies the name printed next to it.
///
/// The visible symptom was Abel's: an account at a custom domain drew that
/// domain's **favicon** -- because `SenderAvatar` falls through to a brand
/// lookup -- so signing in as yourself showed you your host's logo.
///
/// Falls back to `SenderAvatar` when there is no picture, which is always the
/// case for IMAP: a mail server knows a password, not a face.
struct MailboxAvatar: View {
    let account: MailAccount
    var size: CGFloat = 40

    private var store: AvatarStore { .shared }

    var body: some View {
        // Read first, so this view redraws when a picture lands. It is the
        // only observed thing on the store; see the note there.
        let _ = store.generation

        Group {
            if let image = store.image(for: account.id.rawValue) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                // The letter shows immediately and the face replaces it. A row
                // of holes while four downloads run is worse than a letter
                // that becomes a photograph.
                //
                // ⚠️ `allowsBrandIcon: false` is the fix for what Abel
                // actually saw. Without it an IMAP mailbox at a custom domain
                // draws that domain's favicon -- your host's logo standing in
                // for your face.
                SenderAvatar(contact: account.contact, size: size, allowsBrandIcon: false)
            }
        }
        .onAppear { store.ensure(key: account.id.rawValue, url: account.photoURL) }
    }
}
