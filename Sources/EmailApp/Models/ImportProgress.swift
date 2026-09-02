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
    /// Everything is down; writing it to disk and handing it to the app.
    case saving
    /// `missing` is mail Gmail listed that would not come down this run.
    /// Zero on a clean import; anything else is topped up on a later launch.
    case finished(count: Int, missing: Int)

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
        case .connecting: "Getting started"
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
        case .saving: "Finalising"
        case .finished(_, let missing): missing > 0 ? "Nearly everything" : "All set"
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
        case .saving: "Adding your mail to Maily and saving it for offline."
        case .finished(let count, let missing):
            // Never rounded up. Saying "all set" over a mailbox that is 40
            // messages short is how the old import hid a third of somebody's
            // mail from them for weeks.
            if missing > 0 {
                "\(count) of \(count + missing) messages. Maily will fetch the rest shortly."
            } else if count == 1 {
                "1 message ready."
            } else {
                "\(count) messages ready."
            }
        }
    }
}
