import Foundation

/// Keeps the notification extension's copy of the credentials in step.
///
/// `PushCredentials` is deliberately ignorant -- it knows an address and a
/// refresh grant and nothing about mailboxes, because it is compiled into an
/// extension that must not drag the app's model layer in behind it. This is
/// the half that knows about mailboxes, and it lives in the app.
///
/// It rebuilds every record from scratch rather than patching one at a time.
/// That costs a handful of Keychain calls at moments that are already slow --
/// connecting, restoring, disconnecting -- and in exchange it is impossible
/// for a record to be stale, orphaned, or missing on an install that
/// connected its mailbox before this existed. Self-healing beats clever here:
/// the failure mode of the patch version is a notification that quietly never
/// improves, which is exactly the class of bug that took a month to notice
/// last time.
enum PushCredentialMirror {

    /// Every Gmail mailbox gets a record; nothing else does.
    ///
    /// IMAP is excluded because it cannot receive a push at all -- the push
    /// function is driven by Gmail's Pub/Sub and has no other entry point, so
    /// a record for an IMAP mailbox would be a stored password that nothing
    /// could ever read. `MailAccount.canPush` says the same thing.
    static func rebuild(from accounts: [MailAccount], severalConnected: Bool) {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
        else { return }

        for account in accounts where account.provider == .gmail {
            guard let refresh = Keychain.read(.refreshToken, for: account.id) else {
                // Nothing stored yet: connected by a build that let the SDK
                // keep the credential, and `TokenBroker` will adopt it the
                // next time a token is needed. Clearing the record rather
                // than leaving an old one is the honest state.
                PushCredentials.forget(account.address)
                continue
            }

            PushCredentials.save(
                .init(
                    refreshToken: refresh,
                    clientID: clientID,
                    // Named on the lock screen only when there is a choice to
                    // make. With one mailbox connected, saying which mailbox
                    // it came from is noise on every single banner; with two,
                    // leaving it out means a work email and a personal one
                    // look identical. `PushDelegate.announce` decides the
                    // same way, so both writers agree.
                    mailboxName: severalConnected ? account.title : ""
                ),
                for: account.address
            )
        }
    }

    /// A mailbox is going. Its record goes with it, before the mailbox row
    /// does -- a record left behind is a refresh grant an extension would go
    /// on using for an account somebody believes they removed.
    static func forget(_ account: MailAccount) {
        PushCredentials.forget(account.address)
    }
}
