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

/// Fold just enough of the ordered agent log to recognize a real model request. An intent for
/// an older trigger is still durable, but the agent ignores it, so it must not leave dots stuck.
struct AgentTypingState {
    static let requested = "events.iterate.com/agent/llm-request-requested"
    static let settled = "events.iterate.com/agent/llm-request-settled"
    static let paused = "events.iterate.com/agent/paused"
    static let inputGated = "events.iterate.com/agent/input-gated"
    static let eventTypes = [requested, settled, paused, inputGated]

    private var lastOffset = 0
    private var trigger: Int?
    private var request: Int?
    private var replied = false
    var isTyping: Bool { request != nil && !replied }

    mutating func apply(_ event: [String: Any]) {
        guard let offset = event["offset"] as? Int, offset > lastOffset,
              let type = event["type"] as? String, let payload = event["payload"] as? [String: Any] else { return }
        lastOffset = offset
        switch type {
        case AgentChatMessage.contextAdded:
            let role = payload["role"] as? String
            let policy = payload["llmRequestPolicy"] as? [String: Any]
            if (role == "user" || role == "developer"), policy?["behaviour"] as? String != "dont-trigger-request" {
                trigger = offset
            }
        case Self.requested:
            guard request == nil, let trigger, payload["triggerOffset"] as? Int == trigger else { return }
            self.trigger = nil
            request = offset
            replied = false
        case Self.settled:
            guard let request, payload["requestOffset"] as? Int == request else { return }
            self.request = nil
            // Failed attempts may be retried by the loop, using the failed request as their trigger.
            if let result = payload["result"] as? [String: Any], result["status"] as? String == "failed",
               result["loopLimit"] as? Bool != true {
                trigger = request
            }
        case AgentChatMessage.replied:
            if let request, payload["llmRequestOffset"] as? Int == request { replied = true }
        case Self.inputGated:
            if let trigger, payload["inputOffset"] as? Int == trigger, payload["wake"] as? Bool == false {
                self.trigger = nil
            }
        case Self.paused:
            trigger = nil
            request = nil
        default:
            break
        }
    }
}
