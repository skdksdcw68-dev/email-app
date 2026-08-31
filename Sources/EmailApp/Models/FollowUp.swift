import Foundation

/// A conversation that is waiting on somebody.
///
/// Two directions, and they are not the same problem. "Waiting on you" is a
/// to-do list. "Waiting on them" is the one people actually lose track of --
/// you asked for something a fortnight ago and never heard back, and nothing
/// in a normal inbox reminds you of that, because the last thing that happened
/// is your own message and it is buried in Sent.
struct FollowUp: Identifiable, Equatable {
    enum Direction: Equatable {
        case waitingOnYou
        case waitingOnThem
    }

    let id: String
    let direction: Direction
    let message: Message
    /// Days since the last thing happened in this conversation.
    let age: Int

    /// Chased once a week is a reasonable default before something reads as
    /// forgotten rather than merely recent.
    var isOverdue: Bool { direction == .waitingOnThem && age >= 7 }

    var ageDescription: String {
        switch age {
        case ..<1: "today"
        case 1: "yesterday"
        case 2...6: "\(age) days ago"
        case 7...13: "last week"
        default: "\(age / 7) weeks ago"
        }
    }
}

extension Array where Element == Message {
    /// Conversations that need chasing, newest problem first.
    ///
    /// A thread is "waiting on them" when the newest message in it is one the
    /// user sent, and "waiting on you" when it came in and the classifier said
    /// it wants a reply. Anything the user has already replied to drops out on
    /// its own, because their reply becomes the newest message in the thread.
    func followUps(myAddress: String, now: Date = .now) -> [FollowUp] {
        // Newest message per conversation is the whole basis of this: the last
        // thing that happened decides who the ball is with.
        var newestByThread: [String: Message] = [:]
        for message in self {
            let key = message.threadID ?? message.id.uuidString
            if let existing = newestByThread[key], existing.date >= message.date { continue }
            newestByThread[key] = message
        }

        let mine = myAddress.lowercased()
        var results: [FollowUp] = []

        for (key, message) in newestByThread {
            let days = Calendar.current.dateComponents(
                [.day], from: message.date, to: now
            ).day ?? 0

            let isFromMe = message.sender.address.lowercased() == mine
                || message.mailbox == .sent

            if isFromMe {
                // Only worth surfacing once it has gone quiet for a bit --
                // everything sent today would otherwise be a "follow-up".
                guard days >= 3 else { continue }
                results.append(
                    FollowUp(id: key, direction: .waitingOnThem, message: message, age: days)
                )
            } else if message.tags.contains(.needsReply), message.mailbox == .inbox {
                results.append(
                    FollowUp(id: key, direction: .waitingOnYou, message: message, age: days)
                )
            }
        }

        // Overdue first, then oldest, so the most neglected thing is on top.
        return results.sorted { left, right in
            if left.isOverdue != right.isOverdue { return left.isOverdue }
            return left.age > right.age
        }
    }
}
