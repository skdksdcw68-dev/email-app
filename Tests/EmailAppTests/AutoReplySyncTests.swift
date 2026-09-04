import XCTest
@testable import EmailApp

/// The Auto-Reply setup follows the account. Being *armed* must not.
///
/// 🔴 This is the highest-consequence thing in the settings sync, and the
/// failure is silent.
///
/// The setup is shared on purpose: how somebody writes, what their work is,
/// what they will never let a machine say for them — none of that changes
/// because they picked up a second phone, and asking eleven questions again
/// per device is a good way to have the feature switched off for good.
///
/// Arming is the opposite. `AutoReplyActivation` exists precisely because
/// connecting a work address to an app where Auto-Reply was already on would
/// otherwise arm an agent to answer that address's mail — silently, on the
/// first sync, in a voice tuned for a different audience. Those three fields
/// were moved into the mailbox's own suite for that reason.
///
/// A sync that carried them would resurrect the same failure through the back
/// door. So the payload is an allow-list, and this is the test that says so.
final class AutoReplySyncTests: XCTestCase {

    private func armed() -> AutoReplyConfig {
        var config = AutoReplyConfig()
        config.isSetUp = true
        config.isOn = true
        config.mode = .send
        config.watchingSince = Date(timeIntervalSince1970: 1_700_000_000)
        config.allowed = [.acknowledgement]
        config.persona = .freelancer
        return config
    }

    func testTheSyncedCopyIsNotArmed() {
        let synced = armed().syncable

        XCTAssertFalse(synced.isOn)
        XCTAssertEqual(synced.mode, .draft)
        XCTAssertNil(synced.watchingSince)
    }

    func testTheSetupItselfSurvives() {
        // The point of syncing at all. Stripping the arming must not strip
        // the eleven questions with it.
        let synced = armed().syncable

        XCTAssertTrue(synced.isSetUp)
        XCTAssertEqual(synced.allowed, [.acknowledgement])
        XCTAssertEqual(synced.persona, .freelancer)
    }

    func testTheEncodedPayloadCarriesNoArming() throws {
        // Checked on the JSON rather than the struct, because the JSON is what
        // actually leaves the phone. A field added to `AutoReplyConfig` later
        // is encoded whether or not anybody remembered it exists.
        let data = try JSONEncoder().encode(armed().syncable)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["isOn"] as? Bool, false)
        XCTAssertEqual(json["mode"] as? String, AutoReplyConfig.RunMode.draft.rawValue)
        XCTAssertNil(json["watchingSince"])
    }

    func testTheOriginalIsUnchanged() {
        // `syncable` returns a copy. Reading it must not disarm the config the
        // app is actually running from.
        let config = armed()
        _ = config.syncable

        XCTAssertTrue(config.isOn)
        XCTAssertEqual(config.mode, .send)
        XCTAssertNotNil(config.watchingSince)
    }
}
