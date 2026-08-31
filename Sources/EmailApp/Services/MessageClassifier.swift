import Foundation

/// Tags a message using rules only -- no model, no API call, no cost.
///
/// This is deliberately the first half of the priority engine. Four of the five
/// signals a hybrid scorer needs (sender, deadline language, bulk-mail headers,
/// user marks) are available locally; only "how important does this *read*"
/// needs a model. Building the rules first means the app works before any AI
/// spend, and gives a fallback for when the model is slow, down or rate-limited.
///
/// It also short-circuits the largest bucket: anything with a List-Unsubscribe
/// header is bulk mail and never needs a model to say so.
enum MessageClassifier {

    static func tags(for message: Message, headers: [String: String], labels: Set<String>) -> Set<AITag> {
        var tags: Set<AITag> = []

        // What sort of thing it is, which is worth knowing even for bulk mail
        // that stops at the short-circuit below.
        if let kind = kind(for: message, headers: headers, labels: labels) {
            tags.insert(kind)
        }

        if isBulk(headers: headers, labels: labels, sender: message.sender.address) {
            tags.insert(.noReplyNeeded)
            return tags
        }

        var signals: Set<AITag> = []
        let haystack = "\(message.subject) \(message.body.prefix(600))".lowercased()

        if wantsReply(subject: message.subject, body: message.body, haystack: haystack) {
            signals.insert(.needsReply)
        }

        switch score(message: message, labels: labels, haystack: haystack) {
        case 55...: signals.insert(.urgent)
        case 35..<55: signals.insert(.veryImportant)
        case 18..<35: signals.insert(.important)
        default: break
        }

        // Nothing stood out and nobody is waiting: say so rather than leaving
        // it blank, so the inbox is fully triaged. A kind tag does not count
        // here -- "Newsletter" says what a thing is, not whether it is dealt
        // with, and a message showing only a kind would sit in no status
        // filter at all.
        if signals.isEmpty { signals.insert(.noReplyNeeded) }
        return tags.union(signals)
    }

    // MARK: - Kind

    /// Security first, because a sign-in alert that also carries marketing
    /// footer text is a security mail; promotion before newsletter, because
    /// almost every promotion is also technically a bulk send.
    static func kind(for message: Message, headers: [String: String], labels: Set<String>) -> AITag? {
        let haystack = "\(message.subject) \(message.body.prefix(600))".lowercased()
        let sender = message.sender.address.lowercased()

        if securityWords.contains(where: haystack.contains) || sender.contains("accounts.google.com") {
            return .security
        }
        if financeWords.contains(where: haystack.contains) { return .finance }
        if meetingWords.contains(where: haystack.contains) { return .meeting }

        if labels.contains("CATEGORY_PROMOTIONS") { return .promotion }
        if promotionWords.contains(where: haystack.contains) { return .promotion }

        if headers["list-unsubscribe"] != nil { return .newsletter }
        if newsletterWords.contains(where: haystack.contains) { return .newsletter }

        return nil
    }

    private static let securityWords = [
        "security alert", "new sign-in", "new sign in", "signed in", "sign-in attempt",
        "suspicious activity", "verification code", "verify your", "reset your password",
        "password was changed", "two-factor", "2-step", "new device",
        "unusual activity", "was blocked",
    ]

    private static let financeWords = [
        "invoice", "receipt", "payment", "billing", "billed", "charged",
        "refund", "transaction", "payout", "balance due", "subscription renews",
        "renewal", "your order", "purchase", "paid",
    ]

    private static let meetingWords = [
        "meeting", "calendar", "invitation:", "invited you", "reschedul",
        "appointment", "zoom.us", "meet.google.com", "teams.microsoft.com",
        "are you free", "book a time", "schedule a call",
    ]

    private static let promotionWords = [
        "% off", "sale", "discount", "deal", "offer ends", "shop now",
        "limited time", "save big", "coupon", "promo code", "black friday",
        "free trial", "upgrade now",
    ]

    private static let newsletterWords = [
        "newsletter", "digest", "roundup", "this week", "weekly", "daily",
        "issue #", "unsubscribe",
    ]

    // MARK: - Bulk

    /// RFC 8058 says bulk senders must offer List-Unsubscribe, which makes it
    /// the single most reliable newsletter signal there is.
    static func isBulk(headers: [String: String], labels: Set<String>, sender: String) -> Bool {
        if headers["list-unsubscribe"] != nil { return true }
        if headers["precedence"]?.lowercased() == "bulk" { return true }

        let bulkCategories: Set<String> = [
            "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL", "CATEGORY_FORUMS",
        ]
        if !labels.isDisjoint(with: bulkCategories) { return true }

        let address = sender.lowercased()
        return ["noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon"]
            .contains { address.contains($0) }
    }

    // MARK: - Reply

    private static let askPhrases = [
        "can you", "could you", "would you", "are you able",
        "let me know", "please confirm", "please review", "please send",
        "what do you think", "your thoughts", "waiting for", "waiting on",
        "get back to me", "thoughts?", "any update",
    ]

    static func wantsReply(subject: String, body: String, haystack: String) -> Bool {
        if subject.contains("?") { return true }
        if askPhrases.contains(where: haystack.contains) { return true }
        // A question mark anywhere in the opening lines usually means the
        // sender asked something rather than merely mentioned a question.
        return body.prefix(400).contains("?")
    }

    // MARK: - Score

    private static let urgentWords = [
        "urgent", "asap", "immediately", "right away", "emergency",
        "critical", "time sensitive", "time-sensitive",
    ]

    private static let deadlineWords = [
        "deadline", "due today", "due tomorrow", "by end of day", "by eod",
        "eod today", "before 5", "by 5pm", "by noon", "expires", "final notice",
        "last chance to", "closing today",
    ]

    static func score(message: Message, labels: Set<String>, haystack: String) -> Int {
        var score = 0

        // Gmail's own signals. The user starring something is the strongest
        // explicit statement of importance available without asking them.
        if labels.contains("STARRED") { score += 25 }
        if labels.contains("IMPORTANT") { score += 20 }
        if labels.contains("CATEGORY_PERSONAL") { score += 8 }

        if urgentWords.contains(where: haystack.contains) { score += 30 }
        if deadlineWords.contains(where: haystack.contains) { score += 22 }
        if containsClockTime(haystack) { score += 10 }

        // A human on a real domain, rather than a service address.
        if !message.sender.name.contains("@") && message.sender.name.count > 2 { score += 6 }
        if !message.isRead { score += 5 }

        return score
    }

    /// "by 5pm", "at 14:30" -- a concrete time is a strong deadline hint that
    /// the word list alone misses.
    static func containsClockTime(_ text: String) -> Bool {
        let patterns = [
            #"\b\d{1,2}\s*(am|pm)\b"#,
            #"\b\d{1,2}:\d{2}\b"#,
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
