import Security
import XCTest
@testable import Iterate

final class YourMoveSnapshotTests: XCTestCase {
    func testCountsExpireFromOriginalCheckAndRejectInvalidValues() {
        let date = Date.now
        let empty = YourMoveSnapshot(approvalCount: 0, questionCount: 0, checkedAt: date)
        XCTAssertTrue(empty.isFresh(at: date))
        XCTAssertFalse(empty.isFresh(at: empty.expiresAt))
        XCTAssertFalse(empty.isFresh(at: date.addingTimeInterval(-1)))
        XCTAssertFalse(YourMoveSnapshot(approvalCount: -1, questionCount: 0, checkedAt: date).isFresh(at: date))
        XCTAssertFalse(YourMoveSnapshot(approvalCount: Int.max, questionCount: 1, checkedAt: date).isFresh(at: date))
    }

    func testLockedDeviceReadsOnlyFreshCountsForAnActivePairing() {
        let account = UUID().uuidString
        defer { removeFixture(account) }
        let date = Date.now
        var pairing: Result<String?, Error> = .success("first")
        let store = YourMoveSnapshotStore(account: account, session: { try pairing.get() })
        let counts = YourMoveSnapshot(approvalCount: 1, questionCount: 2, checkedAt: date)
        store.write(counts, for: "first", at: date)
        XCTAssertEqual(store.readFresh(at: date), counts)
        pairing = .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)))
        XCTAssertEqual(store.readFresh(at: date), counts)
        XCTAssertEqual(store.readFresh(at: date, for: "first"), counts)
        XCTAssertNil(store.readFresh(at: date, for: "second"))
        XCTAssertNil(store.readFresh(at: counts.expiresAt))
        pairing = .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement)))
        XCTAssertNil(store.readFresh(at: date))
        pairing = .success("second")
        XCTAssertNil(store.readFresh(at: date))
        store.select("second")
        pairing = .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)))
        XCTAssertNil(store.readFresh(at: date))
    }

    func testDeniedRequestInvalidatesOnlyItsSessionAndEarlierChecks() throws {
        let account = UUID().uuidString
        defer { removeFixture(account) }
        let base = Date.now
        var pairing: Result<String?, Error> = .success("first")
        let store = YourMoveSnapshotStore(account: account, session: { try pairing.get() })
        let older = YourMoveSnapshot(approvalCount: 1, questionCount: 0, checkedAt: base)
        let denied = base.addingTimeInterval(1)
        let tied = YourMoveSnapshot(approvalCount: 1, questionCount: 0, checkedAt: denied)
        let newer = YourMoveSnapshot(approvalCount: 0, questionCount: 0, checkedAt: denied.addingTimeInterval(1))
        store.write(older, for: "first", at: base)
        pairing = .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)))
        store.discard(for: "other", through: denied)
        XCTAssertEqual(store.readFresh(at: denied), older)
        store.discard(for: "first", through: denied)
        XCTAssertNil(store.readFresh(at: denied))

        pairing = .success("first")
        store.discard(for: "first", through: base)
        store.write(older, for: "first", at: denied)
        store.write(tied, for: "first", at: denied)
        XCTAssertNil(store.readFresh(at: denied))
        XCTAssertThrowsError(try store.confirm(tied, for: "first", at: denied)) { error in
            guard case AssistantIssue.accessDenied = error else { return XCTFail("Expected a denied session") }
        }
        XCTAssertEqual(try store.confirm(newer, for: "first", at: newer.checkedAt), newer)
        store.discard(for: "first", through: denied)
        XCTAssertEqual(try store.confirm(older, for: "first", at: newer.checkedAt), newer)

        store.select("second")
        pairing = .success("second")
        store.write(older, for: "second", at: denied)
        store.discard(for: "first", through: newer.checkedAt)
        XCTAssertEqual(store.readFresh(at: denied, for: "second"), older)
        XCTAssertThrowsError(try store.confirm(newer, for: "first", at: newer.checkedAt)) { error in
            guard case AssistantIssue.changedSession = error else { return XCTFail("Expected a changed pairing") }
        }
    }

    func testLateFetchCannotUndoSignOutOrReplaceANewerReading() {
        let account = UUID().uuidString
        defer { removeFixture(account) }
        let date = Date.now
        let first = YourMoveSnapshot(approvalCount: 2, questionCount: 1, checkedAt: date)
        let later = YourMoveSnapshot(approvalCount: 0, questionCount: 1, checkedAt: date.addingTimeInterval(1))
        let store = YourMoveSnapshotStore(account: account, session: { "member" })
        store.select("member")
        var interrupted = false
        let overlapping = YourMoveSnapshotStore(account: account) {
            if !interrupted {
                interrupted = true
                store.write(later, for: "member", at: later.checkedAt)
            }
            return "member"
        }
        overlapping.write(first, for: "member", at: later.checkedAt)
        XCTAssertEqual(store.readFresh(at: later.checkedAt), later)
        store.select(nil)
        store.write(later, for: "member", at: later.checkedAt)
        XCTAssertNil(store.readFresh(at: later.checkedAt))
    }

    func testDenialWhileFirstConfirmationIsWritingRejectsThatResponse() {
        let account = UUID().uuidString
        defer { removeFixture(account) }
        let denied = Date.now
        let old = YourMoveSnapshot(approvalCount: 3, questionCount: 0, checkedAt: denied.addingTimeInterval(-1))
        let store = YourMoveSnapshotStore(account: account, session: { "member" })
        var interrupted = false
        let writer = YourMoveSnapshotStore(account: account) {
            if !interrupted {
                interrupted = true
                store.discard(for: "member", through: denied)
            }
            return "member"
        }
        XCTAssertThrowsError(try writer.confirm(old, for: "member", at: denied)) { error in
            guard case AssistantIssue.accessDenied = error else { return XCTFail("Expected a denied session") }
        }
        XCTAssertNil(store.readFresh(at: denied))
    }

    private func removeFixture(_ account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecAttrService as String: WidgetSnapshotService.yourMove.name]
        SecItemDelete(query as CFDictionary)
    }
}
