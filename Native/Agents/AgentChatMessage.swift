import Foundation

struct AgentChatMessage: Identifiable, Equatable {
    enum Role { case input, agent }

    let id: Int
    let role: Role
    let text: String
    let files: [String]
    let sender: String?
    let sendKey: String?
    let isRelayedCopy: Bool

    static let received = "events.iterate.com/agent/message-received"
    static let contextAdded = "events.iterate.com/agent/context-added"
    static let replied = "events.iterate.com/agent/web-message-sent"

    init?(event: [String: Any]) {
        guard let offset = event["offset"] as? Int, offset > 0,
              let type = event["type"] as? String, let payload = event["payload"] as? [String: Any] else { return nil }
        let key = event["idempotencyKey"] as? String
        var originalOffset: Int?
        switch type {
        case Self.received:
            guard let words = payload["message"] as? String else { return nil }
            role = .input
            text = words
        case Self.contextAdded:
            let actor = (payload["actor"] as? [String: Any])?["type"] as? String
            guard payload["role"] as? String == "user", actor == nil || actor == "user",
                  let words = payload["content"] as? String else { return nil }
            if let note = payload["callNote"] as? [String: Any], note["kind"] as? String == "said",
               let spoken = note["text"] as? String, let who = note["who"] as? [String: Any] {
                role = who["actor"] as? String == "voice-agent" ? .agent : .input
                text = spoken
            } else {
                role = .input
                text = words
            }
            // Older and agent-to-agent relays identify the original only in the processor's key.
            let prefix = "agent/message-received@"
            let linked = (payload["messageOffset"] as? Int)
                ?? key.flatMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }
            if let linked, linked > 0, linked < offset { originalOffset = linked }
        case Self.replied:
            guard let words = payload["message"] as? String else { return nil }
            role = .agent
            text = words
        default:
            return nil
        }
        let wireFiles = (payload["files"] as? [Any])?.first as? [[String: Any]] ?? []
        files = wireFiles.compactMap { $0["filename"] as? String }
        guard !text.isEmpty || !files.isEmpty else { return nil }
        id = originalOffset ?? offset
        isRelayedCopy = originalOffset != nil
        sendKey = type == Self.received ? key : nil
        let source = event["source"] as? [String: Any]
        let behalf = source?["onBehalfOf"] as? [String: Any]
        let principal = (source?["principal"] as? [String: Any]) ?? (behalf?["principal"] as? [String: Any])
        if let from = payload["from"] as? String, from != "/" {
            sender = from
        } else if source?["schedule"] == nil, source?["copiedFrom"] == nil, source?["platform"] == nil {
            sender = principal?["email"] as? String
        } else {
            sender = nil
        }
    }

    static func merge(_ added: [Self], into messages: [Self]) -> [Self] {
        var byOffset = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in added {
            if message.isRelayedCopy, byOffset[message.id] != nil { continue }
            byOffset[message.id] = message
        }
        return byOffset.values.sorted { $0.id < $1.id }
    }
}
