import Observation
import XCTest
@testable import Iterate

final class AgentDirectoryTests: XCTestCase {
    func testCompactActivityAgeUsesWholeMinutesHoursAndDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(TimeInterval, String)] = [
            (-60, String(localized: "Now")), (59, String(localized: "Now")),
            (60, "1m"), (1_259, "20m"), (3_599, "59m"), (3_600, "1h"),
            (54_000, "15h"), (86_399, "23h"), (86_400, "1d"), (172_800, "2d")
        ]
        for (elapsed, label) in cases {
            XCTAssertEqual(AgentActivityAge.compactLabel(for: now.addingTimeInterval(-elapsed), relativeTo: now), label)
        }
    }

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
        try await cache.save(rows, archivedPaths: [], for: session.clientID)

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

    func testWidgetRowsOpenTheExactAgentAndTheBackgroundOpensTheDirectory() throws {
        let home = NativeDestination.agents.url
        XCTAssertEqual(home.absoluteString, Deployment.current.urlScheme + "://agents")
        XCTAssertEqual(NativeDestination(url: home), .agents)
        XCTAssertNil(IterateAgent.linkedPath(home))
        for path in ["/agents/travel", "/agents/Þór/🚆?#100%+ &=", "/agents/a/../%2F"] {
            let agent = IterateAgent(path: path, name: "Display name", lastActive: nil)
            let url = try XCTUnwrap(agent.widgetURL)
            XCTAssertEqual(url.host, "agents")
            XCTAssertEqual(url.scheme, Deployment.current.urlScheme)
            XCTAssertEqual(IterateAgent.linkedPath(url), path)
            XCTAssertNil(NativeDestination(url: url))
        }
        for path in ["/other/agent", "/agents/"] {
            XCTAssertNil(IterateAgent(path: path, name: "Invalid", lastActive: nil).widgetURL)
        }
        for url in ["\(Deployment.current.urlScheme)://agents?contextPath=/private",
                    "\(Deployment.current.urlScheme)://agents?contextPath=/agents/one&contextPath=/agents/two",
                    "\(Deployment.current.urlScheme)://agents/extra?contextPath=/agents/one",
                    "\(Deployment.current.urlScheme)://other@agents?contextPath=/agents/one",
                    "\(Deployment.current.urlScheme)://agents?contextPath=/agents/two#part"] {
            let link = try XCTUnwrap(URL(string: url))
            XCTAssertNil(IterateAgent.linkedPath(link))
            XCTAssertNil(NativeDestination(url: link))
        }
    }

    @MainActor
    func testRecentAgentsFillAvailableRowsAfterExcludingTheMembersArchive() throws {
        let wire = NativeMindTransport.encodeLiteral([
            ["path": "/agents/old", "createdAt": "2026-11-01T00:00:00Z"],
            ["path": "/agents/new", "lastActivityAt": "2026-11-21T13:00:00Z"],
            ["path": "/agents/hidden", "lastActivityAt": "2026-11-22T13:00:00Z"],
            ["path": "/agents/tied", "createdAt": "2026-11-21T13:00:00Z"],
            ["path": "/agents/undated"]
        ])
        let catalog = try IterateAgent.catalog(from: wire)
        let archived: Set<String> = ["/agents/hidden", "/agents/old"]
        XCTAssertEqual(IterateAgent.recent(in: catalog, excluding: archived, limit: 2).map(\.path),
                       ["/agents/new", "/agents/tied"])
        XCTAssertEqual(IterateAgent.recent(in: catalog, excluding: archived, limit: 10).last?.path, "/agents/undated")
        XCTAssertTrue(IterateAgent.recent(in: catalog, excluding: Set(catalog.map(\.path)), limit: 2).isEmpty)
    }

    func testProtectedCacheRestoresOnlyTheMatchingPairingAndRejectsLateWritesAfterDisconnect() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CredentialStore(account: "agent-list-fixture-" + UUID().uuidString)
        defer { try? store.clear(); try? FileManager.default.removeItem(at: file) }
        let first = Credentials(clientID: "first", accessToken: "fixture", refreshToken: nil, expiresAt: .distantFuture)
        try store.save(first)
        let cache = AgentDirectoryCache(file: file, credentials: store)
        let rows = [IterateAgent(path: "/agents/test", name: "Test", lastActive: nil)]
        let archived: Set<String> = ["/agents/test"]
        try await cache.save(rows, archivedPaths: archived, for: first.clientID)
        let saved = await cache.load(for: first.clientID)
        let other = await cache.load(for: "other")
        XCTAssertEqual(saved?.rows, rows)
        XCTAssertEqual(saved?.archivedPaths, archived)
        XCTAssertNil(other)
        let otherWorkspace = AgentDirectoryCache(file: file, credentials: CredentialStore(account: "another-workspace"))
        let reusedClientID = await otherWorkspace.load(for: first.clientID)
        XCTAssertNil(reusedClientID)
        try store.clear()
        do {
            try await cache.save(rows, archivedPaths: archived, for: first.clientID)
            XCTFail("A disconnected session wrote an agent list.")
        } catch AssistantIssue.changedSession {}
        await cache.remove(for: first.clientID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testArchiveGestureOwnsOnlyTheRightwardHorizontalAxis() {
        XCTAssertTrue(AgentArchiveKinematics.accepts(x: 160, y: 10, revealed: false))
        XCTAssertFalse(AgentArchiveKinematics.accepts(x: 25, y: 120, revealed: false))
        XCTAssertFalse(AgentArchiveKinematics.accepts(x: -160, y: 10, revealed: false))
        XCTAssertTrue(AgentArchiveKinematics.accepts(x: -160, y: 10, revealed: true))
    }

    func testArchiveReleaseCombinesDistanceAndMomentumAndClearsTheEdge() {
        let width: CGFloat = 402
        XCTAssertEqual(AgentArchiveKinematics.release(offset: 24, velocity: 0, width: width), .close)
        XCTAssertEqual(AgentArchiveKinematics.release(offset: 72, velocity: 20, width: width), .reveal)
        XCTAssertEqual(AgentArchiveKinematics.release(offset: 108, velocity: 920, width: width), .archive)
        XCTAssertEqual(AgentArchiveKinematics.release(offset: 285, velocity: 0, width: width), .archive)
        XCTAssertEqual(AgentArchiveKinematics.release(offset: 95, velocity: -700, width: width), .close)
        let target = AgentArchiveKinematics.exitTarget(width: width)
        XCTAssertGreaterThan(target, width)
        XCTAssertEqual(AgentArchiveKinematics.springVelocity(900, from: 134, to: target), 3, accuracy: 0.001)
        XCTAssertLessThan(AgentArchiveKinematics.springVelocity(120, from: 80, to: 0), 0)
    }

    @MainActor
    func testArchiveWaitsForSuccessAndAllowsRetryAfterFailure() async throws {
        let directory = AgentDirectory()
        directory.selectSession(UUID().uuidString)
        let path = "/agents/test"
        do {
            try await directory.archive(path, onConfirmed: { XCTFail("A failed archive began its exit.") }) {
                XCTAssertEqual(directory.archivingPaths, [path])
                XCTAssertTrue(directory.archivedPaths.isEmpty)
                try await directory.archive(path) { XCTFail("A duplicate archive was sent.") }
                throw AssistantIssue.unavailable
            }
            XCTFail("Archive failure was swallowed.")
        } catch AssistantIssue.unavailable {}
        XCTAssertTrue(directory.archivingPaths.isEmpty)
        XCTAssertTrue(directory.archivedPaths.isEmpty)
        var transportCompleted = false
        var exitStarted = false
        try await directory.archive(path, onConfirmed: {
            XCTAssertTrue(transportCompleted)
            XCTAssertTrue(directory.archivedPaths.contains(path))
            XCTAssertTrue(directory.archivingPaths.contains(path))
            exitStarted = true
        }) {
            transportCompleted = true
        }
        XCTAssertTrue(exitStarted)
        XCTAssertEqual(directory.archivedPaths, [path])
        XCTAssertTrue(directory.archivingPaths.isEmpty)
    }

    @MainActor
    func testArchiveDoesNotAffectAReplacementPairing() async throws {
        let directory = AgentDirectory()
        directory.selectSession(UUID().uuidString)
        let path = "/agents/test"
        do {
            try await directory.archive(path, onConfirmed: { XCTFail("A late archive began its exit.") }) {
                directory.selectSession(UUID().uuidString)
            }
            XCTFail("A late archive affected another session.")
        } catch is CancellationError {}
        XCTAssertTrue(directory.archivedPaths.isEmpty)
        XCTAssertTrue(directory.archivingPaths.isEmpty)
    }
}
