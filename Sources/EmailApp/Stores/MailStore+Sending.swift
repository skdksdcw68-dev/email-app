import Foundation
import UIKit

/// Sending, with a few seconds to change your mind.
///
/// Not a recall. Once Gmail has a message it is gone and no button anywhere
/// brings it back, so the only honest version of "undo send" is to not send
/// it yet. The message is held on the phone for a few seconds, the app says
/// so, and the send happens when the window closes.
///
/// That means the delay is real: the person is waiting those seconds too.
/// Eight is the number Gmail settled on and it is about right -- long enough
/// to catch the wrong recipient or the missing attachment, short enough that
/// nobody thinks it failed.
///
/// The one rule everything here follows: a message that was not cancelled
/// gets sent. Backgrounding the app, sending a second one, closing the
/// sheet -- none of those are a decision to abandon it, so all of them send
/// what is waiting rather than dropping it.
extension MailStore {

    /// A send that has not gone yet.
    struct HeldSend: Identifiable, Equatable {
        let id: UUID
        let subject: String
        let recipient: String
        /// When it goes, so a countdown can draw itself.
        let sendsAt: Date

        static func == (left: HeldSend, right: HeldSend) -> Bool { left.id == right.id }
    }

    /// How long a message waits before it actually goes, in seconds.
    static let undoWindow: TimeInterval = 8

    /// Sends after the undo window, unless it is called off.
    ///
    /// Returns as soon as the message is held, so the compose sheet closes
    /// the way it always did. The send reports through `heldSend` clearing
    /// and, if it fails, `sendFailure`.
    func sendWithUndo(
        subject: String,
        to address: String,
        cc: String? = nil,
        bcc: String? = nil,
        body: String,
        html: String? = nil,
        attachments: [MIMEBuilder.Attached] = [],
        replyingTo original: Message? = nil,
        discardingDraft draft: Message? = nil
    ) {
        // Anything already waiting goes now rather than being replaced. Two
        // messages held at once with one banner between them is two messages
        // nobody knows the state of.
        sendHeldNow()

        let id = UUID()
        heldSend = HeldSend(
            id: id,
            subject: subject.isEmpty ? "(No Subject)" : subject,
            recipient: address,
            sendsAt: .now.addingTimeInterval(Self.undoWindow)
        )

        // The work itself, kept apart from the timer so it can be run early.
        heldWork = { [weak self] in
            guard let self else { return }
            do {
                try await send(
                    subject: subject, to: address, cc: cc, bcc: bcc, body: body,
                    html: html, attachments: attachments, replyingTo: original
                )
                if let original { markReplied(original.id) }
                // Only once it has actually gone. Discarding first would lose
                // the text if the send failed.
                if let draft { await discardDraft(draft.id) }
            } catch {
                sendFailure = error.localizedDescription
            }
        }

        heldTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled else { return }
            await self?.sendHeldNow()
        }
    }

    /// Called off. It was never sent, so there is nothing to undo on Gmail's
    /// side and nothing to explain to anybody.
    func cancelHeldSend() {
        heldTimer?.cancel()
        heldTimer = nil
        heldWork = nil
        heldSend = nil
        Analytics.record(.sendUndone)
    }

    /// Sends what is waiting, now, without seeing out the window.
    ///
    /// Called when the timer runs out, when a second message is sent, and
    /// when the app goes away. Backgrounding is not a decision to abandon a
    /// message: dropping it there would lose something somebody wrote and
    /// believed had gone.
    func sendHeldNow() {
        guard let work = heldWork else { return }
        heldTimer?.cancel()
        heldTimer = nil
        heldWork = nil
        heldSend = nil

        // The usual reason this is called is the app going away, and a
        // suspended app does not finish an upload. Asking for the time turns
        // "probably sent" into sent.
        let assertion = BackgroundAssertion(named: "send")

        Task {
            await work()
            assertion.end()
        }
    }
}

/// A request for a few more seconds after the app leaves the screen.
///
/// A class rather than a local variable so the expiry handler and the send
/// share one identifier -- ending it twice is a crash, and never ending it
/// is how an app gets killed for holding time it stopped using.
@MainActor
private final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(named name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
