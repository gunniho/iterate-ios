import XCTest
import Security
@testable import Iterate

final class YourMoveTimelineTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testLockedKeychainAndOfflineRefreshRecoverButRejectedSessionCannotUseCache() {
        let prior = YourMoveSnapshot(approvalCount: 1, questionCount: 2, checkedAt: checkedAt)
        let now = checkedAt.addingTimeInterval(120)
        let locked = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))
        for error: Error in [locked, URLError(.notConnectedToInternet), URLError(.timedOut)] {
            let plan = YourMoveTimeline.afterFailure(error, cached: prior, now: now)
            XCTAssertEqual(plan.state, .ready(approvals: 1, questions: 2))
            XCTAssertEqual(plan.expiresAt, prior.expiresAt)
        }
        for error: Error in [AssistantIssue.unpaired, AssistantIssue.accessDenied("Denied"), ConnectionIssue.refused, ConnectionIssue.expired] {
            XCTAssertEqual(YourMoveTimeline.afterFailure(error, cached: prior, now: now).state, .unpaired)
        }
        XCTAssertEqual(YourMoveTimeline.afterFailure(AssistantIssue.changedSession, cached: prior, now: now).state, .stale)
    }

    func testTransientFailureKeepsFreshCountsAndRetriesSooner() throws {
        for (approvals, questions) in [(3, 2), (0, 0)] {
            let snapshot = YourMoveSnapshot(approvalCount: approvals, questionCount: questions, checkedAt: checkedAt)
            let live = YourMoveTimeline.live(snapshot, now: checkedAt)
            let deadline = try XCTUnwrap(live.expiresAt)
            let refresh = checkedAt.addingTimeInterval(60)
            let recovered = YourMoveTimeline.recover(snapshot, now: refresh)

            XCTAssertEqual(live.state, .ready(approvals: approvals, questions: questions))
            XCTAssertEqual(recovered.state, live.state)
            XCTAssertEqual(recovered.expiresAt, deadline)
            XCTAssertGreaterThan(recovered.retryAt, refresh)
            XCTAssertLessThan(recovered.retryAt.timeIntervalSince(refresh), live.retryAt.timeIntervalSince(checkedAt))
        }
    }

    func testRepeatedFailuresExpireAtTheOriginalDeadline() throws {
        let snapshot = YourMoveSnapshot(approvalCount: 0, questionCount: 0, checkedAt: checkedAt)
        let live = YourMoveTimeline.live(snapshot, now: checkedAt)
        let deadline = try XCTUnwrap(live.expiresAt)
        XCTAssertGreaterThan(deadline, checkedAt)
        XCTAssertLessThanOrEqual(deadline.timeIntervalSince(checkedAt), 60 * 60)

        let justBefore = YourMoveTimeline.recover(snapshot, now: deadline.addingTimeInterval(-1))
        XCTAssertEqual(justBefore.state, .ready(approvals: 0, questions: 0))
        XCTAssertEqual(justBefore.expiresAt, deadline)
        for time in [deadline, deadline.addingTimeInterval(3600)] {
            let expired = YourMoveTimeline.recover(snapshot, now: time)
            XCTAssertEqual(expired.state, .stale)
            XCTAssertNil(expired.expiresAt)
            XCTAssertGreaterThan(expired.retryAt, time)
            XCTAssertGreaterThan(expired.retryAt.timeIntervalSince(time),
                                 YourMoveTimeline.recover(snapshot, now: checkedAt).retryAt.timeIntervalSince(checkedAt))
        }
    }

    func testMissingAndFutureSnapshotsCannotReportCounts() {
        let future = YourMoveSnapshot(approvalCount: 4, questionCount: 1, checkedAt: checkedAt.addingTimeInterval(60))
        for cached in [nil, future] {
            let plan = YourMoveTimeline.recover(cached, now: checkedAt)
            XCTAssertEqual(plan.state, .stale)
            XCTAssertNil(plan.expiresAt)
            XCTAssertGreaterThan(plan.retryAt, checkedAt)
        }
    }

    func testUnpairedStateCarriesNoCountsOrFormerExpiry() {
        let snapshot = YourMoveSnapshot(approvalCount: 12, questionCount: 3, checkedAt: checkedAt)
        XCTAssertEqual(YourMoveTimeline.live(snapshot, now: checkedAt).state, .ready(approvals: 12, questions: 3))
        let disconnected = YourMoveTimeline.unpaired(now: checkedAt)
        XCTAssertEqual(disconnected.state, .unpaired)
        XCTAssertNil(disconnected.expiresAt)
    }

    func testCountsDecoderRequiresNonnegativeCountsAndARepresentableTotal() throws {
        func decode(_ approvals: Int, _ questions: Int) throws -> YourMoveCounts {
            let data = try JSONSerialization.data(withJSONObject: ["approvalCount": approvals, "questionCount": questions])
            return try JSONDecoder().decode(YourMoveCounts.self, from: data)
        }

        let counts = try decode(5, 2)
        XCTAssertEqual(counts.approvalCount, 5)
        XCTAssertEqual(counts.questionCount, 2)
        XCTAssertNoThrow(try decode(0, 0))
        XCTAssertNoThrow(try decode(Int.max - 1, 1))
        XCTAssertThrowsError(try decode(-1, 0))
        XCTAssertThrowsError(try decode(0, -1))
        XCTAssertThrowsError(try decode(Int.max, 1))
    }
}
