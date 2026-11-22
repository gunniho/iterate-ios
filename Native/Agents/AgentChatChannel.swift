import Foundation

/// One selected agent's log and live subscription on the iPhone's paired socket.
@MainActor
final class AgentChatChannel {
    static let window = 160
    /// A mind that predates the transcript route answers 404 once. The log is then read directly.
    static var transcriptRouteMissing = false

    private let socket: MindSocket
    private let path: String
    private let context: Int
    private var callback: Int?
    private var subscription: Int?
    private var closed = false

    init(socket: MindSocket, path: String) throws {
        self.socket = socket
        self.path = path
        context = try socket.reference(target: MindSocket.root, path: ["mind", "cd"], arguments: [path])
    }

    func head() async throws -> Int {
        // Iterate's head probe returns the durable mark even across unstored event offsets.
        try await page(after: 9_007_199_254_740_991, limit: 1).scannedThrough
    }

    /// The newest messages, the offset they reach back to and the head a subscription resumes from.
    func latest() async throws -> (head: Int, floor: Int, messages: [AgentChatMessage]) {
        if let page = try await transcript(through: nil) { return page }
        let head = try await head()
        let start = max(0, head - Self.window)
        return (head, start, try await messages(after: start, through: head))
    }

    /// The messages before the ones held, and the offset they reach back to.
    func earlier(than floor: Int) async throws -> (floor: Int, messages: [AgentChatMessage]) {
        if let page = try await transcript(through: floor) { return (page.floor, page.messages) }
        let start = max(0, floor - Self.window)
        return (start, try await messages(after: start, through: floor))
    }

    /// The member facet reads the log beside it and returns only what a conversation shows.
    private func transcript(through: Int?) async throws -> (head: Int, floor: Int, messages: [AgentChatMessage])? {
        guard !Self.transcriptRouteMissing else { return nil }
        guard !closed else { throw CancellationError() }
        var body: [String: Any] = ["path": path]
        if let through { body["through"] = through }
        let wire = try await socket.call(path: ["mind", "iterateMobile", "request"],
                                         arguments: [["method": "POST", "path": "/agents/transcript", "body": body]],
                                         timeout: .seconds(18))
        guard let envelope = wire as? [String: Any], let status = envelope["status"] as? Int else {
            throw ConnectionIssue.invalidResponse
        }
        if status == 404 {
            Self.transcriptRouteMissing = true
            return nil
        }
        guard status == 200 else {
            let reason = (envelope["body"] as? [String: Any])?["error"] as? String
            if status == 401 || status == 403 { throw AssistantIssue.accessDenied(reason ?? "Iterate declined this request.") }
            throw AssistantIssue.remote(reason ?? "Iterate returned HTTP \(status).")
        }
        // The events keep their wire form, so they read exactly like a page of the log.
        guard let page = envelope["body"] as? [String: Any], let wrapper = page["events"] as? [Any], wrapper.count == 1,
              let events = wrapper[0] as? [[String: Any]], let head = page["head"] as? Int, head >= 0,
              let floor = page["floor"] as? Int, floor >= 0, floor <= through ?? head else {
            throw ConnectionIssue.invalidResponse
        }
        return (head, floor, events.compactMap(AgentChatMessage.init(event:)))
    }

    func messages(after start: Int, through end: Int) async throws -> [AgentChatMessage] {
        var after = start
        var messages: [AgentChatMessage] = []
        while after < end {
            // The mind also cuts a page by size, so one request usually returns the whole window.
            let part = try await page(after: after, limit: min(Self.window, end - after))
            for event in part.events {
                if let offset = event["offset"] as? Int, offset > start, offset <= end,
                   let message = AgentChatMessage(event: event) { messages.append(message) }
            }
            if part.atHead || part.scannedThrough >= end { break }
            guard part.scannedThrough > after else { throw ConnectionIssue.invalidResponse }
            after = part.scannedThrough
        }
        return messages
    }

    private func page(after: Int, limit: Int) async throws -> (events: [[String: Any]], scannedThrough: Int, atHead: Bool) {
        guard !closed else { throw CancellationError() }
        let wire = try await socket.call(target: context, path: ["readEvents"], arguments: [after, limit])
        guard let page = wire as? [String: Any], let wrapper = page["events"] as? [Any], wrapper.count == 1,
              let events = wrapper[0] as? [[String: Any]], let through = page["scannedThroughOffset"] as? Int, through >= 0,
              let atHead = page["atHead"] as? Bool else { throw ConnectionIssue.invalidResponse }
        return (events, through, atHead)
    }

    func follow(after offset: Int, receive: @escaping ([[String: Any]]) -> Void) async throws {
        guard !closed else { throw CancellationError() }
        let id = socket.exportCallback(receive)
        callback = id
        let options: [String: Any] = [
            "name": "iterate-ios-chat-" + UUID().uuidString.lowercased(),
            "afterOffset": offset,
            "consumes": [[AgentChatMessage.received, AgentChatMessage.contextAdded, AgentChatMessage.replied]],
            "target": ["export", id]
        ]
        let wire = try await socket.call(target: context, path: ["subscribe"], arguments: [options])
        guard let handle = MindSocket.exportedReference(in: wire) else { throw ConnectionIssue.invalidResponse }
        guard !closed, !Task.isCancelled else {
            socket.release(handle)
            throw CancellationError()
        }
        subscription = handle
    }

    func send(_ text: String, key: String) async throws -> AgentChatMessage {
        guard !closed else { throw ConnectionIssue.lostConnection }
        let agent = try socket.reference(target: MindSocket.root, path: ["mind", "agents", "get"], arguments: [path])
        defer { socket.release(agent) }
        let wire = try await socket.call(target: agent, path: ["message"], arguments: [text, ["key": key]])
        return try Self.receipt(wire, text: text, key: key)
    }

    static func startAgent(at path: String, text: String, key: String, on socket: MindSocket) async throws -> AgentChatMessage {
        let creation = try socket.reference(target: MindSocket.root, path: ["mind", "agents", "create"], arguments: [path])
        defer { socket.release(creation) }

        let afterCreation = firstMessageExpression(after: creation, at: path, text: text, key: key)
        let wire = try await socket.evaluate(afterCreation, timeout: .seconds(75))
        return try receipt(wire, text: text, key: key)
    }

    static func firstMessageExpression(after creation: Int, at path: String, text: String, key: String) -> [Any] {
        // Cap'n Web runs these steps when create succeeds. The captured root is -1 and the
        // steps' results are 1 and 2. Always deliver to the path chosen for this draft.
        let getAgent: [Any] = ["pipeline", -1, ["mind", "agents", "get"], [path]]
        let message: [Any] = ["pipeline", 1, ["message"], [text, ["key": key]]]
        return ["remap", creation, [], [["import", MindSocket.root]], [getAgent, message, ["pipeline", 2]]]
    }

    private static func receipt(_ wire: Any, text: String, key: String) throws -> AgentChatMessage {
        guard let event = wire as? [String: Any], let message = AgentChatMessage(event: event),
              message.sendKey == "agent-message:" + key, message.text == text else { throw ConnectionIssue.invalidResponse }
        return message
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let callback { socket.removeCallback(callback) }
        if let subscription { socket.release(subscription) }
        socket.release(context)
    }
}
