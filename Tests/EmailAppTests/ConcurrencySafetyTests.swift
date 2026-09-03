import Testing
import Foundation
@testable import EmailApp

/// These exist because of a crash on a real phone.
///
/// `AIUsage.record` was a read-modify-write of a shared static with no
/// barrier, called from `AIService.call`, which `enhanceWithAI` runs fifteen
/// of at once. The app died in `_xzm_corruption_detected` -- heap corruption
/// -- inside a Keychain call that had nothing to do with it, about seventy
/// seconds after launch.
///
/// A racing counter usually undercounts before it corrupts anything, so the
/// cheap and reliable way to test it is to count. Against the old code these
/// either come back short or take the process with them; against the fixed
/// code they are exact.
@Suite(.serialized)
struct ConcurrencySafetyTests {

    // MARK: - The counter that crashed

    @Test func recordingFromManyTasksAtOnceLosesNothing() async {
        AIUsage.reset()
        let calls = 200

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<calls {
                group.addTask { AIUsage.record(action: "classify") }
            }
        }

        // Exactly, not approximately. A lost increment is a lost increment
        // whether or not it also corrupted the heap.
        #expect(AIUsage.count(of: .reading) == calls)
        AIUsage.reset()
    }

    @Test func mixedKindsFromManyTasksAllLand() async {
        AIUsage.reset()
        let each = 60

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<each {
                group.addTask { AIUsage.record(action: "classify") }
                group.addTask { AIUsage.record(action: "ask_stream") }
                group.addTask { AIUsage.record(action: "draft") }
            }
        }

        #expect(AIUsage.count(of: .reading) == each)
        #expect(AIUsage.count(of: .questions) == each)
        #expect(AIUsage.count(of: .writing) == each)
        #expect(AIUsage.total == each * 3)
        AIUsage.reset()
    }

    /// Reading while writing is the other half of the race, and the half a
    /// count on its own would not catch.
    @Test func readingWhileRecordingIsSafe() async {
        AIUsage.reset()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { AIUsage.record(action: "classify") }
                group.addTask { _ = AIUsage.total }
                group.addTask { _ = AIUsage.used }
            }
        }

        #expect(AIUsage.count(of: .reading) == 100)
        AIUsage.reset()
    }

    // MARK: - The caches the mailbox index reads

    /// `PersonPreferences` fills its caches on *read*, and the reads come from
    /// the main thread building `MailboxIndex` and from the twenty-five
    /// background tasks that parse a page of Gmail. So a cold cache read
    /// concurrently is a write from twenty-six threads.
    @Test func aColdCacheReadFromManyTasksAtOnceIsSafe() async {
        PersonPreferences.clearAll()
        PersonPreferences.setImportant(true, for: "sara@example.com")
        PersonPreferences.setMuted(true, for: "noise@example.com")
        // Cold, so every reader below races to fill it.
        PersonPreferences.clearAll()
        PersonPreferences.setImportant(true, for: "sara@example.com")

        let answers = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<200 {
                group.addTask { PersonPreferences.isImportant("sara@example.com") }
            }
            var all: [Bool] = []
            for await answer in group { all.append(answer) }
            return all
        }

        #expect(answers.count == 200)
        #expect(answers.allSatisfy { $0 })
        PersonPreferences.clearAll()
    }

    @Test func scoringFromManyTasksAgreesWithItself() async {
        PersonPreferences.clearAll()
        PersonPreferences.setImportant(true, for: "client@example.com")
        PersonPreferences.setMuted(true, for: "newsletter@example.com")

        let scores = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<100 {
                group.addTask { PersonPreferences.scoreAdjustment(for: "client@example.com") }
                group.addTask { PersonPreferences.scoreAdjustment(for: "newsletter@example.com") }
                group.addTask { PersonPreferences.scoreAdjustment(for: "nobody@example.com") }
            }
            var all: [Int] = []
            for await score in group { all.append(score) }
            return all
        }

        #expect(scores.filter { $0 == 15 }.count == 100)
        #expect(scores.filter { $0 == -25 }.count == 100)
        #expect(scores.filter { $0 == 0 }.count == 100)
        PersonPreferences.clearAll()
    }

    // MARK: - The lock itself

    @Test func guardedSerialisesItsIncrements() async {
        let counter = Guarded(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask { counter.withLock { value in value += 1 } }
            }
        }

        #expect(counter.read { $0 } == 500)
    }

    @Test func guardedHandsBackWhatTheClosureReturns() {
        let box = Guarded([1, 2, 3])
        #expect(box.withLock { $0.removeLast() } == 3)
        #expect(box.read(\.count) == 2)
    }
}
