import Foundation

/// Changing which mailbox is in front of you.
///
/// One store that swaps its contents, rather than a store per account. The
/// archive is thousands of messages and a few megabytes decoded; two or three
/// resident at once in an app that has to survive a thirty second background
/// wake is how it gets killed for memory, and the symptom of that is
/// "notifications sometimes don't work", which is close to undiagnosable from
/// a TestFlight build. `@Environment(MailStore.self)` is also threaded through
/// every screen in the app.
///
/// The order below is the whole design. Save what the outgoing mailbox has,
/// fence the work it started, clear, repoint, load. Getting any of those out
/// of order loses mail.
extension MailStore {

    /// The overlay must not strobe.
    ///
    /// Decoding an archive is a hundred to four hundred milliseconds, so a
    /// fast switch would flash a blur and be gone before it read as anything.
    private static let minimumSwitch: TimeInterval = 0.35

    /// Puts a different mailbox in front of the person.
    func activate(_ next: MailAccount) async {
        guard next.id != account?.id else { return }

        isSwitching = true
        switchingTo = next
        let started = Date.now

        leaveCurrentMailbox()

        // Everything scoped -- the suite, the four in-memory caches, and the
        // five file-backed stores -- moves together.
        account = next
        registry.setActive(next.id)
        announceActiveMailbox()

        await loadArchive()

        // Only the disk read is on the critical path. The network can arrive
        // behind the overlay.
        let elapsed = Date.now.timeIntervalSince(started)
        if elapsed < Self.minimumSwitch {
            try? await Task.sleep(for: .seconds(Self.minimumSwitch - elapsed))
        }
        isSwitching = false
        switchingTo = nil

        Task { await restore() }
    }

    /// Puts down whatever the current mailbox was holding.
    ///
    /// Shared with `connect`, because connecting a mailbox while another one
    /// is open is a switch with an extra consent screen in front of it.
    func leaveCurrentMailbox() {
        // A message written and accepted belongs to the mailbox it was
        // written from. Held for a few more seconds and then sent from
        // whichever account happened to be current would be somebody's reply
        // going out from the wrong address.
        sendHeldNow()
        ClassificationCache.flush()

        if let going = account {
            let snapshot = messages
            Task { await MessageArchive.save(snapshot, mailbox: going.id) }
        }

        // Nothing that was already running may write after this point.
        bumpEpoch()

        write { $0 = [] }
        nextPageToken = nil
        searchResults = []
        searchTerms = []
        searchExplanation = nil
        searchError = nil
        importProgress = .idle
        importAudit = nil
        connectionError = nil
        forgetCaches()
    }
}
