import Foundation

/// Catching up, cheaply.
///
/// `refresh()` lists the inbox and fetches twenty-five messages to find out
/// whether anything arrived, which is twenty-six requests to usually learn
/// "no". Gmail keeps a history log instead: one request says exactly what
/// changed since a cursor, and the app fetches only that.
///
/// The difference is not only cost. It is what makes new mail appear the
/// moment it arrives rather than the next time somebody pulls to refresh,
/// and it is what a push notification wakes the app to do.
extension MailStore {

    private static var historyKey: String { "mail.historyId" }

    /// Where Gmail's log was last time the app looked.
    var syncCursor: String? {
        get { MailboxScope.defaults.string(forKey: Self.historyKey) }
        set {
            if let newValue {
                MailboxScope.defaults.set(newValue, forKey: Self.historyKey)
            } else {
                MailboxScope.defaults.removeObject(forKey: Self.historyKey)
            }
        }
    }

    /// Brings the mailbox up to date. Cheap when nothing happened, which is
    /// most of the time.
    ///
    /// Falls back to a full refresh when there is no cursor yet, or when the
    /// cursor is older than the week or so of history Gmail keeps.
    @discardableResult
    func catchUp() async -> [Message] {
        guard isConnected, !isRefreshing, !importProgress.isRunning else { return [] }
        guard let cursor = syncCursor else {
            await refresh()
            await rememberCursor()
            return []
        }

        do {
            let token = try await accessToken()
            let changes = try await GmailService.changes(since: cursor, accessToken: token)

            if changes.isExpired {
                await refresh()
                await rememberCursor()
                return []
            }

            var arrived: [Message] = []
            if !changes.added.isEmpty {
                arrived = try await GmailService.messages(ids: changes.added, accessToken: token)
                absorb(arrived)
            }
            if !changes.removed.isEmpty {
                forget(remoteIDs: Set(changes.removed))
            }

            // Only move the cursor once the work landed. Moving it first and
            // failing after would skip whatever was in that window forever.
            if let next = changes.historyId { syncCursor = next }

            if !arrived.isEmpty {
                let snapshot = messages
                Task { [id = account?.id] in
                    guard let id else { return }
                    await MessageArchive.save(snapshot, mailbox: id)
                }
                Task { await enhanceWithAI() }
            }
            return arrived.filter { $0.mailbox == .inbox }
        } catch {
            // A failed catch-up is not worth a banner. The next one, or a
            // pull to refresh, will get it.
            return []
        }
    }

    /// Records where Gmail's log is now, so the next catch-up has somewhere
    /// to start from.
    func rememberCursor() async {
        guard isConnected else { return }
        guard let token = try? await accessToken(),
              let id = try? await GmailService.currentHistoryID(accessToken: token)
        else { return }
        syncCursor = id
    }
}
