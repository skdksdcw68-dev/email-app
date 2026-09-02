import Foundation

/// One thing an email committed somebody to.
///
/// "Send the revised quote by Friday." "I'll have the contract over
/// Monday." "Does Thursday work?" "Board meeting on the 11th." The tags say
/// how much a message matters; this says what is actually in it, in a form
/// the app can sort, date and cross off -- which is what "what am I waiting
/// on" and "what did I promise" need, and what no amount of re-reading forty
/// digests on every question could give reliably.
///
/// Read out of the message by the second tier of the classifier and kept on
/// the phone only. It is mail content, so it goes with the mailbox.
struct Fact: Identifiable, Codable, Equatable, Hashable {

    enum Kind: String, Codable, CaseIterable {
        /// Somebody wants something done or sent.
        case request
        /// Somebody said they would do something.
        case commitment
        /// A question left open, that is not a request to do anything.
        case question
        /// An event or deadline with a day attached.
        case date
    }

    /// Whose move it is.
    enum Party: String, Codable {
        case me
        case them
    }

    var id = UUID()
    var kind: Kind
    /// For a date, the party it concerns rather than owes: always `me`.
    var owedBy: Party
    /// Short, verb first for requests and commitments. What the model wrote.
    var text: String
    /// The day it is wanted by, or the day it happens. Nil when the email
    /// named none; the app never guesses one.
    var due: Date?
    /// The other person in it. Who asked, who promised, who is waiting.
    var person: Contact
    /// Gmail's id for the message it came from, so it can be opened.
    var messageID: String
    var threadID: String?
    /// When the email was written. Ages the fact, and decides whether a later
    /// message in the thread is a reply to it.
    var date: Date
    var isDone = false

    var isOnMe: Bool { owedBy == .me }

    /// Past its day. A request due Friday is overdue on Saturday; a date is
    /// simply gone by then, which `FactStore.reconcile` treats as done.
    func isOverdue(now: Date = .now) -> Bool {
        guard let due, kind != .date else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: now)
    }

    /// One line for the model, from the reader's side of the conversation.
    /// `number` is the message's place in the list the model was given, when
    /// it was given; the model can only show a card for a numbered one.
    func describe(number: Int?, now: Date = .now) -> String {
        let who = person.name.isEmpty ? person.address : person.name
        let written = date.formatted(.dateTime.day().month(.abbreviated))
        let when = due.map { Self.dayPhrase($0, now: now) }

        var line: String
        switch (kind, owedBy) {
        case (.request, .me):
            line = "On you: \(text). \(who) asked on \(written)"
        case (.request, .them):
            line = "On them: \(who) was asked to \(lowercasedFirst(text)), on \(written)"
        case (.commitment, .me):
            line = "On you: you said you would \(lowercasedFirst(text)), to \(who) on \(written)"
        case (.commitment, .them):
            line = "On them: \(who) said they would \(lowercasedFirst(text)), on \(written)"
        case (.question, .me):
            line = "On you: \(who) asked \"\(text)\" on \(written), still unanswered"
        case (.question, .them):
            line = "On them: you asked \(who) \"\(text)\" on \(written), no answer yet"
        case (.date, _):
            line = "Date: \(text), with \(who)"
        }

        if let when {
            line += kind == .date ? ", \(when)" : ", due \(when)"
            if isOverdue(now: now) { line += " (overdue)" }
        }
        if let number { line += " [\(number)]" }
        return line
    }

    /// "Fri 4 Sep", with "today" and "tomorrow" where they apply, so the
    /// model does not have to work out what day it is from a date.
    static func dayPhrase(_ day: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(day, inSameDayAs: tomorrow) { return "tomorrow" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// What the second tier read out of one message, from the email's own point
/// of view: the writer and the reader. Which of those is "me" depends on
/// whether the message was sent or received, and only the app knows that.
struct Extraction: Decodable, Equatable {
    struct Item: Decodable, Equatable {
        var what: String
        var due: String?
        var on: String?
    }

    var requests: [Item] = []
    var commitments: [Item] = []
    var questions: [String] = []
    var dates: [Item] = []

    init(requests: [Item] = [], commitments: [Item] = [], questions: [String] = [], dates: [Item] = []) {
        self.requests = requests
        self.commitments = commitments
        self.questions = questions
        self.dates = dates
    }

    /// A list the server left out is an empty list, not a failed read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requests = try container.decodeIfPresent([Item].self, forKey: .requests) ?? []
        commitments = try container.decodeIfPresent([Item].self, forKey: .commitments) ?? []
        // Asked for as plain strings; a model that wraps them in objects
        // anyway has still answered.
        if let plain = try? container.decodeIfPresent([String].self, forKey: .questions) {
            questions = plain
        } else {
            questions = (try container.decodeIfPresent([Item].self, forKey: .questions) ?? []).map(\.what)
        }
        dates = try container.decodeIfPresent([Item].self, forKey: .dates) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case requests, commitments, questions, dates
    }

    var isEmpty: Bool {
        requests.isEmpty && commitments.isEmpty && questions.isEmpty && dates.isEmpty
    }

    /// Turned around to the reader's side.
    ///
    /// Received: their requests and questions land on me, their commitments
    /// are on them. Sent: what I asked for is on them, what I promised is on
    /// me. The other person is the sender when it came in and the first
    /// recipient when it went out.
    func facts(for message: Message, myAddress: String) -> [Fact] {
        guard let remoteID = message.remoteID else { return [] }

        let mine = myAddress.lowercased()
        let sentByMe = message.mailbox == .sent || message.sender.address.lowercased() == mine
        let person = sentByMe
            ? (message.recipients.first { $0.address.lowercased() != mine } ?? message.sender)
            : message.sender

        func make(_ kind: Fact.Kind, _ owedBy: Fact.Party, _ text: String, _ day: String?) -> Fact? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".;"))
            guard trimmed.count >= 3 else { return nil }
            return Fact(
                kind: kind,
                owedBy: owedBy,
                text: String(trimmed.prefix(160)),
                due: day.flatMap(Self.day),
                person: person,
                messageID: remoteID,
                threadID: message.threadID,
                date: message.date
            )
        }

        var facts: [Fact] = []
        for item in requests.prefix(4) {
            facts += [make(.request, sentByMe ? .them : .me, item.what, item.due)].compactMap { $0 }
        }
        for item in commitments.prefix(4) {
            facts += [make(.commitment, sentByMe ? .me : .them, item.what, item.due)].compactMap { $0 }
        }
        for question in questions.prefix(4) {
            facts += [make(.question, sentByMe ? .them : .me, question, nil)].compactMap { $0 }
        }
        for item in dates.prefix(4) {
            // A date the model could not pin to a day is not a date.
            guard let on = item.on, Self.day(on) != nil else { continue }
            facts += [make(.date, .me, item.what, on)].compactMap { $0 }
        }
        return facts
    }

    /// "2026-09-04" as the start of that day, in the device's own calendar.
    /// Anything else is nil rather than a guess.
    static func day(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }
}
