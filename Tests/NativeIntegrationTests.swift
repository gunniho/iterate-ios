import XCTest
@testable import Iterate

final class NativeIntegrationTests: XCTestCase {
    @MainActor
    func testUpgradeClearsOnlyTaskFilesAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let retired = ["AssistantCache/runs.json", "AssistantCache/glance.json", "AssistantCache/cache.lock",
                       "IterateReplies/reply", "VisualMemoryTerms/labels", "Library/Caches/IterateFileVersions/version"]
        let kept = ["CaptureDrafts/thought", "AssistantCache/installation.json", "token-renewal.lock"]
        for name in retired + kept {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: file)
        }
        try TaskInboxUpgrade.removeCachedResults(in: root)
        try TaskInboxUpgrade.removeCachedResults(in: root)
        for name in retired { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
        for name in kept { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Data(name.utf8)) }
    }

    func testAssistantAndCaptureLinksOpenNativelyAndPreviousResultLinksOpenOnTheWeb() {
        XCTAssertEqual(NativeDestination.yourMove.url.absoluteString, Deployment.current.urlScheme + "://your-move")
        XCTAssertEqual(NativeDestination(url: NativeDestination.yourMove.url), .yourMove)
        for destination in [NativeDestination.newAgent, .talk, .capture, .camera, .briefing] {
            XCTAssertEqual(NativeDestination(url: destination.url), destination)
            let schemeURL = URL(string: Deployment.current.urlScheme + "://" + destination.url.lastPathComponent)!
            XCTAssertEqual(NativeDestination(url: schemeURL), destination)
        }
        let id = UUID()
        let web = URL(string: "https://\(Deployment.current.apexHost)/runs/" + id.uuidString.lowercased())!
        for prefix in ["https://\(Deployment.current.apexHost)/runs/", "https://\(Deployment.current.apexHost)/read/", "\(Deployment.current.urlScheme)://runs/"] {
            XCTAssertEqual(URL(string: prefix + id.uuidString).flatMap(NativeDestination.init(url:)), .web(web))
        }
        XCTAssertEqual(NativeDestination(url: URL(string: "\(Deployment.current.urlScheme)://inbox")!), .web(URL(string: "https://\(Deployment.current.apexHost)/runs")!))
        for value in ["https://\(Deployment.current.apexHost).example/talk", "https://\(Deployment.current.apexHost):443/talk", "https://x@\(Deployment.current.apexHost)/talk",
                      "http://\(Deployment.current.apexHost)/talk", "https://\(Deployment.current.apexHost)/runs/invalid", "\(Deployment.current.urlScheme)://talk/extra"] {
            XCTAssertNil(URL(string: value).flatMap(NativeDestination.init(url:)))
        }
    }

    @MainActor
    func testPendingQuestionFetchesOnlyItsOwnReplyAndStopsOnceAnswered() async throws {
        let id = UUID()
        let ready = makeRun(id: id, status: .completed, response: "The train leaves at noon.")
        var fetched: [UUID] = []
        let answer = try await AssistantCenter.shared.awaitAnswer(for: makeRun(id: id, status: .queued),
            until: .now.advanced(by: .seconds(10))) { requested in
                fetched.append(requested)
                return ready
            }
        XCTAssertEqual(fetched, [id])
        XCTAssertEqual(answer.shortcutAnswer, "The train leaves at noon.")
        let complete = try await AssistantCenter.shared.awaitAnswer(for: ready, until: .now) { _ in
            XCTFail("A full answer must not trigger another read.")
            return ready
        }
        XCTAssertEqual(complete, ready)
    }

    @MainActor
    func testInterruptedQuestionKeepsItsOriginalWebLinkAndLongAnswersAreFetchedInFull() async throws {
        let id = UUID()
        let pending = makeRun(id: id, status: .running, response: "Previous turn")
        let timeout = try await AssistantCenter.shared.awaitAnswer(for: pending, until: .now)
        XCTAssertTrue(timeout.isPending)
        XCTAssertTrue(timeout.shortcutAnswer.contains(id.uuidString.lowercased()))
        XCTAssertFalse(timeout.shortcutAnswer.contains("Previous turn"))
        let clarification = makeRun(id: id, status: .needsInput, response: "Which day?")
        XCTAssertTrue(clarification.shortcutAnswer.hasPrefix("Which day?"))
        XCTAssertEqual(makeRun(id: id, status: .failed, response: "Network unavailable").answerText, "Network unavailable")

        let full = makeRun(id: id, status: .completed, response: "Train 🚆")
        var preview = full
        preview.responseLength = full.response?.utf16.count
        preview.response = "Train"
        XCTAssertFalse(preview.hasFullResponse)
        let hydrated = try await AssistantCenter.shared.awaitAnswer(for: preview, until: .now) { requested in
            XCTAssertEqual(requested, id)
            return full
        }
        XCTAssertEqual(hydrated, full)
    }

    @MainActor
    func testLiteralArraysRoundTripAndRejectProtocolOperationsInResults() throws {
        let object: [String: Any] = ["rows": [["names": ["pipeline", "resolve"]]], "empty": []]
        let encoded = NativeMindTransport.encodeLiteral(object)
        let decoded = try NativeMindTransport.decodeLiteral(encoded)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: decoded, options: .sortedKeys))
        XCTAssertThrowsError(try NativeMindTransport.decodeLiteral(["pipeline", 1]))
    }

    @MainActor
    func testBackendDatesAndUnicodeLengthsDecodeAcrossClientVersions() throws {
        let json = """
        {"id":"00112233-4455-4677-8899-aabbccddeeff","kind":"ask","title":"Today","prompt":"My question",
         "status":"completed","response":"🌍","responseLength":2,
         "createdAt":"2026-11-20T11:00:00Z","updatedAt":"2026-11-20T11:00:00.450Z"}
        """
        let run = try AssistantCenter.decoder().decode(IterateRun.self, from: Data(json.utf8))
        XCTAssertTrue(run.hasFullResponse)
        XCTAssertEqual(run.updatedAt.timeIntervalSince(run.createdAt), 0.45, accuracy: 0.0001)
    }

    private func makeRun(id: UUID, status: RunStatus, response: String? = nil) -> IterateRun {
        .init(id: id, kind: "ask", title: "Trains", prompt: "When is the train?", status: status,
              response: response, createdAt: .distantPast, updatedAt: .now)
    }
}
