import Foundation

/// Ending the Maily account on this phone, in one place.
///
/// 🔴 There were two of these, written months apart, and they did different
/// things under near-identical words: "Sign out of Maily" on Edit profile
/// cleared ten stores, "Sign out and erase" in Privacy cleared four. Both
/// called `mail.disconnect()`, which takes the mailbox *in front of you* and
/// promotes the next one -- so anybody with two mailboxes signed out, signed
/// back in, and was met by the other account's mail, already imported, under
/// a Maily account that no longer existed on this phone.
///
/// The rule this settles: an account owns its mailboxes. When it goes, they
/// go, and the next sign-in starts at "connect an inbox". A mailbox is a
/// grant somebody made to *their* account; it is not furniture that belongs
/// to the phone.
@MainActor
enum AccountTeardown {

    /// Signs out of Maily itself and leaves nothing of it behind.
    ///
    /// The order matters in one place only: mailboxes first, while their
    /// tokens are still readable, because ending a Gmail grant needs the
    /// token that the teardown is about to delete.
    static func signOutOfMaily(
        mail: MailStore,
        memory: AIMemory,
        chats: ChatHistory,
        user: UserStore
    ) {
        // Every mailbox, not just the active one.
        mail.disconnectEverything()

        // Per-person and per-thread preferences. Scoped to a mailbox, but
        // written before mailboxes were scoped, so cleared by hand.
        PersonPreferences.clearAll()
        FollowUpPreferences.clearAll()

        // Memory is about the person rather than the mailbox, so disconnecting
        // an inbox keeps it. Signing out of the account does not.
        memory.forgetAll()
        chats.clearAll()

        // Both kinds of face: the one they chose, and every one a provider
        // supplied. `AvatarStore.forgetAll` rather than a per-mailbox forget,
        // because a picture whose account has already been deleted is the one
        // nothing would think to remove.
        ProfilePhoto.clearAll()
        AvatarStore.shared.forgetAll()

        // The contact list those faces were matched against. It is somebody's
        // address book; it does not outlive their account.
        PeopleDirectory.shared.forgetAll()

        // The domain-to-logo map too. It holds no addresses -- only which
        // companies write to this phone -- but that is still a list about
        // somebody.
        LogoDirectory.shared.forgetAll()

        // The chips, including any the person wrote themselves. They come
        // back from the server on the next sign-in; what must not happen is
        // the next account inheriting them from the last one.
        CategoryStore.shared.forgetAll()

        user.signOut()
        Task { await AuthService.signOut() }
    }
}
