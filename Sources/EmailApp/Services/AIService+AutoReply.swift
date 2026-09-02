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
