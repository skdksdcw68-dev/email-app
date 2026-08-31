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

        init(priority: String, needsReply: Bool, summary: String, category: String? = nil) {
            self.priority = priority
            self.needsReply = needsReply
            self.summary = summary
            self.category = category
        }

        enum CodingKeys: String, CodingKey {
            case priority
            case needsReply = "needs_reply"
            case summary
            case category
        }

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

    // MARK: - Transport

    private static func call<T: Decodable>(_ payload: [String: String]) async throws -> T {
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
