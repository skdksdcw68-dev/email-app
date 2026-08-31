import Foundation

/// A correspondent, assembled from their messages.
///
/// Everything here is computed locally from mail already held. None of it
/// costs an API call, which is what makes it reasonable to show for a hundred
/// people at once -- only the written summary on a person's own screen ever
/// reaches the model.
struct Person: Identifiable, Equatable {
    let contact: Contact
    let category: PersonCategory
    /// How many messages, in either direction.
    let messageCount: Int
    /// Distinct conversations, which is a truer measure of a relationship than
    /// a raw message count -- one long thread is not twelve relationships.
    let conversationCount: Int
    /// Messages from them still tagged as needing a reply.
    let awaitingReply: Int
    /// How many of the conversations they started.
    let theyStarted: Int
    let youStarted: Int
    let lastContacted: Date
    let isImportant: Bool
    let isMuted: Bool
    /// Their company, where the address implies one.
    let organization: String?

    var id: String { contact.address }

    var lastContactedDescription: String {
        let days = Calendar.current.dateComponents([.day], from: lastContacted, to: .now).day ?? 0
        switch days {
        case ..<1: "Today"
        case 1: "Yesterday"
        case 2...29: "\(days) days ago"
        default: "\(max(1, days / 30)) months ago"
        }
    }

    /// Who tends to start things. Nil when it is too close, or when there is
    /// not enough history to say anything honest.
    var initiator: String? {
        let total = theyStarted + youStarted
        guard total >= 3 else { return nil }
        if theyStarted >= youStarted * 2 { return "They usually reach out first" }
        if youStarted >= theyStarted * 2 { return "You usually reach out first" }
        return nil
    }
}

extension Array where Element == Message {
    /// Everyone in this mail, busiest and most-neglected first.
    ///
    /// `myAddress` decides which side of a conversation is the user, which is
    /// what makes "who started it" answerable at all -- and only became
    /// possible once Sent mail was imported.
    func people(myAddress: String) -> [Person] {
        let mine = myAddress.lowercased()
        let myDomain = mine.split(separator: "@").last.map(String.init)

        // Group by the other party, whichever direction the message went.
        var byAddress: [String: [Message]] = [:]
        for message in self {
            let isFromMe = message.sender.address.lowercased() == mine || message.mailbox == .sent
            let other = isFromMe
                ? message.recipients.first?.address
                : message.sender.address
            guard let other, !other.isEmpty, other.lowercased() != mine else { continue }
            byAddress[other.lowercased(), default: []].append(message)
        }

        return byAddress.compactMap { address, messages -> Person? in
            guard let newest = messages.max(by: { $0.date < $1.date }) else { return nil }

            // Prefer a real display name over a bare address, whichever
            // message happens to carry one.
            let named = messages.first { !$0.sender.name.contains("@") && $0.sender.address.lowercased() == address }
            let contact = named?.sender
                ?? messages.first { $0.sender.address.lowercased() == address }?.sender
                ?? Contact(name: address, address: address)

            let isBulk = messages.contains { $0.tags.contains(.newsletter) || $0.tags.contains(.promotion) }
            let category = PersonPreferences.category(for: address)
                ?? PersonCategory.inferred(for: address, myDomain: myDomain, isBulk: isBulk)

            // Who opened each conversation: the oldest message in each thread.
            var openers: [String: Message] = [:]
            for message in messages {
                let key = message.threadID ?? message.id.uuidString
                if let existing = openers[key], existing.date <= message.date { continue }
                openers[key] = message
            }
            let theyStarted = openers.values.filter {
                $0.sender.address.lowercased() == address
            }.count

            return Person(
                contact: contact,
                category: category,
                messageCount: messages.count,
                conversationCount: openers.count,
                awaitingReply: messages.filter {
                    $0.tags.contains(.needsReply) && $0.mailbox == .inbox
                }.count,
                theyStarted: theyStarted,
                youStarted: openers.count - theyStarted,
                lastContacted: newest.date,
                isImportant: PersonPreferences.isImportant(address),
                isMuted: PersonPreferences.isMuted(address),
                organization: organization(from: address, myDomain: myDomain)
            )
        }
        .sorted { left, right in
            if left.isImportant != right.isImportant { return left.isImportant }
            if left.awaitingReply != right.awaitingReply { return left.awaitingReply > right.awaitingReply }
            return left.lastContacted > right.lastContacted
        }
    }

    /// "stripe.com" reads as Stripe. Consumer domains say nothing about who
    /// somebody works for, so they get nothing rather than "Gmail".
    private func organization(from address: String, myDomain: String?) -> String? {
        guard let domain = address.lowercased().split(separator: "@").last.map(String.init),
              domain.contains("."),
              PersonCategory.inferred(for: address, myDomain: myDomain) != .personal
        else { return nil }

        let name = domain.split(separator: ".").first.map(String.init) ?? domain
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
