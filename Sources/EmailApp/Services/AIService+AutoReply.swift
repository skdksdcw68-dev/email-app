import Foundation

/// The two calls behind the Auto-Reply setup.
///
/// Both send the person's own answers -- what they picked, what they typed
/// about their own business -- and nothing else. No mail content goes near
/// either of them, which is what keeps this outside the Limited Use rules
/// that govern everything the classifier does.
extension AIService {

    /// What the model understood, written back for them to check.
    ///
    /// The whole value of the screen is that this can be wrong. Assembled on
    /// the device from the same fields that produced it, it would agree with
    /// itself every time and check nothing.
    static func autoReplyUnderstanding(
        _ payload: [String: String]
    ) async throws -> AutoReplyUnderstanding {
        var body = payload
        body["action"] = "autoreply_understanding"
        return try await call(body)
    }

    /// A real reply, written from the setup, with the model's own account of
    /// what it refused to answer and why.
    static func autoReplyExample(
        _ payload: [String: String]
    ) async throws -> AutoReplyExample {
        var body = payload
        body["action"] = "autoreply_example"
        return try await call(body)
    }
}

extension AIService {

    /// One reply, written from the setup and the message.
    ///
    /// The model may refuse, and refusing is a real answer: `handled` comes
    /// back false with a reason, and the app escalates rather than treating
    /// it as a failure. An assistant that cannot decline will answer
    /// everything, which is the failure that matters here.
    struct AutoReplyResult: Decodable {
        let handled: Bool
        let reply: String
        let reason: String
        let category: String
        let evidence: [String]
        let withheld: [String]
        let confidence: Double

        private enum CodingKeys: String, CodingKey {
            case handled, reply, reason, category, evidence, withheld, confidence
        }

        /// Every field optional on the way in: a reply that arrives without
        /// its explanation is still a reply, and a malformed one must fail
        /// closed rather than throw away the whole response.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            handled = try container.decodeIfPresent(Bool.self, forKey: .handled) ?? false
            reply = try container.decodeIfPresent(String.self, forKey: .reply) ?? ""
            reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
            evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
            withheld = try container.decodeIfPresent([String].self, forKey: .withheld) ?? []
            confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        }
    }

    static func autoReply(
        message: Message,
        briefing: String,
        thread: String
    ) async throws -> AutoReplyResult {
        var payload: [String: String] = [
            "action": "autoreply",
            "briefing": briefing,
            "from": "\(message.sender.name) <\(message.sender.address)>",
            "date": message.fullDate,
            "subject": message.subject,
            "body": message.body,
            "today": Self.todayLine,
        ]
        if !thread.isEmpty { payload["thread"] = thread }
        return try await call(payload)
    }
}
