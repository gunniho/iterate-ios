import XCTest
@testable import Iterate

@MainActor
final class PhoneActionsTests: XCTestCase {
    func testALentNameIsTheStartOfTheMembersAddress() {
        XCTAssertEqual(PhoneLend.name(for: "Ada.Lovelace@example.com"), "adalovelace.iphone")
        XCTAssertEqual(PhoneLend.name(for: "42@example.com"), "member42.iphone")
        XCTAssertNil(PhoneLend.name(for: "…@example.com"))
        XCTAssertNil(PhoneLend.name(for: nil))
    }

    func testListsTravelWrappedAndArriveUnwrapped() throws {
        let answer: [String: Any] = ["songs": [["title": "One"], ["title": "Two"]], "count": 2]
        let sent = try XCTUnwrap(MindWire.wire(answer) as? [String: Any])
        let wrapped = try XCTUnwrap(sent["songs"] as? [Any])
        XCTAssertEqual(wrapped.count, 1)
        let back = try XCTUnwrap(MindWire.plain(sent) as? [String: Any])
        XCTAssertEqual((back["songs"] as? [[String: String]])?.map { $0["title"] }, ["One", "Two"])
        XCTAssertTrue(try MindWire.plain(["undefined"]) is NSNull)
        // A stub or bytes are no input for an action.
        XCTAssertThrowsError(try MindWire.plain(["export", -3]))
    }

    func testATimeWithoutAnOffsetIsReadOnThisIPhonesClock() throws {
        let exact = try XCTUnwrap(PhoneActions.moment(["at": "2026-11-24T09:30:00.000Z"], "at"))
        XCTAssertEqual(exact.timeIntervalSince1970, 1_795_512_600)
        let local = try XCTUnwrap(PhoneActions.moment(["at": "2026-11-24T09:30"], "at"))
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute], [2026, 11, 24, 9, 30])
        let day = try XCTUnwrap(PhoneActions.moment(["at": "2026-11-24"], "at"))
        XCTAssertEqual(day, Calendar.current.startOfDay(for: local))
        XCTAssertNil(try PhoneActions.moment([:], "at"))
        XCTAssertThrowsError(try PhoneActions.moment(["at": "next Tuesday"], "at"))
    }

    func testDescribeNamesEveryActionAndAnUnknownOneIsRefused() async throws {
        let answer = try await PhoneActions.perform(["describe"], [])
        let described = try XCTUnwrap(answer as? [String: Any])
        let calls = (described["actions"] as? [[String: String]])?.compactMap { $0["call"] }
        XCTAssertEqual(calls, PhoneActions.catalog.map(\.call))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(MindWire.wire(described)))
        for refused in [["calendar", "events"], ["reminders", "add"], ["home", "erase"], [], ["describe", "more"]] {
            do {
                _ = try await PhoneActions.perform(refused, [])
                XCTFail("\(refused) was performed")
            } catch { XCTAssertTrue(error.localizedDescription.contains("describe()")) }
        }
    }

    func testAnActionChecksItsInputBeforeItAsksIOSForAnything() async {
        let wrong: [([String], [Any])] = [
            (["contacts", "find"], [[:] as [String: Any]]),
            (["contacts", "find"], [["name": 7]]),
            (["music", "search"], [[:] as [String: Any]]),
            (["health", "steps"], [["day": "next Tuesday"]]),
            (["home", "run"], [["home": "Cabin"]]),
            (["music", "play"], [["term": "Song", "in": "radio"]]),
            (["health", "steps"], ["tomorrow"]),
        ]
        for (path, arguments) in wrong {
            do {
                _ = try await PhoneActions.perform(path, arguments)
                XCTFail("\(path) took \(arguments)")
            } catch { XCTAssertTrue(error is DeviceContextError, "\(path): \(error)") }
        }
    }
}
