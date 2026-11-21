import Foundation

enum VoiceDestination: Equatable {
    case device
    case agent(path: String, draftID: UUID?)
}

enum VoiceEvent: Equatable {
    case accepted
    case speaker(Data, clear: Bool)
    case caption(String, fromGPT: Bool)
    case ended(String)
    case providerError(String)

    static let prefix = "events.iterate.com/voice-agent/"
    static let names = ["conversation-accepted", "speaker-frame", "utterance-transcribed",
                        "answer-transcribed", "call-ended", "provider-error-reported", "provider-disconnected"]

    static func decode(_ event: [String: Any], activation: String) -> Self? {
        guard let type = event["type"] as? String, type.hasPrefix(prefix),
              let fields = event["payload"] as? [String: Any],
              fields["activation"] as? String == activation else { return nil }
        switch type.dropFirst(prefix.count) {
        case "conversation-accepted": return .accepted
        case "speaker-frame":
            guard let encoded = fields["pcm"] as? String, let pcm = Data(base64Encoded: encoded),
                  pcm.count.isMultiple(of: 2) else { return nil }
            return .speaker(pcm, clear: fields["clearSpeakerBufferBeforeFrame"] as? Bool == true)
        case "utterance-transcribed", "answer-transcribed":
            guard let text = fields["text"] as? String, !text.isEmpty else { return nil }
            return .caption(text, fromGPT: type == prefix + "answer-transcribed")
        case "call-ended": return .ended(fields["reason"] as? String ?? "The call ended.")
        case "provider-error-reported": return .providerError(fields["message"] as? String ?? "GPT reported an error.")
        case "provider-disconnected": return .ended("The connection to GPT ended.")
        default: return nil
        }
    }
}

@MainActor
final class VoiceRelay {
    static let clientName: String = {
        let key = "voice.installationName." + Deployment.current.workspaceKey
        if let name = UserDefaults.standard.string(forKey: key) { return name }
        let name = "ios-" + randomID().prefix(12)
        UserDefaults.standard.set(name, forKey: key)
        return name
    }()

    let socket: MindSocket
    let path: String
    private let context: Int
    private let callback: Int
    private let subscription: Int
    private var closed = false

    static func randomID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private init(socket: MindSocket, path: String, context: Int, callback: Int, subscription: Int) {
        self.socket = socket
        self.path = path
        self.context = context
        self.callback = callback
        self.subscription = subscription
    }

    static func open(on socket: MindSocket, client: String = clientName, destination: VoiceDestination = .device,
                     receive: @escaping ([[String: Any]]) -> Void) async throws -> VoiceRelay {
        let path: String
        switch destination {
        case .device:
            let reply = try await socket.call(path: ["mind", "voice", "ensureVoiceDevice"],
                                              arguments: [["client": client]], timeout: .seconds(30))
            guard let device = reply as? [String: Any], device["path"] as? String == "/voice/" + client,
                  device["agentPath"] as? String == "/agents/voice/" + client else { throw ConnectionIssue.invalidResponse }
            path = "/voice/" + client
        case .agent(let agent, let draftID):
            var input = ["agentPath": agent, "client": client]
            if let draftID { input["draftId"] = draftID.uuidString.lowercased() }
            let reply = try await socket.call(path: ["mind", "iterateMobile", "openAgentVoice"],
                                              arguments: [input], timeout: .seconds(60))
            guard let device = reply as? [String: Any], device["agentPath"] as? String == agent,
                  let relayPath = device["path"] as? String,
                  relayPath.range(of: #"^/voice/ios-chat-[a-f0-9]{40}$"#, options: .regularExpression) != nil
            else { throw ConnectionIssue.invalidResponse }
            path = relayPath
        }
        try Task.checkCancellation()
        let context = try socket.reference(target: MindSocket.root, path: ["mind", "cd"], arguments: [path])
        let callback = socket.exportCallback(receive)
        do {
            // Cap'n Web wraps a literal array once to distinguish it from a wire expression.
            let options: [String: Any] = [
                "name": client + "-" + randomID().prefix(8),
                "consumes": [VoiceEvent.names.map { VoiceEvent.prefix + $0 }],
                "target": ["export", callback],
            ]
            let value = try await socket.call(target: context, path: ["subscribe"], arguments: [options])
            guard let subscription = MindSocket.exportedReference(in: value) else {
                throw ConnectionIssue.invalidResponse
            }
            return VoiceRelay(socket: socket, path: path, context: context, callback: callback, subscription: subscription)
        } catch {
            socket.removeCallback(callback)
            socket.release(context)
            throw error
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        socket.removeCallback(callback)
        socket.release(subscription)
        socket.release(context)
    }

    func start(_ activation: String) async throws {
        var start = event("call-started", activation: activation)
        start["idempotencyKey"] = "voice-agent/call:" + activation
        _ = try await socket.call(target: context, path: ["append"], arguments: [start])
    }

    func sendMic(_ frames: [Data], activation: String) async throws {
        let events = frames.map {
            event("mic-frame", activation: activation, fields: ["pcm": $0.base64EncodedString()], ephemeral: true)
        }
        _ = try await socket.call(target: context, path: ["appendOffsets"], arguments: events, timeout: .seconds(5))
    }

    func keepAlive(_ activation: String) async throws {
        _ = try await socket.call(target: context, path: ["append"],
                                  arguments: [event("keepalive", activation: activation, ephemeral: true)])
    }

    func speakScreenAnswer(_ text: String, activation: String, runID: UUID) async throws {
        var message = event("words-given", activation: activation, fields: ["text": text])
        message["idempotencyKey"] = "voice-agent/screen-answer:" + activation + ":" + runID.uuidString.lowercased()
        _ = try await socket.call(target: context, path: ["append"], arguments: [message])
    }

    func end(_ activation: String, reason: String) async throws {
        try await Self.end(activation, reason: reason, context: context, on: socket)
    }

    static func end(_ activation: String, reason: String, context: Int, on socket: MindSocket) async throws {
        let event: [String: Any] = ["type": VoiceEvent.prefix + "call-ended",
                                    "payload": ["activation": activation, "reason": reason],
                                    "idempotencyKey": "voice-agent/hang-up:" + activation]
        _ = try await socket.call(target: context, path: ["append"], arguments: [event], timeout: .seconds(3))
    }

    private func event(_ name: String, activation: String, fields: [String: Any] = [:],
                       ephemeral: Bool = false) -> [String: Any] {
        var payload = fields
        payload["activation"] = activation
        var envelope: [String: Any] = ["type": VoiceEvent.prefix + name, "payload": payload]
        if ephemeral { envelope["ephemeral"] = true }
        return envelope
    }
}
