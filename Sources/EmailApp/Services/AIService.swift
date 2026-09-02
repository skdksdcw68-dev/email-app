import Foundation
import Supabase

/// Talks to the `ai` Edge Function.
///
/// Called over plain URLSession rather than the Supabase SDK's function
/// helper: the request is two fields and a bearer token, and hand-rolling it
/// keeps the exact wire shape visible instead of behind generics.
///
/// No provider key here. It lives in Supabase's secret store and is only ever
/// read server-side.
enum AIService {

    struct Classification: Decodable {
        let priority: String
        let needsReply: Bool
        let summary: String
        /// What sort of message this is. Optional so a response from an older
        /// deployment of the function still decodes.
        let category: String?
        /// Whether the model thought a closer read would find something: an
        /// ask, a promise, a date. The first tier deciding when the second
        /// runs, rather than a word list. Optional for the same reason.
        let extract: Bool?

        init(priority: String, needsReply: Bool, summary: String, category: String? = nil, extract: Bool? = nil) {
            self.priority = priority
            self.needsReply = needsReply
            self.summary = summary
            self.category = category
            self.extract = extract
        }

        enum CodingKeys: String, CodingKey {
            case priority
            case needsReply = "needs_reply"
            case summary
            case category
            case extract
        }

        var wantsExtraction: Bool { extract == true }

        /// The model speaks in its own vocabulary; map it onto ours.
        var tag: AITag? {
            switch priority {
            case "urgent": .urgent
            case "very_important": .veryImportant
            case "important": .important
            default: nil
            }
        }

        var kindTag: AITag? {
            category.flatMap(AITag.kind(named:))
        }
    }

    struct Draft: Decodable {
        let body: String
    }

    enum AIError: LocalizedError {
        case server(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .server(let message): message
            case .malformed: "The AI service returned something unexpected."
            }
        }
    }

    // MARK: - Calls

    static func classify(_ message: Message) async throws -> Classification {
        try await call(
            [
                "action": "classify",
                "from": "\(message.sender.name) <\(message.sender.address)>",
                "subject": message.subject,
                "body": message.body,
            ]
        )
    }

    /// The second tier: what this message asks, promises, questions or dates.
    ///
    /// Only for messages the first tier flagged, and for mail the person sent
    /// themselves, which is person-to-person by construction. The whole body
    /// goes, within the server's limit, because an ask is usually at the end.
    /// The result is from the email's point of view; `Extraction.facts(for:)`
    /// turns it round to the reader's.
    static func extract(_ message: Message) async throws -> Extraction {
        try await call(
            [
                "action": "extract",
                "from": "\(message.sender.name) <\(message.sender.address)>",
                "to": message.recipients.map { "\($0.name) <\($0.address)>" }.joined(separator: ", "),
                "date": message.fullDate,
                "subject": message.subject,
                "body": message.body,
            ]
        )
    }

    /// `instruction` is what the user asked for -- spoken aloud, or picked
    /// from the writer's styles. The model turns it into a reply; it does not
    /// invent facts beyond it.
    ///
    /// `message` is optional so the writer also works on a new email, where
    /// there is no thread to answer and the instruction is all the context
    /// there is.
    static func draft(replyingTo message: Message?, instruction: String, tone: String) async throws -> Draft {
        var payload = [
            "action": "draft",
            "instruction": instruction,
            "tone": tone,
        ]
        if let message {
            payload["from"] = "\(message.sender.name) <\(message.sender.address)>"
            payload["subject"] = message.subject
            payload["body"] = message.body
        }
        return try await call(payload)
    }

    /// Tightens what the user has already written, rather than writing from
    /// scratch. The original message goes along when there is one so the model
    /// can tell a reply from a cold email and keep the thread's register.
    static func refine(text: String, replyingTo message: Message?, tone: String) async throws -> Draft {
        var payload = [
            "action": "refine",
            "text": text,
            "tone": tone,
        ]
        if let message {
            payload["from"] = "\(message.sender.name) <\(message.sender.address)>"
            payload["subject"] = message.subject
            payload["body"] = message.body
        }
        return try await call(payload)
    }

    /// Applies one requested change to a draft -- "make it warmer", "add a
    /// clear next step" -- and nothing else. Distinct from `refine`, which
    /// improves a draft on its own judgement; here the person has said
    /// exactly what they want different.
    static func revise(text: String, instruction: String, replyingTo message: Message?, tone: String) async throws -> Draft {
        var payload = [
            "action": "revise",
            "text": text,
            "instruction": instruction,
            "tone": tone,
        ]
        if let message {
            payload["from"] = "\(message.sender.name) <\(message.sender.address)>"
            payload["subject"] = message.subject
            payload["body"] = message.body
        }
        return try await call(payload)
    }

    struct Answer: Decodable {
        let answer: String
    }

    /// What an AI search decided to look for.
    ///
    /// The model does not read the mailbox here. It reads the *question* and
    /// writes a Gmail query, which Gmail then answers from its own index over
    /// the whole account. That is what makes this affordable: one small call,
    /// no mail leaving the phone, and a search that reaches back further than
    /// the three months this device holds.
    struct SearchPlan: Decodable {
        let query: String
        let terms: [String]
        let explanation: String

        init(query: String, terms: [String], explanation: String) {
            self.query = query
            self.terms = terms
            self.explanation = explanation
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            query = (try? container.decode(String.self, forKey: .query)) ?? ""
            terms = (try? container.decode([String].self, forKey: .terms)) ?? []
            explanation = (try? container.decode(String.self, forKey: .explanation)) ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case query, terms, explanation
        }
    }

    static func searchPlan(for question: String) async throws -> SearchPlan {
        try await call([
            "action": "search",
            "question": String(question.prefix(300)),
            "today": Self.todayLine,
        ])
    }

    /// Asks a question about the mailbox.
    ///
    /// `context` has already been chosen on the device, so only a handful of
    /// messages -- headers and the opening of each body -- leave the phone.
    /// The model is told to cite them by number, which is what makes an answer
    /// checkable rather than merely confident.
    static func ask(question: String, context: [Message]) async throws -> Answer {
        let digest = context.map { message in
            [
                "from": "\(message.sender.name) <\(message.sender.address)>",
                "date": message.fullDate,
                "subject": message.subject,
                "body": String(message.body.prefix(400)),
            ]
        }

        var request = URLRequest(url: SupabaseConfig.url.appending(path: "functions/v1/ai"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(await bearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["action": "ask", "question": question, "messages": digest]
        )
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AIError.server(message ?? "AI service returned \(http.statusCode).")
        }
        do {
            return try JSONDecoder().decode(Answer.self, from: data)
        } catch {
            throw AIError.malformed
        }
    }

    /// The same question, delivered a piece at a time.
    ///
    /// `onDelta` is called on the main actor for every fragment the model
    /// produces, so the answer appears as it is written rather than arriving
    /// whole after ten seconds of nothing. That wait is the difference between
    /// an app that looks fast and one that looks stuck.
    ///
    /// `history` is the conversation so far, oldest first, so a follow-up
    /// like "and the second one?" has something to refer to. A deployment of
    /// the function that predates it simply ignores the field.
    ///
    /// `inbox` is the tag chips as one line -- "Very Urgent 12, Important 30"
    /// -- so the model can answer about a pile it was not sent. Nil when the
    /// question has nothing to do with mail, which is also what makes that
    /// case cheap: no digest, no inbox line, no sources.
    ///
    /// `signedInAs` and `tone` are who is asking and how they like to be
    /// written to. Both were known on the device all along and never sent.
    @MainActor
    static func askStreaming(
        question: String,
        context: [Message],
        history: [(role: String, content: String)] = [],
        inbox: String? = nil,
        signedInAs: String? = nil,
        tone: String? = nil,
        memories: String? = nil,
        /// What the app has already read out of their mail: who is waiting
        /// on whom, and for what. Numbered against `context`, so the model
        /// can show the message a line points at.
        facts: String? = nil,
        /// How many more times the model may ask to search instead of
        /// answering. Counts down each hop, so an investigation can take
        /// two or three passes and still cannot run forever.
        hopsLeft: Int = 2,
        /// Whether a search has already run for this question. Changes the
        /// advice: a second guess should not repeat the first one's words.
        hasSearched: Bool = false,
        onDelta: @MainActor (String) -> Void
    ) async throws {
        // 300, not 400. Twelve messages at 400 characters is most of what a
        // question costs, and the opening 300 carries the point of an email.
        let digest = context.map { message in
            [
                "from": "\(message.sender.name) <\(message.sender.address)>",
                "date": message.fullDate,
                "subject": message.subject,
                "body": String(message.body.prefix(300)),
                // Whether they have seen it. This is what stops the model
                // telling somebody to reply to an email they read on Monday
                // and decided about already.
                "read": message.isRead ? "yes" : "no",
                "tags": message.tags.map(\.title).sorted().joined(separator: ", "),
            ]
        }
        let prior = history.map { ["role": $0.role, "content": $0.content] }

        var payload: [String: Any] = [
            "action": "ask_stream",
            "question": question,
            "messages": digest,
            "history": prior,
            // The model has never known what day it is, so "urgent today",
            // "this week" and "before Friday" were all guesses.
            "today": Self.todayLine,
        ]
        if let inbox, !inbox.isEmpty { payload["inbox"] = inbox }
        if let signedInAs, !signedInAs.isEmpty { payload["user"] = signedInAs }
        if let tone, !tone.isEmpty { payload["tone"] = tone }
        if let memories, !memories.isEmpty { payload["memories"] = memories }
        if let facts, !facts.isEmpty { payload["facts"] = facts }
        payload["hops_left"] = max(0, hopsLeft)
        payload["searched"] = hasSearched

        var request = URLRequest(url: SupabaseConfig.url.appending(path: "functions/v1/ai"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(await bearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            // An error comes back as JSON on the same connection, so read what
            // little there is rather than reporting a bare status code.
            var body = ""
            for try await line in bytes.lines { body += line }
            let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
            throw AIError.server(message ?? "AI service returned \(http.statusCode).")
        }

        for try await line in bytes.lines {
            // Server-sent events: `data: {json}` per line, terminated by
            // `data: [DONE]`. Anything else is keepalive or blank.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { return }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let fragment = delta["content"] as? String,
                  !fragment.isEmpty
            else { continue }

            onDelta(fragment)
        }
    }

    /// "Monday, 1 September 2026" -- the device's own date, in the device's
    /// own locale.
    /// Also read by the Auto-Reply runtime, which has the same problem: a
    /// model that does not know the date cannot resolve "by Friday".
    static var todayLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        return formatter.string(from: .now)
    }

    // MARK: - Transport

    /// Not private: the Auto-Reply calls live in their own file, because
    /// they are about the person's setup rather than their mail.
    static func call<T: Decodable>(_ payload: [String: String]) async throws -> T {
        var request = URLRequest(url: SupabaseConfig.url.appending(path: "functions/v1/ai"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(await bearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIError.malformed }

        guard (200..<300).contains(http.statusCode) else {
            // The function reports its own failures as { "error": "..." }.
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AIError.server(message ?? "AI service returned \(http.statusCode).")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIError.malformed
        }
    }

    /// A signed-in user's token when there is one, the public anon key
    /// otherwise -- the function accepts either, and both are valid JWTs.
    private static func bearer() async -> String {
        if let session = try? await SupabaseClient.shared.auth.session {
            return session.accessToken
        }
        return SupabaseConfig.anonKey
    }
}
