import Security
import XCTest
@testable import Iterate

final class RecentAgentsRecoveryTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let alpha = IterateAgent(path: "/agents/alpha", name: "Alpha", lastActive: nil)
    private let beta = IterateAgent(path: "/agents/beta", name: "Beta", lastActive: nil)
    private let locked = NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed))

    func testInterruptedRefreshRetainsLastConfirmedListAndTimeOvernight() {
        let nextMorning = checkedAt.addingTimeInterval(12 * 3600)
        for rows in [[alpha, beta], []] {
            let prior = RecentAgentsSnapshot(rows: rows, checkedAt: checkedAt)
            let live = RecentAgentsTimeline.live(prior, now: checkedAt)
            guard case .list(let initial) = live.state else { return XCTFail("Expected a confirmed list") }
            XCTAssertEqual(initial.rows, rows)
            for error: Error in [locked, URLError(.notConnectedToInternet), URLError(.timedOut)] {
                let retry = RecentAgentsTimeline.afterFailure(error, cached: prior, now: nextMorning)
                guard case .list(let recovered) = retry.state else { return XCTFail("Expected the saved list") }
                XCTAssertEqual(recovered.rows, rows)
                XCTAssertEqual(recovered.checkedAt, checkedAt)
                XCTAssertGreaterThan(retry.retryAt, nextMorning)
            }
            let gallery = RecentAgentsTimeline.cached(prior, now: nextMorning)
            guard case .list(let saved) = gallery.state else { return XCTFail("Expected the saved list in the widget snapshot") }
            XCTAssertEqual(saved.rows, rows)
            XCTAssertEqual(saved.checkedAt, checkedAt)
        }
    }

    func testMissingOrFutureSnapshotCannotMasqueradeAsAnEmptyCatalog() {
        let future = RecentAgentsSnapshot(rows: [], checkedAt: checkedAt.addingTimeInterval(60))
        for snapshot in [nil, future] {
            let result = RecentAgentsTimeline.cached(snapshot, now: checkedAt)
            guard case .unavailable = result.state else { return XCTFail("Expected an unavailable list") }
            XCTAssertGreaterThan(result.retryAt, checkedAt)
        }
    }

    func testAuthorizationAndPairingFailuresCannotDisplayPreviousRows() {
        let previous = RecentAgentsSnapshot(rows: [alpha], checkedAt: checkedAt)
        for error: Error in [AssistantIssue.unpaired, AssistantIssue.accessDenied("Denied"),
                             ConnectionIssue.expired, ConnectionIssue.refused,
                             AssistantIssue.changedSession, ConnectionIssue.wrongMind] {
            let result = RecentAgentsTimeline.afterFailure(error, cached: previous, now: checkedAt)
            if case .list = result.state { XCTFail("Unexpected cached rows for \(error)") }
        }
    }

    func testLockedWidgetUsesSamePairingAfterFirstUnlockAndSignOutClearsIt() throws {
        let account = UUID().uuidString
        defer { SecItemDelete(keychainQuery(account) as CFDictionary) }
        var session: Result<String?, Error> = .success("first")
        let writer = RecentAgentsSnapshotStore(account: account, session: { try session.get() })
        let reader = RecentAgentsSnapshotStore(account: account, session: { try session.get() })
        let prior = RecentAgentsSnapshot(rows: [alpha, beta], checkedAt: checkedAt)
        writer.write(prior, for: "first", at: checkedAt)

        var query = keychainQuery(account)
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        let nextMorning = checkedAt.addingTimeInterval(12 * 3600)
        session = .failure(locked)
        let afterLock = try XCTUnwrap(reader.readFresh(at: nextMorning))
        XCTAssertEqual(afterLock.rows, prior.rows)
        XCTAssertEqual(afterLock.checkedAt, checkedAt)
        XCTAssertNil(reader.readFresh(at: nextMorning, for: "second"))
        session = .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(errSecMissingEntitlement)))
        XCTAssertNil(reader.readFresh(at: nextMorning))
        session = .success("second")
        XCTAssertNil(reader.readFresh(at: nextMorning))
        writer.select("second")
        session = .failure(locked)
        XCTAssertNil(reader.readFresh(at: nextMorning))

        session = .success("second")
        let latest = RecentAgentsSnapshot(rows: [beta], checkedAt: nextMorning)
        writer.write(latest, for: "second", at: nextMorning)
        XCTAssertEqual(reader.readFresh(at: nextMorning)?.rows, [beta])
        writer.select(nil)
        writer.write(latest, for: "second", at: nextMorning)
        session = .failure(locked)
        XCTAssertNil(reader.readFresh(at: nextMorning))
    }

    func testLateCatalogCannotRestoreArchivedRowOrAdvanceItsTimestamp() throws {
        let account = UUID().uuidString
        defer { SecItemDelete(keychainQuery(account) as CFDictionary) }
        let store = RecentAgentsSnapshotStore(account: account, session: { "member" })
        let first = RecentAgentsSnapshot(rows: [alpha, beta], checkedAt: checkedAt)
        store.write(first, for: "member", at: checkedAt)
        let started = checkedAt.addingTimeInterval(1)
        let archived = checkedAt.addingTimeInterval(2)
        let staleReply = RecentAgentsSnapshot(rows: [alpha, beta], checkedAt: started)
        store.remove(path: alpha.path, for: "member", at: archived)
        let recovered = try store.confirm(staleReply, for: "member", at: archived)
        XCTAssertEqual(recovered.rows, [beta])
        XCTAssertEqual(recovered.checkedAt, checkedAt)
        store.write(staleReply, for: "member", at: archived)
        XCTAssertEqual(store.readFresh(at: archived)?.rows, [beta])
    }

    func testArchivingBeforeTheFirstSnapshotBlocksAnEarlierRequest() {
        let account = UUID().uuidString
        defer { SecItemDelete(keychainQuery(account) as CFDictionary) }
        let store = RecentAgentsSnapshotStore(account: account, session: { "member" })
        let earlier = RecentAgentsSnapshot(rows: [alpha, beta], checkedAt: checkedAt)
        let archived = checkedAt.addingTimeInterval(1)
        store.remove(path: alpha.path, for: "member", at: archived)
        let response = try? store.confirm(earlier, for: "member", at: archived)
        XCTAssertFalse(response?.rows.contains(alpha) == true)
        XCTAssertFalse(store.readFresh(at: archived)?.rows.contains(alpha) == true)
    }

    func testDenialBarsOlderRequestsButAllowsNewerSuccessfulCatalog() throws {
        let account = UUID().uuidString
        defer { SecItemDelete(keychainQuery(account) as CFDictionary) }
        let store = RecentAgentsSnapshotStore(account: account, session: { "member" })
        let first = RecentAgentsSnapshot(rows: [alpha], checkedAt: checkedAt)
        let denied = checkedAt.addingTimeInterval(2)
        store.write(first, for: "member", at: checkedAt)
        store.discard(for: "other", through: denied)
        XCTAssertEqual(store.readFresh(at: denied)?.rows, [alpha])
        store.discard(for: "member", through: denied)
        for date in [checkedAt, denied] {
            let late = RecentAgentsSnapshot(rows: [alpha], checkedAt: date)
            XCTAssertThrowsError(try store.confirm(late, for: "member", at: denied)) { error in
                guard case AssistantIssue.accessDenied = error else { return XCTFail("Expected access denial") }
            }
            store.write(late, for: "member", at: denied)
            XCTAssertNil(store.readFresh(at: denied))
        }
        let next = denied.addingTimeInterval(1)
        let new = RecentAgentsSnapshot(rows: [], checkedAt: next)
        let confirmed = try store.confirm(new, for: "member", at: next)
        XCTAssertEqual(confirmed.rows, [])
        store.discard(for: "member", through: denied)
        XCTAssertEqual(store.readFresh(at: next)?.checkedAt, next)
    }

    private func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: WidgetSnapshotService.recentAgents.name,
         kSecAttrAccount as String: account]
    }
}
