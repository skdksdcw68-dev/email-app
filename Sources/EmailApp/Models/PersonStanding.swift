import Foundation

/// Where things stand with one person, in one object.
///
/// "What's happening with Sara" is a question the app could only answer by
/// handing the model a dozen of Sara's emails and hoping. Everything it
/// actually needs is already worked out and sitting in three different
/// places: who she is (`Person`), what the mail committed either of you to
/// (`FactStore`), and whose move it is (`FollowUp`). This is the join.
///
/// Assembled on the device from things it already holds, so asking about
/// somebody costs a paragraph in the prompt rather than a search.
struct PersonStanding: Equatable {

    let person: Person
    /// Things they asked for, or you promised them, that are still open.
    let onMe: [Fact]
    /// Things you asked for, or they promised, still open.
    let onThem: [Fact]
    /// Dated things involving them that have not passed.
    let coming: [Fact]
    /// Conversations waiting on somebody, either way.
    let waiting: [FollowUp]

    var name: String {
        person.contact.name.isEmpty ? person.contact.address : person.contact.name
    }

    /// Whether there is anything to say beyond who they are.
    var hasOutstanding: Bool {
        !onMe.isEmpty || !onThem.isEmpty || !coming.isEmpty || !waiting.isEmpty
    }

    /// One line for a row: the most useful thing about them right now.
    var headline: String {
        if let first = onMe.first { return first.text }
        if !waiting.filter({ $0.direction == .waitingOnYou }).isEmpty {
            return "Waiting on your reply"
        }
        if let promised = onThem.first { return "They owe you: \(promised.text)" }
        if let next = coming.first, let due = next.due {
            return "\(next.text), \(Fact.dayPhrase(due))"
        }
        return person.lastContactedDescription
    }

    // MARK: - For the model

    /// Everything known about them, as prose the model reads instead of a
    /// dozen of their emails.
    ///
    /// Deliberately compact. This is background: it says who somebody is and
    /// what is outstanding, so the model does not have to work that out from
    /// the mail every time it is asked. Anything it needs to quote is still
    /// in the messages.
    func described(now: Date = .now) -> String {
        var lines = ["\(name) <\(person.contact.address)>"]

        var identity = [person.relationshipTitle]
        if let organization = person.organization { identity.append("at \(organization)") }
        if person.isImportant { identity.append("marked important by them") }
        if person.isMuted { identity.append("muted") }
        lines.append("- Who: " + identity.joined(separator: ", "))

        lines.append(
            "- History: \(person.messageCount) messages across \(person.conversationCount) conversations, "
            + "last \(person.lastContactedDescription.lowercased())"
        )

        if !onMe.isEmpty {
            lines.append("- On you:")
            lines += onMe.prefix(4).map { "  - " + $0.describe(number: nil, now: now) }
        }
        if !onThem.isEmpty {
            lines.append("- On them:")
            lines += onThem.prefix(4).map { "  - " + $0.describe(number: nil, now: now) }
        }
        if !coming.isEmpty {
            lines.append("- Coming up:")
            lines += coming.prefix(3).map { "  - " + $0.describe(number: nil, now: now) }
        }
        if !waiting.isEmpty {
            let onYou = waiting.filter { $0.direction == .waitingOnYou }.count
            let onThem = waiting.count - onYou
            var parts: [String] = []
            if onYou > 0 { parts.append("\(onYou) waiting on your reply") }
            if onThem > 0 { parts.append("\(onThem) you sent that went quiet") }
            lines.append("- Conversations: " + parts.joined(separator: ", "))
        }

        return lines.joined(separator: "\n")
    }
}

extension MailStore {

    /// Where things stand with one person, or nil when they are a stranger.
    func standing(for address: String, now: Date = .now) -> PersonStanding? {
        let wanted = address.lowercased()
        guard let person = people.first(where: { $0.contact.address.lowercased() == wanted }) else {
            return nil
        }
        return standing(for: person, now: now)
    }

    func standing(for person: Person, now: Date = .now) -> PersonStanding {
        let wanted = person.contact.address.lowercased()
        let theirs = facts.open.filter { $0.person.address.lowercased() == wanted }

        return PersonStanding(
            person: person,
            onMe: theirs.filter { $0.isOnMe && $0.kind != .date },
            onThem: theirs.filter { !$0.isOnMe && $0.kind != .date },
            coming: theirs.filter { $0.kind == .date }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) },
            waiting: followUps.filter {
                $0.message.sender.address.lowercased() == wanted
                    || $0.message.recipients.contains { $0.address.lowercased() == wanted }
            }
        )
    }

    /// The people a question is plainly about, by name or address.
    ///
    /// Deliberately narrow: a first name that matches somebody they write to
    /// is worth a paragraph of background, and everything else is not. This
    /// is not intent detection, it is looking up a name the person typed --
    /// the model still decides what the question means.
    func peopleMentioned(in question: String, limit: Int = 2) -> [PersonStanding] {
        let lowered = question.lowercased()
        guard lowered.count >= 3 else { return [] }

        let matches = people.filter { person in
            let address = person.contact.address.lowercased()
            if lowered.contains(address) { return true }

            // First names only, and only ones long enough to be a name
            // rather than a word. "Sam" counts; "Jo" would match "job".
            let name = person.contact.name.lowercased()
            guard !name.isEmpty, !name.contains("@") else { return false }
            return name.split(separator: " ")
                .filter { $0.count >= 3 }
                .contains { part in
                    lowered.range(of: "\\b\(NSRegularExpression.escapedPattern(for: String(part)))\\b",
                                  options: .regularExpression) != nil
                }
        }

        // The ones with something outstanding first: if two names match, the
        // one somebody is actually waiting on is the one worth the room.
        return matches
            .map { standing(for: $0) }
            .sorted { left, right in
                if left.hasOutstanding != right.hasOutstanding { return left.hasOutstanding }
                return left.person.lastContacted > right.person.lastContacted
            }
            .prefix(limit)
            .map { $0 }
    }
}

extension MailStore {

    /// The last few messages of a conversation, oldest first, as prose.
    ///
    /// Enough for a reply to sound like it belongs to the thread rather than
    /// arriving from nowhere. Three, because a reply written from the whole
    /// history of a long thread starts answering questions that were settled
    /// two months ago.
    func threadSummary(for message: Message, limit: Int = 3) -> String {
        guard let thread = message.threadID else { return "" }
        return messages
            .filter { $0.threadID == thread && $0.id != message.id }
            .sorted { $0.date < $1.date }
            .suffix(limit)
            .map { earlier in
                let who = earlier.sender.name.isEmpty ? earlier.sender.address : earlier.sender.name
                return "\(who) wrote on \(earlier.fullDate):\n\(earlier.body.prefix(400))"
            }
            .joined(separator: "\n\n")
    }
}
