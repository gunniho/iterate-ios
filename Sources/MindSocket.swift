import Foundation

struct MindRPCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The authenticated root, outstanding calls and subscription callbacks share one ordered socket.
@MainActor
final class MindSocket {
    static let root = 1
    private let socket: URLSessionWebSocketTask
    private let outgoing = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(256))
    private var nextImport = 1
    private var nextCallback = -1
    private var nextPeerCall = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var callbacks: [Int: ([[String: Any]]) -> Void] = [:]
    private var peerResults: [Int: Bool] = [:]
    private var closed = false

    init(_ socket: URLSessionWebSocketTask) { self.socket = socket }

    func close() {
        guard !closed else { return }
        closed = true
        outgoing.continuation.finish()
        socket.cancel(with: .goingAway, reason: nil)
        for waiter in pending.values { waiter.resume(throwing: ConnectionIssue.lostConnection) }
        pending.removeAll()
        callbacks.removeAll()
        peerResults.removeAll()
    }

    func run(verified: @escaping @MainActor (String?) -> Void) async throws {
        let transport = socket
        socket.resume()
        defer { close() }
        _ = try reference(target: 0, path: ["authenticate"])
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.write() }
                group.addTask { try await self.receive() }
                group.addTask { try await self.heartbeat(verified: verified) }
                defer {
                    close()
                    group.cancelAll()
                }
                try await group.next()
            }
        } onCancel: {
            transport.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Keep a pipelined remote object until its owner releases it.
    func reference(target: Int, path: [String], arguments: [Any] = []) throws -> Int {
        let id = nextImport
        try enqueue(["push", ["pipeline", target, path, arguments]])
        nextImport += 1
        return id
    }

    func release(_ id: Int) {
        if !closed { try? enqueue(["release", id, 1]) }
    }

    func exportCallback(_ callback: @escaping ([[String: Any]]) -> Void) -> Int {
        let id = nextCallback
        nextCallback -= 1
        callbacks[id] = callback
        return id
    }

    func removeCallback(_ id: Int) { callbacks.removeValue(forKey: id) }

    func call(target: Int = root, path: [String], arguments: [Any] = [],
              timeout: Duration = .seconds(15)) async throws -> Any {
        try await evaluate(["pipeline", target, path, arguments], timeout: timeout)
    }

    func evaluate(_ expression: [Any], timeout: Duration) async throws -> Any {
        let (id, data) = try await request(expression, timeout: timeout)
        guard let frame = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ConnectionIssue.invalidResponse
        }
        return try Self.value(in: frame, for: id)
    }

    private func request(_ expression: [Any], timeout: Duration) async throws -> (Int, Data) {
        try Task.checkCancellation()
        let id = nextImport
        try enqueue(["stream", expression])
        nextImport += 1
        let deadline = Task {
            try await Task.sleep(for: timeout)
            pending.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
        }
        defer { deadline.cancel() }
        let response: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
        return (id, response)
    }

    private func heartbeat(verified: @escaping @MainActor (String?) -> Void) async throws {
        while !closed {
            let (id, data) = try await request(["pipeline", Self.root, ["mind", "whoami"], []], timeout: .seconds(15))
            guard let frame = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw ConnectionIssue.invalidResponse
            }
            verified(try Self.identity(in: frame, for: id))
            try await Task.sleep(for: .seconds(30))
        }
    }

    private func enqueue(_ frame: [Any]) throws {
        guard !closed else { throw ConnectionIssue.lostConnection }
        let data = try JSONSerialization.data(withJSONObject: frame)
        switch outgoing.continuation.yield(String(decoding: data, as: UTF8.self)) {
        case .enqueued: break
        default:
            close()
            throw ConnectionIssue.lostConnection
        }
    }

    private func write() async throws {
        for await message in outgoing.stream {
            try Task.checkCancellation()
            try await socket.send(.string(message))
        }
    }

    private func receive() async throws {
        while !closed {
            let message = try await socket.receive()
            try Task.checkCancellation()
            guard case .string(let json) = message else { throw ConnectionIssue.invalidResponse }
            let data = Data(json.utf8)
            guard let frame = try JSONSerialization.jsonObject(with: data) as? [Any],
                  frame.count >= 2, let kind = frame[0] as? String else { throw ConnectionIssue.invalidResponse }
            switch kind {
            case "resolve", "reject":
                guard frame.count == 3, let id = frame[1] as? Int else { throw ConnectionIssue.invalidResponse }
                if let waiter = pending.removeValue(forKey: id) {
                    waiter.resume(returning: data)
                } else if kind == "resolve", let exported = Self.exportedReference(in: frame[2]) {
                    release(exported)
                }
            case "push", "stream":
                let id = nextPeerCall
                nextPeerCall += 1
                let handled = dispatch(frame[1])
                if kind == "stream" { try reply(to: id, handled: handled) }
                else { peerResults[id] = handled }
            case "pull":
                guard let id = frame[1] as? Int else { throw ConnectionIssue.invalidResponse }
                try reply(to: id, handled: peerResults[id] ?? false)
            case "release":
                if let id = frame[1] as? Int, id > 0 { peerResults.removeValue(forKey: id) }
            case "abort": throw ConnectionIssue.lostConnection
            default: throw ConnectionIssue.invalidResponse
            }
        }
    }

    static func exportedReference(in value: Any) -> Int? {
        guard let tag = value as? [Any], tag.count == 2, tag[0] as? String == "export",
              let id = tag[1] as? Int, id < 0 else { return nil }
        return id
    }

    private func dispatch(_ expression: Any) -> Bool {
        guard let pipeline = expression as? [Any], pipeline.count == 4,
              pipeline[0] as? String == "pipeline", let id = pipeline[1] as? Int,
              let callback = callbacks[id], let path = pipeline[2] as? [String], path.isEmpty,
              let args = pipeline[3] as? [Any], let wrapper = args.first as? [Any], wrapper.count == 1,
              let events = wrapper[0] as? [[String: Any]] else { return false }
        callback(events)
        return true
    }

    private func reply(to id: Int, handled: Bool) throws {
        if handled { try enqueue(["resolve", id, ["undefined"]]) }
        else { try enqueue(["reject", id, ["error", "TypeError", "Unknown client method"]]) }
    }

    private static func value(in frame: [Any], for requestID: Int) throws -> Any {
        guard frame.count == 3, frame[1] as? Int == requestID else { throw ConnectionIssue.invalidResponse }
        if frame[0] as? String == "reject" {
            let error = frame[2] as? [Any]
            if (error?.dropFirst(4).first as? [String: Any])?["code"] as? String == "UNAUTHENTICATED" {
                throw ConnectionIssue.refused
            }
            throw MindRPCError(message: (error?.dropFirst(2).first as? String) ?? "Iterate declined the request.")
        }
        guard frame[0] as? String == "resolve" else { throw ConnectionIssue.invalidResponse }
        return frame[2]
    }

    static func identity(in frame: [Any], for requestID: Int, deployment: Deployment = .current) throws -> String? {
        guard let result = try value(in: frame, for: requestID) as? [String: Any] else {
            throw ConnectionIssue.invalidResponse
        }
        guard deployment.isConfigured, result["mindId"] as? String == deployment.mindID,
              result["mindSlug"] as? String == deployment.controlHost,
              result["path"] as? String == "/" else { throw ConnectionIssue.wrongMind }
        return (result["principal"] as? [String: Any])?["email"] as? String
    }
}
