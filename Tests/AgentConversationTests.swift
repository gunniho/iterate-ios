import XCTest
@testable import Iterate

final class AgentConversationTests: XCTestCase {
    func testMermaidPartsPreserveMarkdownAndIgnoreOtherFences() {
        let hidden = "\u{60}\u{60}\u{60}\u{60}text\n\u{60}\u{60}\u{60}mermaid\nflowchart TD\nA --> B\n\u{60}\u{60}\u{60}\n\u{60}\u{60}\u{60}\u{60}"
        let diagram = "~~~Mermaid\nflowchart TD\nA --> B\n~~~"
        let unfinished = "\u{60}\u{60}\u{60}mermaid\n[not a link](https://example.invalid)"
        XCTAssertEqual(AgentReplyPart.parse("**Before**\n" + hidden + "\n" + diagram + "\n**After**\n" + unfinished), [
            .markdown("**Before**\n" + hidden), .diagram(source: "flowchart TD\nA --> B", fallback: diagram),
            .markdown("**After**"), .literal(unfinished),
        ])
        let plain = "**Markdown**\r\nwith \u{60}mermaid\u{60} inline"
        XCTAssertEqual(AgentReplyPart.parse(plain), [.markdown(plain)])
    }

    func testOnlyDeliveredAssistantRepliesCanShowDiagrams() throws {
        let chart = "~~~mermaid\nflowchart TD\nA --> B\n~~~"
        let reply = try XCTUnwrap(AgentChatMessage(event: typingEvent(1, AgentChatMessage.replied, ["message": chart])))
        XCTAssertTrue(reply.allowsMermaid)
        let user = try XCTUnwrap(AgentChatMessage(event: typingEvent(2, AgentChatMessage.received, ["message": chart])))
        XCTAssertFalse(user.allowsMermaid)
        XCTAssertNil(AgentChatMessage(event: typingEvent(3, "events.iterate.com/agent/llm-response-frame", ["responseDelta": chart])))
    }

    @MainActor
    func testMermaidRendersRepresentativeMailFlowToBitmapAndFallsBackOnFailure() async throws {
        let renderer = AgentMermaidRenderer()
        let chart = """
            flowchart TD
              A["Incoming email"] --> B{"In rollout scope?<br/>Use recipient and arrival time"}
              B -->|No| R["Normal mail routing"]
              B -->|Yes| S["Screen a bounded, redacted subject<br/>Keep the result in member-only Mail"]
              S --> V{"Screened?"}
              V -->|Yes| R
              V -->|Pending, flagged, or unavailable| I["Stays in Mail · no agent routing"]
            """
        let rendered = await renderer.render(chart, dark: false)
        let image = try XCTUnwrap(rendered)
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertGreaterThan(image.size.height, 100)
        XCTAssertNotNil(image.cgImage)
        let invalid = await renderer.render("flowchart TD\nA-->[", dark: false)
        XCTAssertNil(invalid)
        let override = await renderer.render("---\nconfig:\n  securityLevel: loose\n---\n" + chart, dark: false)
        XCTAssertNil(override)
        let safe = await renderer.render("flowchart TD\nA[\"<img src=https://example.invalid/chart-fetch>\"] --> B[Mail]", dark: true)
        XCTAssertNotNil(safe?.cgImage, "Chart markup must not expose an interactive view")
    }


    func testTypingTracksOnlyTheCurrentRequestAndHidesWhenItReplies() {
        var state = AgentTypingState()
        state.apply(typingEvent(10, AgentChatMessage.contextAdded, ["role": "user"]))
        state.apply(typingEvent(11, AgentChatMessage.contextAdded, ["role": "developer"]))
        state.apply(typingEvent(12, AgentTypingState.requested, ["triggerOffset": 10]))
        XCTAssertFalse(state.isTyping, "An obsolete intent does not start a model request")
        state.apply(typingEvent(13, AgentTypingState.requested, ["triggerOffset": 11]))
        XCTAssertTrue(state.isTyping)
        state.apply(typingEvent(14, AgentTypingState.settled, ["requestOffset": 12, "result": ["status": "cancelled"]]))
        state.apply(typingEvent(15, AgentChatMessage.replied, ["llmRequestOffset": 12, "message": "Older reply"]))
        XCTAssertTrue(state.isTyping)
        state.apply(typingEvent(16, AgentChatMessage.replied, ["llmRequestOffset": 13, "message": "Current reply"]))
        XCTAssertFalse(state.isTyping)
        state.apply(typingEvent(13, AgentTypingState.requested, ["triggerOffset": 11]))
        XCTAssertFalse(state.isTyping, "Replayed delivery does not restart the dots")
    }

    func testTypingStopsOnFailureOrSilenceAndFollowsARealRetry() {
        var state = AgentTypingState()
        state.apply(typingEvent(20, AgentChatMessage.contextAdded, ["role": "user"]))
        state.apply(typingEvent(21, AgentChatMessage.contextAdded, ["role": "user", "llmRequestPolicy": ["behaviour": "dont-trigger-request"]]))
        state.apply(typingEvent(22, AgentTypingState.requested, ["triggerOffset": 20]))
        XCTAssertTrue(state.isTyping)
        state.apply(typingEvent(23, AgentTypingState.settled, ["requestOffset": 22, "result": ["status": "failed"]]))
        XCTAssertFalse(state.isTyping)
        state.apply(typingEvent(24, AgentTypingState.requested, ["triggerOffset": 22]))
        XCTAssertTrue(state.isTyping)
        state.apply(typingEvent(25, AgentTypingState.settled, ["requestOffset": 24, "result": ["status": "succeeded", "text": ""]]))
        XCTAssertFalse(state.isTyping, "A turn can settle without a visible reply")
    }

    func testTypingStopsOnCancellationAndPause() {
        var state = AgentTypingState()
        state.apply(typingEvent(30, AgentChatMessage.contextAdded, ["role": "user"]))
        state.apply(typingEvent(31, AgentTypingState.requested, ["triggerOffset": 30]))
        state.apply(typingEvent(32, AgentChatMessage.contextAdded, ["role": "user"]))
        state.apply(typingEvent(33, AgentTypingState.settled, ["requestOffset": 31, "result": ["status": "cancelled"]]))
        XCTAssertFalse(state.isTyping)
        state.apply(typingEvent(34, AgentTypingState.requested, ["triggerOffset": 32]))
        XCTAssertTrue(state.isTyping)
        state.apply(typingEvent(35, AgentTypingState.paused, ["reason": "loop-limit"]))
        XCTAssertFalse(state.isTyping)
    }

    private func typingEvent(_ offset: Int, _ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["offset": offset, "type": type, "payload": payload]
    }

    @MainActor
    func testConnectingActionOpensOneDraftAndLaterActionsOpenFreshDrafts() throws {
        let scene = IterateShortcutScene()
        scene.openConnectingDraft()
        let first = try XCTUnwrap(scene.requestedAgents.first)
        scene.consume([first])
        scene.openRequestedAgent()
        XCTAssertTrue(scene.requestedAgents.isEmpty)

        scene.openRequestedAgent()
        let second = try XCTUnwrap(scene.requestedAgents.first)
        XCTAssertFalse(first === second)
        scene.openRequestedAgent()
        XCTAssertEqual(scene.requestedAgents.count, 2)
        scene.consume([second])
        XCTAssertEqual(scene.requestedAgents.count, 1)
    }

    @MainActor
    func testASecondActionPreservesInputInTheConnectingDraft() throws {
        let scene = IterateShortcutScene()
        scene.openConnectingDraft()
        let first = try XCTUnwrap(scene.requestedAgents.first)
        first.draft = "Unsent thought"
        scene.openRequestedAgent()
        XCTAssertEqual(scene.requestedAgents.count, 2)
        XCTAssertEqual(first.draft, "Unsent thought")
        XCTAssertEqual(scene.requestedAgents.last?.draft, "")
    }

    @MainActor
    func testIncludedWordsFollowTheDraftOnTheirOwnLine() {
        let chat = AgentConversation()
        chat.include("  Standup — 09:00\n")
        XCTAssertEqual(chat.draft, "Standup — 09:00")
        XCTAssertTrue(chat.receivedInput)

        chat.draft = "Move this one \n"
        chat.include("Ada Lovelace")
        XCTAssertEqual(chat.draft, "Move this one\nAda Lovelace")
        chat.include(" \n")
        XCTAssertEqual(chat.draft, "Move this one\nAda Lovelace")
    }

    @MainActor
    func testFreshDraftStartsLocallyAndHasAStablePerMemberPath() async throws {
        let id = UUID()
        let chat = AgentConversation(newAgentID: id)
        chat.draft = "A first question"
        await chat.open(on: nil)
        await chat.sendDraft(using: MindConnection())
        XCTAssertFalse(chat.sending)
        XCTAssertEqual(chat.draft, "A first question")
        XCTAssertEqual(chat.floor, 0)
        XCTAssertTrue(chat.isNewDraft)
        let path = AgentConversation.newAgentPath(id: id, email: "Jo+Phone@example.test")
        XCTAssertEqual(path, "/agents/people/jo-phone/web/" + id.uuidString.lowercased())
        XCTAssertNotEqual(path, AgentConversation.newAgentPath(id: UUID(), email: "Jo+Phone@example.test"))
        XCTAssertEqual(AgentConversation.newAgentPath(id: id, email: nil), "/agents/web/" + id.uuidString.lowercased())
    }

    @MainActor
    func testReturningToAnAgentFindsItsConversationUntilThePairingChanges() {
        let conversations = AgentConversations()
        let first = conversations.conversation(for: "/agents/one")
        first.draft = "Unsent thought"
        XCTAssertTrue(conversations.conversation(for: "/agents/one") === first)
        XCTAssertFalse(conversations.conversation(for: "/agents/two") === first)
        XCTAssertEqual(conversations.conversation(for: "/agents/one").draft, "Unsent thought")
        // Only the most recently visited are kept.
        for index in 0..<AgentConversations.capacity { _ = conversations.conversation(for: "/agents/later-\(index)") }
        XCTAssertFalse(conversations.conversation(for: "/agents/one") === first)
        let kept = conversations.conversation(for: "/agents/kept")
        conversations.forget()
        XCTAssertFalse(conversations.conversation(for: "/agents/kept") === kept)
    }

    @MainActor
    func testFirstSendMatchesTheDeployedCapnWebPipeline() throws {
        let expression = AgentChatChannel.firstMessageExpression(after: 17, at: "/agents/example", text: "Hello", key: "request")
        // Wire representation emitted by Iterate's Cap'n Web client for
        // create(path).map(() => agents.get(path).message(text, {key})).
        let expected = """
        ["remap",17,[],[["import",1]],[["pipeline",-1,["mind","agents","get"],["/agents/example"]],
        ["pipeline",1,["message"],["Hello",{"key":"request"}]],["pipeline",2]]]
        """
        let reference = try JSONSerialization.jsonObject(with: Data(expected.utf8))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: expression, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: reference, options: .sortedKeys))
    }

    @MainActor
    func testDraftPhotosKeepTheirOrderAndCanBeRemoved() throws {
        let conversation = AgentConversation()
        let photos = try (1...12).map {
            try CapturedFile(name: "Photo \($0).jpg", contentType: "image/jpeg", data: Data([UInt8($0)]))
        }
        XCTAssertFalse(conversation.hasDraftContent)
        conversation.addDraftPhotos(photos)
        XCTAssertTrue(conversation.receivedInput)
        XCTAssertTrue(conversation.hasDraftContent)
        XCTAssertEqual(conversation.draftPhotoSlots, 0)
        XCTAssertEqual(conversation.visibleDraftPhotos.map(\.file.name), photos.prefix(10).map(\.name))
        conversation.removeDraftPhoto(try XCTUnwrap(conversation.draftPhotos.first).id)
        XCTAssertEqual(conversation.draftPhotoSlots, 1)
        XCTAssertEqual(conversation.visibleDraftPhotos.first?.file.name, "Photo 2.jpg")
        for photo in conversation.draftPhotos { conversation.removeDraftPhoto(photo.id) }
        XCTAssertFalse(conversation.hasDraftContent)
    }

    func testReceiptAndRelayedCopyRemainOneInputAcrossHistoryAndLiveDelivery() throws {
        let original = try XCTUnwrap(AgentChatMessage(event: [
            "type": AgentChatMessage.received, "offset": 8, "idempotencyKey": "agent-message:example",
            "payload": ["message": "Hello", "from": "/"],
            "source": ["onBehalfOf": ["principal": ["email": "person@example.test"]]]
        ]))
        let copy = try XCTUnwrap(AgentChatMessage(event: [
            "type": AgentChatMessage.contextAdded, "offset": 10,
            "payload": ["role": "user", "content": "Hello", "messageOffset": 8]
        ]))
        let otherCopy = try XCTUnwrap(AgentChatMessage(event: [
            "type": AgentChatMessage.contextAdded, "offset": 11, "idempotencyKey": "agent/message-received@8",
            "payload": ["role": "user", "content": "Hello"]
        ]))
        let reply = try XCTUnwrap(AgentChatMessage(event: [
            "type": AgentChatMessage.replied, "offset": 13, "payload": ["message": "Hi!"]
        ]))
        XCTAssertEqual(AgentChatMessage.merge([reply, copy, original, otherCopy], into: []), [original, reply])
        XCTAssertEqual(AgentChatMessage.merge([copy, reply, original], into: [original, reply]), [original, reply])
        XCTAssertEqual(original.sender, "person@example.test")
        XCTAssertEqual(original.sendKey, "agent-message:example")
    }

    @MainActor
    func testCallAndTextClaimTheSameLocalDraftAndKeepUnsentWords() throws {
        let id = UUID()
        let chat = AgentConversation(newAgentID: id)
        chat.draft = "Still here"
        let expected = AgentConversation.newAgentPath(id: id, email: "Test@example.test")
        XCTAssertEqual(try chat.voiceDestination(member: "test", email: "Test@example.test"), .agent(path: expected, draftID: id))
        XCTAssertThrowsError(try chat.voiceDestination(member: "other", email: nil))
        chat.voiceConnected()
        XCTAssertFalse(chat.isNewDraft)
        XCTAssertEqual(chat.draft, "Still here")
        XCTAssertEqual(try AgentConversation(path: expected).voiceDestination(member: "test", email: nil),
                       .agent(path: expected, draftID: nil))
    }

    @MainActor
    func testLeavingBeforeDictationStartsCancelsThePermissionRequest() async {
        let dictation = AgentDictation()
        dictation.start(after: "Unsent thought") { _ in XCTFail("A cancelled dictation changed the draft") }
        XCTAssertEqual(dictation.phase, .requesting)
        dictation.cancel()
        await Task.yield()
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertNil(dictation.issue)
    }

    @MainActor
    func testDictationReplacesPartialWordsAfterTheOriginalDraft() {
        XCTAssertEqual(AgentDictation.inserting("Book", after: "Please"), "Please Book")
        XCTAssertEqual(AgentDictation.inserting("Book a train", after: "Please"), "Please Book a train")
        XCTAssertEqual(AgentDictation.inserting("New line", after: "First line\n"), "First line\nNew line")
        XCTAssertEqual(AgentDictation.inserting("Hello", after: ""), "Hello")
        XCTAssertEqual(AgentDictation.inserting("", after: "Draft"), "Draft")
    }

    func testSpokenTurnsDisplayOnceAsTheOriginalSpeaker() throws {
        for (speaker, role) in [("member", AgentChatMessage.Role.input), ("voice-agent", .agent)] {
            let spoken = try XCTUnwrap(AgentChatMessage(event: [
                "offset": 42, "type": AgentChatMessage.contextAdded,
                "payload": ["role": "user", "content": "[call] Caller said: Hello", "actor": ["type": "user"],
                            "callNote": ["kind": "said", "who": ["actor": speaker], "text": "Hello"]]
            ]))
            XCTAssertEqual(spoken.role, role)
            XCTAssertEqual(spoken.text, "Hello")
            XCTAssertEqual(AgentChatMessage.merge([spoken], into: [spoken]), [spoken])
        }
    }

    func testOnlyPeopleAndPublishedAgentWordsEnterTheConversation() throws {
        for payload in [["role": "assistant", "content": "Provider output"], ["role": "system", "content": "System"],
                        ["role": "developer", "content": "Tool result"]] {
            XCTAssertNil(AgentChatMessage(event: ["type": AgentChatMessage.contextAdded, "offset": 17, "payload": payload]))
        }
        XCTAssertNil(AgentChatMessage(event: [
            "type": AgentChatMessage.contextAdded, "offset": 18,
            "payload": ["role": "user", "actor": ["type": "agent"], "content": "Internal clock tick"]
        ]))
        XCTAssertNil(AgentChatMessage(event: ["type": "events.iterate.com/agent/llm-response-frame",
                                              "offset": 19, "payload": ["thinkingDelta": "private", "responseDelta": "partial"]]))
        let direct = try XCTUnwrap(AgentChatMessage(event: ["type": AgentChatMessage.contextAdded, "offset": 20,
                                                            "payload": ["role": "user", "content": "A question"]]))
        XCTAssertEqual(direct.id, 20)
        let file = try XCTUnwrap(AgentChatMessage(event: [
            "type": AgentChatMessage.received, "offset": 21,
            "payload": ["message": "", "files": [[["filename": "notes.txt"]]], "from": "/agents/reader"]
        ]))
        XCTAssertEqual(file.files, ["notes.txt"])
        XCTAssertEqual(file.sender, "/agents/reader")
        XCTAssertEqual(file.role, .input)
    }
}
