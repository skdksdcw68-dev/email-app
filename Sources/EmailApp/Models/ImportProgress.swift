import Foundation

/// Where the initial import has got to.
///
/// Every string here is derived from a real count. Nothing is on a timer and
/// nothing says "almost there" until it actually is -- a progress screen that
/// lies is worse than one that says nothing, because the next time it tells
/// the truth nobody believes it.
enum ImportProgress: Equatable {
    case idle
    /// Waiting on Google's consent screen.
    case connecting
    /// Asking Gmail what is in the window before fetching any of it.
    case counting
    /// `done` of `total` message bodies fetched.
    case importing(done: Int, total: Int)
    /// Everything is down; writing it to disk.
    case saving
    case finished

    var isRunning: Bool {
        switch self {
        case .idle, .finished: false
        default: true
        }
    }

    /// 0 to 1, or nil when there is nothing honest to show yet.
    var fraction: Double? {
        switch self {
        case .importing(let done, let total) where total > 0:
            Double(done) / Double(total)
        case .saving: 1
        case .finished: 1
        default: nil
        }
    }

    var title: String {
        switch self {
        case .idle: ""
        case .connecting: "Connecting to Gmail"
        case .counting: "Looking through your mailbox"
        case .importing(let done, let total):
            // The wording tracks the actual fraction. "Almost there" appears
            // when it is almost there, not after a fixed delay.
            if total > 0, Double(done) / Double(total) >= 0.85 {
                "Almost there"
            } else if done == 0 {
                "Starting the import"
            } else {
                "Importing your email"
            }
        case .saving: "Saving for offline"
        case .finished: "All set"
        }
    }

    var detail: String {
        switch self {
        case .idle: ""
        case .connecting: "Waiting for you to allow access."
        case .counting: "Finding everything from the last three months."
        case .importing(let done, let total):
            total > 0
                ? "\(done) of \(total) messages"
                : "\(done) messages so far"
        case .saving: "So your mail is here even without a connection."
        case .finished: "Your inbox is ready."
        }
    }
}
