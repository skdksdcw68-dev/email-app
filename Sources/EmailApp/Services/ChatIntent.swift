import Foundation

/// What the person meant, decided on the device before anything is spent.
///
/// This is the top of the assistant's decision ladder. Saying "hi" must not
/// come back as a list of tagged emails; "send it" while a draft is waiting
/// must send it; "reply to Sara saying Thursday works" must produce a draft,
/// not an answer. Only what is left over is a question for the mailbox or
/// the model.
enum ChatIntent: Equatable {
    enum Greeting: Equatable {
        case hello
        case thanks
        case acknowledgement
    }

    /// "hi", "thanks", "ok". Answered warmly, with no email in it.
    case greeting(Greeting)
    /// "send it", "yes", "go ahead" while a draft is waiting.
    case sendPendingDraft
    /// "no", "cancel", "don't send" while a draft is waiting.
    case discardPendingDraft
    /// "reply to Sara saying Thursday works", "write an email to Tom".
    case draft(DraftRequest)
    /// "mark these as read", "mark the newsletters read".
    case markRead(MarkReadRequest)
    /// Everything else: a question about the mailbox.
    case question
}

/// Which mail to mark read.
///
/// The only thing Maily can change about a message without `gmail.modify`,
/// and the one the person asks for most: having read something in the app,
/// they do not want to be told about it again.
struct MarkReadRequest: Equatable {
    /// A named pile: "mark the newsletters as read".
    let tag: AITag?
    /// "mark everything as read".
    let isEverything: Bool
    /// Nothing named at all, so it means whatever was just listed.
    var isImplicit: Bool { tag == nil && !isEverything }
}

struct DraftRequest: Equatable {
    /// What to say, when they said it. Nil means "answer what was asked".
    let instruction: String?
    /// Words that might identify who or which email: a name, a subject word.
    let hints: [String]
    /// Which one, when Maily has just offered a list. 1-based; -1 is latest.
    let ordinal: Int?
    /// A fresh email rather than a reply to something received.
    let isNewEmail: Bool
}

enum ChatIntentParser {

    static func parse(_ raw: String, hasPendingDraft: Bool) -> ChatIntent {
        let text = normalize(raw)
        guard !text.isEmpty else { return .question }

        if hasPendingDraft {
            if sendPhrases.contains(text) { return .sendPendingDraft }
            if discardPhrases.contains(text) { return .discardPendingDraft }
        }
        if let greeting = greeting(in: text) { return .greeting(greeting) }
        // Before drafting: "mark it as read" opens with no command verb, but
        // "mark the reply from Sara as read" would otherwise trip the reply
        // verb and start writing an email nobody asked for.
        if let request = markReadRequest(in: text) { return .markRead(request) }
        if let request = draftRequest(in: text) { return .draft(request) }
        return .question
    }

    // MARK: - Marking read

    /// "mark them as read", "mark the newsletters read", "mark all read".
    ///
    /// Deliberately narrow. Everything here says the word "mark", because
    /// "read the newsletters" means something else entirely and guessing
    /// wrong changes the person's inbox.
    private static func markReadRequest(in text: String) -> MarkReadRequest? {
        guard text.contains("mark") else { return nil }
        guard text.contains("read") || text.contains("seen") else { return nil }
        // "mark it as unread" is the opposite request, and not one anybody
        // has asked for out loud yet.
        guard !text.contains("unread") else { return nil }

        let everything = ["all", "everything", "every one", "the whole", "inbox"]
            .contains { text.contains($0) }

        return MarkReadRequest(
            tag: AITag.named(in: text),
            isEverything: everything
        )
    }

    /// "yes", "go on", "show me" -- an acceptance of something just offered.
    ///
    /// Separate from `sendPhrases`, which answers a waiting draft and means
    /// something irreversible. This one only means "do the thing you just
    /// suggested", so it can afford to be generous.
    static func isAffirmative(_ raw: String) -> Bool {
        let text = normalize(raw)
        return affirmatives.contains(text)
    }

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "ya", "sure", "ok", "okay", "k",
        "yes please", "please", "please do", "go on", "go ahead", "do it",
        "show me", "show them", "show me them", "let's see", "lets see",
        "sounds good", "why not", "alright", "all right", "of course", "definitely",
    ]

    /// A bare answer to "which one?" -- "Drobe", "the second one", "the one
    /// from Sara" -- read as the words that pick, plus any ordinal.
    static func selection(_ raw: String) -> (hints: [String], ordinal: Int?) {
        let text = normalize(raw)
        return (hints(in: text), ordinal(in: text))
    }

    // MARK: - Normalising

    /// Lowercased, trimmed, trailing punctuation gone, spaces collapsed.
    /// Apostrophes inside words stay, so "don't" survives.
    private static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmed = Substring(lowered)
        while let last = trimmed.last, ".!?,;:".contains(last) { trimmed.removeLast() }
        return trimmed.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Greetings

    private static let hellos: [String] = [
        "hi", "hello", "hey", "yo", "hiya", "howdy", "sup", "whats up", "what's up",
        "good morning", "good afternoon", "good evening", "morning", "evening",
        "how are you", "how are you doing", "how's it going", "hows it going",
        "you there", "are you there", "hey there", "hi there", "hello there",
    ]

    private static let thanks: [String] = [
        "thanks", "thank you", "thx", "ty", "cheers", "thanks a lot",
        "thank you so much", "appreciate it", "nice one", "thanks man",
    ]

    private static let acknowledgements: [String] = [
        "ok", "okay", "cool", "nice", "great", "perfect", "got it", "alright",
        "k", "sounds good", "fine", "good", "sweet", "awesome",
    ]

    /// Words that can follow a greeting without changing what it is.
    private static let fillers: Set<String> = [
        "maily", "there", "man", "bro", "dude", "mate", "friend", "buddy",
        "again", "please", "so", "much", "a", "lot", "you", "too",
    ]

    private static func greeting(in text: String) -> ChatIntent.Greeting? {
        // A real question is never this short and this empty.
        guard text.count <= 32 else { return nil }
        if let exact = exactGreeting(text) { return exact }

        let groups: [([String], ChatIntent.Greeting)] = [
            (hellos, .hello), (thanks, .thanks), (acknowledgements, .acknowledgement),
        ]
        for (phrases, kind) in groups {
            for phrase in phrases where text.hasPrefix(phrase + " ") {
                let rest = String(text.dropFirst(phrase.count + 1))
                let words = rest.split(separator: " ").map(String.init)
                if exactGreeting(rest) != nil || words.allSatisfy(fillers.contains) {
                    return kind
                }
            }
        }
        return nil
    }

    private static func exactGreeting(_ text: String) -> ChatIntent.Greeting? {
        if hellos.contains(text) { return .hello }
        if thanks.contains(text) { return .thanks }
        if acknowledgements.contains(text) { return .acknowledgement }
        return nil
    }

    // MARK: - A waiting draft

    private static let sendPhrases: Set<String> = [
        "send", "send it", "yes", "yes send", "yes send it", "go ahead", "send that",
        "ok send", "ok send it", "okay send", "okay send it", "do it", "looks good",
        "looks good send it", "ship it", "send now", "send the email", "send the reply",
        "send this", "yep", "yeah", "yes please", "sure", "confirm", "go",
        "good send it", "perfect send it", "send it please", "please send", "please send it",
    ]

    private static let discardPhrases: Set<String> = [
        "no", "nope", "don't send", "dont send", "don't send it", "dont send it",
        "cancel", "discard", "scrap it", "forget it", "no don't", "not that",
        "delete it", "drop it", "never mind", "nevermind", "no thanks", "stop",
    ]

    // MARK: - Draft requests

    /// Politeness and warm-up words that carry no meaning of their own.
    private static let politePrefixes: [String] = [
        "can you", "could you", "would you", "will you", "please", "pls",
        "hey maily", "hi maily", "maily", "i want you to", "i need you to",
        "i want to", "i need to", "help me", "go ahead and", "just", "now",
        "ok", "okay", "also", "and", "then",
    ]

    /// Anything that opens like a question is one, however many verbs follow.
    /// "what should I reply to Sara" wants an answer, not a draft.
    private static let questionOpeners: [String] = [
        "what", "who", "whom", "which", "when", "where", "why", "how", "is", "are",
        "am", "do", "does", "did", "should", "show", "list", "find", "search",
        "summarise", "summarize", "any", "anything", "give me", "tell me",
    ]

    /// Longest first, so "write back to" wins over "write". The flag says
    /// whether the verb means a fresh email rather than a reply.
    private static let commandVerbs: [(verb: String, isNewEmail: Bool)] = [
        ("write back to", false), ("write a reply to", false), ("write a reply", false), ("write back", false),
        ("write a new email to", true), ("write an email to", true), ("write a mail to", true),
        ("write a message to", true), ("write to", true), ("write", false),
        ("reply to", false), ("reply", false), ("respond to", false), ("respond", false),
        ("answer", false), ("get back to", false),
        ("draft a reply to", false), ("draft a reply", false), ("draft a new email to", true),
        ("draft an email to", true), ("draft an email", true), ("draft a message to", true), ("draft", false),
        ("compose a new email to", true), ("compose an email to", true), ("compose", true),
        ("send a reply to", false), ("send a reply", false), ("send a new email to", true),
        ("send an email to", true), ("send a message to", true), ("send a mail to", true),
        // "Send me an email for App Store Connect": the person wants one
        // written, not sent to themselves.
        ("send me an email", true), ("send me a mail", true), ("send me a message", true),
        ("write me an email", true), ("write me a mail", true), ("draft me an email", true),
        ("make an email", true), ("create an email", true), ("write an email", true),
        ("write a mail", true), ("send an email", true), ("write email to", true),
        ("send email to", true), ("draft email to", true),
        ("email", true), ("message", true), ("tell", false), ("let", false),
    ]

    private static let orderedVerbs = commandVerbs.sorted { $0.verb.count > $1.verb.count }

    /// Where the target ends and what-to-say begins.
    private static let instructionSeparators: [String] = [
        " saying that ", " saying ", " telling them that ", " telling him that ", " telling her that ",
        " telling them ", " telling him ", " telling her ", " to say that ", " to say ",
        " and say that ", " and say ", " to tell them ", " to tell him ", " to tell her ",
        " that ", " asking ", " and ask ", ": ",
    ]

    /// Words in the target part that do not help identify anybody.
    private static let stopWords: Set<String> = [
        "the", "one", "this", "that", "him", "her", "them", "his", "their", "about",
        "email", "mail", "message", "from", "with", "and", "for", "please", "latest",
        "last", "first", "second", "third", "fourth", "newest", "recent", "new",
        "reply", "again", "back", "guy", "person", "who", "sent", "wrote", "today",
        "yesterday", "know", "quickly", "quick", "short", "nice", "politely", "warmly",
        "an", "a", "to", "it", "its", "of", "in", "on", "regarding", "re",
    ]

    private static func draftRequest(in text: String) -> DraftRequest? {
        var t = text
        var stripped = true
        while stripped {
            stripped = false
            for prefix in politePrefixes where t.hasPrefix(prefix + " ") {
                t = String(t.dropFirst(prefix.count + 1))
                stripped = true
            }
        }

        if questionOpeners.contains(where: { t == $0 || t.hasPrefix($0 + " ") }) { return nil }

        guard let command = orderedVerbs.first(where: { t == $0.verb || t.hasPrefix($0.verb + " ") }) else {
            return nil
        }

        let rest = String(t.dropFirst(command.verb.count)).trimmingCharacters(in: .whitespaces)
        let (targetPart, instruction) = split(rest)

        return DraftRequest(
            instruction: instruction,
            hints: hints(in: targetPart),
            ordinal: ordinal(in: targetPart),
            isNewEmail: command.isNewEmail && !t.contains("reply") && !t.contains("back")
        )
    }

    /// "sara that thursday works" -> ("sara", "thursday works"). The earliest
    /// separator wins, so "tell sara that the thing that broke is fixed" cuts
    /// at the first "that".
    private static func split(_ rest: String) -> (target: String, instruction: String?) {
        let padded = " " + rest + " "
        var best: (range: Range<String.Index>, separator: String)?
        for separator in instructionSeparators {
            guard let range = padded.range(of: separator) else { continue }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (range, separator)
            }
        }
        guard let best else {
            return (rest, nil)
        }
        let target = String(padded[..<best.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let instruction = String(padded[best.range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (target, instruction.isEmpty ? nil : instruction)
    }

    private static func ordinal(in target: String) -> Int? {
        let words = Set(target.split(separator: " ").map(String.init))
        if words.contains("first") { return 1 }
        if words.contains("second") { return 2 }
        if words.contains("third") { return 3 }
        if words.contains("fourth") { return 4 }
        if !words.isDisjoint(with: ["last", "latest", "newest", "recent"]) { return -1 }
        return nil
    }

    private static func hints(in target: String) -> [String] {
        target
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }
}
