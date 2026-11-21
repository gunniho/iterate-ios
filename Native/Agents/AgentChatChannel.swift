import Foundation

/// One selected agent's log and live subscription on the iPhone's paired socket.
@MainActor
final class AgentChatChannel {
    static let window = 160

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

    func messages(after start: Int, through end: Int) async throws -> [AgentChatMessage] {
        var after = start
        var messages: [AgentChatMessage] = []
        while after < end {
            let part = try await page(after: after, limit: min(48, end - after))
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
