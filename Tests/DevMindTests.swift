import XCTest
@testable import Iterate

/// The app against the local stand-in mind (Server/tests/dev-mind.mjs), over the real socket:
///
///     node Server/tests/dev-mind.mjs &
///     TEST_RUNNER_ITERATE_DEV_MIND=http://127.0.0.1:8787 xcodebuild -project Iterate.xcodeproj -scheme Iterate \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test \
///       -only-testing:IterateTests/SpeedTests -only-testing:IterateTests/ConversationFlowTests
///
/// Without the stand-in these tests are skipped. With it, run only these: the other tests expect the real host.
@MainActor
class DevMindTestCase: XCTestCase {
    struct Network { let name: String; let rtt: Int; let mbps: Int }
    static let networks = [Network(name: "wifi", rtt: 30, mbps: 50), Network(name: "lte", rtt: 80, mbps: 8)]
    static let runs = 3
    let member = "dev-mind-test"
    private let store = CredentialStore(account: "dev-mind-" + UUID().uuidString)
    private var open: [MindConnection] = []
    private var results: [String: [Double]] = [:]

    override func setUp() async throws {
        try XCTSkipUnless(Deployment.current.issuer.host == "127.0.0.1", "Start the dev mind and set ITERATE_DEV_MIND to run the app against it.")
        try store.save(Credentials(clientID: member, accessToken: "dev", refreshToken: nil, expiresAt: .distantFuture))
        AgentChatChannel.transcriptRouteMissing = false
        try await configure(["rtt": 30, "mbps": 50, "legacy": false, "offline": false])
    }

    override func tearDown() async throws {
        for connection in open { await leave(connection) }
        open = []
        try? store.clear()
    }

    // MARK: The stand-in's controls

    func each(_ scenario: @escaping @MainActor (Network) async throws -> Void) async throws {
        for network in Self.networks {
            try await configure(["rtt": network.rtt, "mbps": network.mbps])
            for _ in 0..<Self.runs {
                try await scenario(network)
                for connection in open { await leave(connection) }
                open = []
            }
        }
        for (key, samples) in results.sorted(by: { $0.key < $1.key }) {
            let median = samples.sorted()[samples.count / 2]
            print("SPEED \(key) = \(Int(median.rounded()))")
        }
    }

    func report(_ scenario: String, _ network: Network, _ values: [String: Double]) {
        for (metric, value) in values { results["\(scenario) | \(network.name) | \(metric)", default: []].append(value) }
    }

    @discardableResult
    func control(_ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: Deployment.current.issuer.appendingPathComponent("dev/" + path))
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func configure(_ values: [String: Any]) async throws { try await control("config", values) }

    /// Seeded logs, every context cold. Returns the agents, most recent first.
    func reset() async throws -> [String] {
        try await control("reset", [:])
        let stats = try await control("stats")
        return try XCTUnwrap(stats["agents"] as? [String])
    }

    func wire() async throws -> (bytes: Int, calls: [String]) {
        let stats = try await control("stats")
        return (stats["bytesOut"] as? Int ?? 0, stats["calls"] as? [String] ?? [])
    }

    // MARK: The app's side

    func connected() async throws -> MindConnection {
        let connection = MindConnection(store: store)
        open.append(connection)
        connection.activate()
        try await wait("connected") {
            if case .failed(let reason) = connection.phase { XCTFail(reason); return true }
            return connection.agentLink != nil
        }
        return connection
    }

    private func leave(_ connection: MindConnection) async {
        let saved = try? store.load()
        connection.disconnect()
        let deadline = ContinuousClock.now + .seconds(5)
        while connection.phase != .disconnected, ContinuousClock.now < deadline {
            if case .failed = connection.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let saved { try? store.save(saved) }
    }

    /// Opens an agent as its screen does, and says when words appeared and when sending became possible.
    func visit(_ path: String, in connection: MindConnection, on link: MindSocket) async throws
        -> (chat: AgentConversation, shown: Double, live: Double) {
        let tapped = ContinuousClock.now
        let chat = Build.conversation(path, in: connection)
        let screen = Task { await chat.open(on: link) }
        var shown: Double?
        try await wait("conversation live") {
            if shown == nil, chat.floor != nil { shown = Self.ms(since: tapped) }
            if let issue = chat.readError { XCTFail(issue); return true }
            return chat.connected
        }
        await screen.value
        return (chat, shown ?? Self.ms(since: tapped), Self.ms(since: tapped))
    }

    final func wait(_ what: String, seconds: Int = 20, until done: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !done() {
            guard ContinuousClock.now < deadline else { throw MindRPCError(message: "Timed out waiting for: \(what)") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }
}

/// Times what a person waits for. Each line it prints starts with SPEED.
final class SpeedTests: DevMindTestCase {

    func testOpeningAConversation() async throws {
        try await each { network in
            let agents = try await self.reset()
            let connection = try await self.connected()
            let link = try XCTUnwrap(connection.agentLink)
            let before = try await self.wire()
            let (chat, shown, live) = try await self.visit(agents[0], in: connection, on: link)
            let after = try await self.wire()
            self.report("open cold", network, ["content": shown, "live": live, "messages": Double(chat.messages.count),
                                               "kb": Double(after.bytes - before.bytes) / 1024,
                                               "calls": Double(after.calls.count - before.calls.count)])
            chat.close()

            let (again, reshown, relive) = try await self.visit(agents[0], in: connection, on: link)
            self.report("open again", network, ["content": reshown, "live": relive, "messages": Double(again.messages.count)])
            again.close()

            // An agent whose latest work said nothing for a long while.
            let (quiet, _, _) = try await self.visit(agents[3], in: connection, on: link)
            self.report("open after long work", network, ["messages": Double(quiet.messages.count)])
            quiet.close()
        }
    }

    func testOpeningFromTheListAfterAMoment() async throws {
        try await each { network in
            let agents = try await self.reset()
            let connection = try await self.connected()
            let link = try XCTUnwrap(connection.agentLink)
            await Build.listAppeared(connection, on: link)
            try await Task.sleep(for: .seconds(2))
            let (chat, shown, live) = try await self.visit(agents[1], in: connection, on: link)
            self.report("open from list", network, ["content": shown, "live": live, "messages": Double(chat.messages.count)])
            chat.close()
        }
    }

    func testLaunchToAFreshAgentList() async throws {
        try await each { network in
            _ = try await self.reset()
            let started = ContinuousClock.now
            let connection = try await self.connected()
            let link = try XCTUnwrap(connection.agentLink)
            let linked = Self.ms(since: started)
            await connection.directory.refresh(on: link)
            XCTAssertNotNil(connection.directory.rows)
            XCTAssertNil(connection.directory.refreshError)
            self.report("launch", network, ["connected": linked, "list": Self.ms(since: started)])
        }
    }

    func testComingBackFromAnotherApp() async throws {
        try await each { network in
            let agents = try await self.reset()
            let connection = try await self.connected()
            let chat = Build.conversation(agents[0], in: connection)
            // What the conversation screen's task does as its link comes and goes.
            var screen: Task<Void, Never>?
            func follow(_ link: MindSocket?) {
                screen?.cancel()
                screen = Task { await chat.open(on: link) }
            }
            follow(connection.agentLink)
            try await self.wait("conversation live") { chat.connected }

            connection.background()
            if Build.screenClosesWhenInactive { follow(nil) }
            var seen = connection.agentLink.map(ObjectIdentifier.init)
            let away = ContinuousClock.now
            while Self.ms(since: away) < 3_000 {
                try await Task.sleep(for: .milliseconds(20))
                let now = connection.agentLink.map(ObjectIdentifier.init)
                if now != seen { seen = now; follow(connection.agentLink) }
            }
            let returned = ContinuousClock.now
            connection.activate()
            if Build.screenClosesWhenInactive { follow(connection.agentLink) }
            try await self.wait("conversation live again") {
                let now = connection.agentLink.map(ObjectIdentifier.init)
                if now != seen { seen = now; follow(connection.agentLink) }
                return chat.connected && connection.agentLink != nil
            }
            self.report("return after 3 s away", network, ["live": Self.ms(since: returned)])
            screen?.cancel()
            chat.close()
        }
    }

    func testStartingACall() async throws {
        try await each { network in
            let agents = try await self.reset()
            let connection = try await self.connected()
            let link = try XCTUnwrap(connection.agentLink)
            let voice = LiveVoice(permission: { true }, makeAudio: { SlowAudio() })
            voice.attach(to: link, prepareImmediately: false)
            let tapped = ContinuousClock.now
            voice.start(for: .agent(path: agents[2], draftID: nil))
            try await self.wait("call live") {
                if case .failed(let reason) = voice.phase { XCTFail(reason); return true }
                return voice.phase == .live
            }
            self.report("call", network, ["live": Self.ms(since: tapped)])
            voice.hangUp()
            try await self.wait("call ended") { voice.phase == .ready || voice.phase == .preparing }
            voice.detach(from: link)
        }
    }

    func testRecoveringWhenTheMindComesBack() async throws {
        _ = try await reset()
        let connection = try await connected()
        try await configure(["offline": true])
        try await wait("gave up", seconds: 30) {
            if case .failed = connection.phase { return true }
            return false
        }
        try await configure(["offline": false])
        let back = ContinuousClock.now
        var recovered: Double?
        while Self.ms(since: back) < 20_000 {
            if connection.agentLink != nil { recovered = Self.ms(since: back); break }
            try await Task.sleep(for: .milliseconds(50))
        }
        print("SPEED recover | any | " + (recovered.map { "reconnected=\(Int($0))" } ?? "reconnected=never (waited 20 s)"))
    }
}

/// How this build's screens reach a conversation and the list.
@MainActor
enum Build {
    static let screenClosesWhenInactive = false
    static func conversation(_ path: String, in connection: MindConnection) -> AgentConversation {
        connection.conversations.conversation(for: path)
    }
    static func listAppeared(_ connection: MindConnection, on link: MindSocket) async {
        await connection.directory.refresh(on: link)
        connection.preloadRecentConversations()
    }
}

/// A microphone and speaker that take as long to open as an iPhone's voice processing does.
@MainActor
final class SlowAudio: VoiceAudioIO {
    private var source: Task<Void, Never>?

    func start(interrupted: @escaping @MainActor (String) -> Void) async throws -> AsyncThrowingStream<Data, Error> {
        try await Task.sleep(for: .milliseconds(400))
        let (stream, sink) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(40))
        source = Task {
            defer { sink.finish() }
            while !Task.isCancelled {
                sink.yield(Data(count: CallAudio.frameBytes))
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
        return stream
    }

    func play(_ pcm: Data, clear: Bool) {}
    func stop() { source?.cancel() }
}

/// What a conversation must still do now that it is kept, preloaded and read through the facet.
final class ConversationFlowTests: DevMindTestCase {
    func testAKeptConversationCatchesUpStaysLiveSendsAndPagesBack() async throws {
        let agents = try await reset()
        let connection = try await connected()
        let link = try XCTUnwrap(connection.agentLink)
        let (chat, _, _) = try await visit(agents[0], in: connection, on: link)
        let first = chat.messages
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.map(\.id), first.map(\.id).sorted())
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)

        // Words that arrive while the screen is closed are there on return, without reading the log again.
        chat.close()
        try await control("say", ["path": agents[0], "text": "Said while you were away"])
        let before = try await wire()
        let (again, _, _) = try await visit(agents[0], in: connection, on: link)
        XCTAssertTrue(again === chat)
        try await wait("missed reply") { chat.messages.last?.text == "Said while you were away" }
        let reopening = try await wire().calls.dropFirst(before.calls.count)
        XCTAssertFalse(reopening.contains { $0.contains("transcript") }, "\(reopening)")
        XCTAssertEqual(Array(chat.messages.dropLast()), first)

        try await control("say", ["path": agents[0], "text": "Said while you watched"])
        try await wait("live reply") { chat.messages.last?.text == "Said while you watched" }

        chat.draft = "A question from the test"
        await chat.sendDraft(using: connection)
        XCTAssertNil(chat.sendError)
        XCTAssertEqual(chat.draft, "")
        try await wait("own message") { chat.messages.contains { $0.text == "A question from the test" && $0.role == .input } }
        try await wait("agent reply") { chat.messages.last?.text.hasPrefix("Understood: A question") == true }

        // Earlier pages join without gaps or repeats, down to the first message.
        var floor = try XCTUnwrap(chat.floor)
        XCTAssertGreaterThan(floor, 0)
        while floor > 0 {
            let held = chat.messages.count
            await chat.loadEarlier()
            XCTAssertNil(chat.readError)
            let next = try XCTUnwrap(chat.floor)
            XCTAssertLessThan(next, floor)
            XCTAssertGreaterThanOrEqual(chat.messages.count, held)
            floor = next
        }
        XCTAssertEqual(chat.messages.map(\.id), chat.messages.map(\.id).sorted())
        XCTAssertEqual(Set(chat.messages.map(\.id)).count, chat.messages.count)
        XCTAssertEqual(chat.messages.filter { $0.text.hasPrefix("Question ") }.count, 60)
        XCTAssertEqual(chat.messages.first?.text.hasPrefix("Question 1:"), true)
        chat.close()
    }

    func testAConversationOnTwoScreensStaysLiveUntilBothLeave() async throws {
        let agents = try await reset()
        let connection = try await connected()
        let chat = connection.conversations.conversation(for: agents[2])
        let one = UUID(), two = UUID()
        await chat.open(on: connection.agentLink, for: one)
        await chat.open(on: connection.agentLink, for: two)
        XCTAssertTrue(chat.connected)
        chat.leave(one)
        XCTAssertTrue(chat.connected)
        try await control("say", ["path": agents[2], "text": "Still listening"])
        try await wait("live reply") { chat.messages.last?.text == "Still listening" }
        chat.leave(two)
        XCTAssertFalse(chat.connected)
    }

    func testANewAgentStartsOnItsFirstMessageAndHearsTheReply() async throws {
        _ = try await reset()
        let connection = try await connected()
        let chat = AgentConversation()
        chat.draft = "Start something new"
        await chat.sendDraft(using: connection)
        XCTAssertNil(chat.sendError)
        XCTAssertFalse(chat.isNewDraft)
        XCTAssertEqual(chat.firstMessageTitle, "Start something new")
        await chat.open(on: connection.agentLink)
        XCTAssertTrue(chat.connected)
        try await wait("first reply") { chat.messages.last?.text == "Understood: Start something new" }
        XCTAssertEqual(chat.messages.map(\.text), ["Start something new", "Understood: Start something new"])
        chat.close()
    }

    func testAnOlderMindStillOpensAndPagesConversations() async throws {
        let agents = try await reset()
        try await configure(["legacy": true])
        let connection = try await connected()
        let link = try XCTUnwrap(connection.agentLink)
        let (chat, _, _) = try await visit(agents[0], in: connection, on: link)
        XCTAssertTrue(AgentChatChannel.transcriptRouteMissing)
        XCTAssertFalse(chat.messages.isEmpty)
        let held = chat.messages.count
        await chat.loadEarlier()
        XCTAssertNil(chat.readError)
        XCTAssertGreaterThan(chat.messages.count, held)
        XCTAssertEqual(chat.messages.map(\.id), chat.messages.map(\.id).sorted())
        // Once known, the missing route is not asked for again.
        let before = try await wire()
        let (other, _, _) = try await visit(agents[1], in: connection, on: link)
        XCTAssertFalse(other.messages.isEmpty)
        let calls = try await wire().calls.dropFirst(before.calls.count)
        XCTAssertFalse(calls.contains { $0.contains("transcript") }, "\(calls)")
        chat.close()
        other.close()
    }

    func testYourMoveReadsTheInboxAMindAnswers() async throws {
        _ = try await reset()
        let connection = try await connected()
        let link = try XCTUnwrap(connection.agentLink)
        let facet = NativeMindTransport()
        let read = try await facet.invoke("GET", path: "/approvals?signatures=1", body: nil, over: link)
        let inbox = try AssistantCenter.decoder().decode(ApprovalInbox.self, from: read)
        XCTAssertEqual(inbox.items.map(\.kind), [.email, .action, .signature])
        XCTAssertTrue(inbox.items.allSatisfy { ApprovalReviewLink.item($0.reviewURL) != nil })
        XCTAssertEqual(inbox.decided.map(\.outcome), [.approved])
        // A phone from before signature requests is not sent one.
        let earlier = try await facet.invoke("GET", path: "/approvals", body: nil, over: link)
        XCTAssertEqual(try AssistantCenter.decoder().decode(ApprovalInbox.self, from: earlier).items.map(\.kind), [.email, .action])
        let summary = try await facet.invoke("GET", path: "/your-move/summary", body: nil, over: link)
        let counts = try JSONDecoder().decode(YourMoveCounts.self, from: summary)
        XCTAssertEqual(counts.approvalCount, 3)
        XCTAssertEqual(counts.questionCount, 0)
    }

    func testTheListPreloadsItsFirstAgentsAndAPairingChangeForgetsThem() async throws {
        let agents = try await reset()
        let connection = try await connected()
        let link = try XCTUnwrap(connection.agentLink)
        await connection.directory.refresh(on: link)
        connection.preloadRecentConversations()
        let top = agents.prefix(3).map { connection.conversations.conversation(for: $0) }
        try await wait("preloaded") { top.allSatisfy { $0.floor != nil } }
        XCTAssertTrue(top.allSatisfy { !$0.messages.isEmpty && !$0.connected })
        XCTAssertNil(connection.conversations.conversation(for: agents[5]).floor)

        // Opening a preloaded agent goes live without reading its log again.
        let before = try await wire()
        let (chat, _, _) = try await visit(agents[0], in: connection, on: link)
        let calls = try await wire().calls.dropFirst(before.calls.count)
        XCTAssertFalse(calls.contains { $0.contains("transcript") }, "\(calls)")
        chat.close()

        connection.disconnect()
        try await wait("unpaired") { connection.pairing == .unpaired }
        XCTAssertFalse(connection.conversations.conversation(for: agents[0]) === chat)
    }
}
