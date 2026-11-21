import Observation
import XCTest
@testable import Iterate

final class AgentDirectoryTests: XCTestCase {
    @MainActor
    func testCatalogUsesRecentActivityAndFallsBackToPathForUntitledAgents() throws {
        let wire = NativeMindTransport.encodeLiteral([
            ["path": "/agents/travel", "title": "Travel plans", "lastActivityAt": "2026-11-20T13:00:00.550Z"],
            ["path": "/agents/notes/daily", "title": NSNull(), "createdAt": "2026-11-21T13:00:00Z"],
            ["path": "/agents/travel", "title": "Duplicate"],
            ["path": "/agents/archive", "title": "  "]
        ] as [[String: Any]])
        let agents = try IterateAgent.catalog(from: wire)
        XCTAssertEqual(agents.map(\.name), ["daily", "Travel plans", "archive"])
        XCTAssertEqual(agents.map(\.id), ["/agents/notes/daily", "/agents/travel", "/agents/archive"])
        XCTAssertTrue(try IterateAgent.catalog(from: NativeMindTransport.encodeLiteral([] as [Any])).isEmpty)
        XCTAssertThrowsError(try IterateAgent.catalog(from: ["pipeline", 1]))
        XCTAssertThrowsError(try IterateAgent.catalog(from: NativeMindTransport.encodeLiteral([["path": "/secrets"]])))
    }

    func testAgentLinksSelectTheNativeContextVerbatim() throws {
        for link in ["\(Deployment.current.urlScheme)://agents/check-routes/example", "https://\(Deployment.current.dashHost)/agents/agents/check-routes/example"] {
            XCTAssertEqual(IterateAgent.linkedPath(try XCTUnwrap(URL(string: link))), "/agents/check-routes/example")
        }
        let escaped = try XCTUnwrap(URL(string: "https://\(Deployment.current.dashHost)/agents/agents/Team%20A/what%3F%23100%25+ready"))
        XCTAssertEqual(IterateAgent.linkedPath(escaped), "/agents/Team A/what?#100%+ready")
        let unusual = try XCTUnwrap(URL(string: "https://\(Deployment.current.dashHost)/agents?contextPath=%2Fagents%2Fa%2F..%2Fb%2Bc"))
        XCTAssertEqual(IterateAgent.linkedPath(unusual), "/agents/a/../b+c")
        for link in ["https://\(Deployment.current.dashHost)/agents", "https://other.\(Deployment.current.dashHost)/agents/agents/a",
                     "https://x@\(Deployment.current.dashHost)/agents/agents/a", "https://\(Deployment.current.dashHost)/agents?contextPath=/private"] {
            XCTAssertNil(URL(string: link).flatMap(IterateAgent.linkedPath))
        }
    }

    @MainActor
    func testPairedDirectoryDisplaysCachedRowsWithoutOpeningASocket() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CredentialStore(account: "offline-catalog-" + UUID().uuidString)
        defer { try? store.clear(); try? FileManager.default.removeItem(at: file) }
        let session = Credentials(clientID: "cached-client", accessToken: "fixture", refreshToken: nil,
                                  expiresAt: .distantFuture)
        try store.save(session)
        let cache = AgentDirectoryCache(file: file, credentials: store)
        let rows = [IterateAgent(path: "/agents/notes", name: "Notes", lastActive: nil)]
        try await cache.save(rows, for: session.clientID)

        let directory = AgentDirectory(cache: cache)
        directory.selectSession(session.clientID)
        let displayed = XCTestExpectation(description: "Cached agents became available")
        withObservationTracking {
            _ = directory.rows
        } onChange: { displayed.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [displayed], timeout: 5)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(directory.rows, rows)
    }

    func testProtectedCacheRestoresOnlyTheMatchingPairingAndRejectsLateWritesAfterDisconnect() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CredentialStore(account: "agent-list-fixture-" + UUID().uuidString)
        defer { try? store.clear(); try? FileManager.default.removeItem(at: file) }
        let first = Credentials(clientID: "first", accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture)
        try store.save(first)
        let cache = AgentDirectoryCache(file: file, credentials: store)
        let rows = [IterateAgent(path: "/agents/test", name: "Test", lastActive: nil)]
        try await cache.save(rows, for: first.clientID)
        let saved = await cache.load(for: first.clientID)
        let other = await cache.load(for: "other")
        XCTAssertEqual(saved, rows)
        XCTAssertNil(other)
        let otherWorkspace = AgentDirectoryCache(file: file, credentials: CredentialStore(account: "another-workspace"))
        let reusedClientID = await otherWorkspace.load(for: first.clientID)
        XCTAssertNil(reusedClientID)
        try store.clear()
        do {
            try await cache.save(rows, for: first.clientID)
            XCTFail("A disconnected session wrote an agent list.")
        } catch AssistantIssue.changedSession {}
        await cache.remove(for: first.clientID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
