import Foundation
import os

/// Something shared, behind a lock.
///
/// This exists because of a crash. `AIUsage` kept its counters in a
/// `nonisolated(unsafe) static var`, and `AIService.call` incremented them --
/// read, modify, write, no barrier -- from fifteen tasks at once. Storing an
/// `Optional` holding a `Dictionary` is a refcounted store, so two threads
/// doing it together released the same buffer twice. The app died in
/// `_xzm_corruption_detected`, in a Keychain call that had nothing to do with
/// any of it, because that was simply the next thing to allocate.
///
/// A lock rather than an actor, and that is a real constraint rather than a
/// preference: these values are read from inside SwiftUI `body`, which is
/// synchronous. An actor would make every one of those reads an `await`, and
/// a view cannot await.
///
/// `OSAllocatedUnfairLock` rather than `NSLock` because it holds the value it
/// protects. There is then no way to reach the state without taking the lock,
/// which is the mistake this type is here to prevent.
final class Guarded<Value>: @unchecked Sendable {
    private let storage: OSAllocatedUnfairLock<Value>

    init(_ initial: Value) {
        storage = OSAllocatedUnfairLock(initialState: initial)
    }

    /// Reads, changes, or both. Whatever is returned from the closure comes
    /// back out.
    ///
    /// Keep the body short and do no I/O in it. This is a spinlock: a thread
    /// waiting on it burns CPU rather than sleeping, so holding it across a
    /// network call or a disk write would be worse than the race it fixes.
    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        storage.withLock { state in body(&state) }
    }

    /// The common case: look at it without changing it.
    func read<Result>(_ body: (Value) -> Result) -> Result {
        storage.withLock { state in body(state) }
    }
}
