import Darwin
import Foundation

@MainActor
enum PairedSession {
    static func credentials(replacing rejected: String? = nil) async throws -> Credentials {
        let store = CredentialStore()
        guard let original = try store.load() else { throw AssistantIssue.unpaired }
        if original.expiresAt.timeIntervalSinceNow > 25, original.accessToken != rejected { return original }

        // Refresh tokens can rotate. Coordinate the host and extensions using the same device grant.
        let path = try IterateAppGroup.container().appendingPathComponent("token-renewal.lock").path
        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AssistantIssue.storage }
        defer { close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ContinuousClock.now < deadline else { throw AssistantIssue.unavailable }
            try await Task.sleep(for: .milliseconds(90))
        }
        defer { flock(fd, LOCK_UN) }
        guard let current = try store.load(), current.clientID == original.clientID else {
            throw AssistantIssue.changedSession
        }
        if current.expiresAt.timeIntervalSinceNow > 25, current.accessToken != rejected { return current }
        let renewed = try await IterateClient().refresh(current)
        guard try store.load()?.accessToken == current.accessToken else { throw AssistantIssue.changedSession }
        try store.save(renewed)
        return renewed
    }
}

@MainActor
struct NativeMindTransport {
    func request(_ method: String, path: String, body: [String: Any]?, using credentials: Credentials,
                 over verifiedLink: MindSocket? = nil) async throws -> Data {
        if let verifiedLink { return try await invoke(method, path: path, body: body, over: verifiedLink) }
        let task = try IterateClient().socket(for: credentials)
        task.maximumMessageSize = 8 * 1024 * 1024
        let link = MindSocket(task)
        let ready = AsyncThrowingStream<Void, Error>.makeStream()
        let connection = Task {
            do {
                try await link.run { _ in
                    ready.continuation.yield(())
                    ready.continuation.finish()
                }
                ready.continuation.finish(throwing: ConnectionIssue.lostConnection)
            } catch { ready.continuation.finish(throwing: error) }
        }
        defer { link.close(); connection.cancel() }
        var readiness = ready.stream.makeAsyncIterator()
        guard try await readiness.next() != nil else { throw ConnectionIssue.lostConnection }
        try Task.checkCancellation()
        return try await invoke(method, path: path, body: body, over: link)
    }

    private func invoke(_ method: String, path: String, body: [String: Any]?, over link: MindSocket) async throws -> Data {
        var request: [String: Any] = ["method": method, "path": path]
        if let body { request["body"] = Self.encodeLiteral(body) }
        let value = try await link.call(path: ["mind", "iterateMobile", "request"],
                                        arguments: [request], timeout: .seconds(18))
        guard let envelope = try Self.decodeLiteral(value) as? [String: Any],
              let status = envelope["status"] as? Int, let result = envelope["body"] else {
            throw ConnectionIssue.invalidResponse
        }
        guard (200..<300).contains(status) else {
            let reason = (result as? [String: Any])?["error"] as? String
            if status == 409 { throw AssistantIssue.conflict(reason ?? "Iterate has a newer reply. Check for the latest answer.") }
            throw AssistantIssue.remote(reason ?? "Iterate returned HTTP \(status).")
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    // A single-element envelope distinguishes literal JSON arrays from Cap'n Web operations.
    static func encodeLiteral(_ value: Any) -> Any {
        if let list = value as? [Any] { return [list.map(encodeLiteral)] }
        if let fields = value as? [String: Any] { return fields.mapValues(encodeLiteral) }
        return value
    }

    static func decodeLiteral(_ value: Any) throws -> Any {
        if let fields = value as? [String: Any] { return try fields.mapValues(decodeLiteral) }
        if let list = value as? [Any] {
            if list.count == 1, let contents = list.first as? [Any] { return try contents.map(decodeLiteral) }
            if list.count == 1, list.first as? String == "undefined" { return NSNull() }
            throw ConnectionIssue.invalidResponse
        }
        return value
    }
}

@MainActor
final class AssistantCenter {
    static let shared = AssistantCenter()

    private let transport = NativeMindTransport()
    var foregroundSession: (id: String, link: MindSocket)?

    func submit(text: String, attachment: IterateAttachment? = nil, remember: Bool = false,
                requestID: UUID = UUID(), requiredSession: String? = nil) async throws -> IterateRun {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || attachment != nil), text.utf16.count <= 16_000 else {
            throw AssistantIssue.invalidInput("Enter a question or select an item. Text can contain up to 16,000 characters.")
        }
        var body: [String: Any] = ["id": requestID.uuidString.lowercased(), "kind": remember ? "remember" : "ask",
                                   "prompt": text.isEmpty ? "Remember this attachment." : text]
        if let attachment {
            guard !attachment.data.isEmpty, attachment.data.count <= IterateAttachment.maximumBytes else {
                throw AssistantIssue.invalidInput("Choose a non-empty attachment of 2 MB or less.")
            }
            body["attachments"] = [["name": attachment.name, "contentType": attachment.contentType,
                                    "dataBase64": attachment.data.base64EncodedString()]]
        }
        if let context = FocusContext.current { body["context"] = context }
        return try await post("/runs", body: body, expecting: requestID, requiredSession: requiredSession)
    }

    func briefing(context: String? = nil, requestID: UUID = UUID()) async throws -> IterateRun {
        var body: [String: Any] = ["id": requestID.uuidString.lowercased(), "kind": "briefing",
                                   "prompt": "Prepare my briefing. Summarize commitments, open tasks and decisions that need my attention."]
        let relevant = [FocusContext.current, context].compactMap { $0 }.joined(separator: "\n")
        if !relevant.isEmpty { body["context"] = String(relevant.prefix(2_000)) }
        return try await post("/runs", body: body, expecting: requestID)
    }

    func refresh(id: UUID) async throws -> IterateRun {
        let path = "/runs/" + id.uuidString.lowercased()
        let (data, session) = try await request("GET", path: path)
        var run = try Self.decoder().decode(IterateRun.self, from: data)
        guard run.id == id else { throw ConnectionIssue.invalidResponse }
        var length = run.response?.utf16.count ?? 0
        let total = run.responseLength ?? length
        run.responseLength = total
        let revision = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(run.updatedAt)
        while length < total {
            try Task.checkCancellation()
            var query = URLComponents()
            query.queryItems = [.init(name: "from", value: String(length)), .init(name: "at", value: revision)]
            let (page, _) = try await request("GET", path: path + "/response?" + (query.percentEncodedQuery ?? ""),
                                              requiredSession: session)
            struct Chunk: Decodable { let text: String }
            let text = try JSONDecoder().decode(Chunk.self, from: page).text
            let added = text.utf16.count
            guard added > 0, added <= total - length else { throw ConnectionIssue.invalidResponse }
            if run.response == nil { run.response = "" }
            run.response?.append(text)
            length += added
        }
        return run
    }

    func reply(to id: UUID, text: String, requestID: UUID = UUID(), expectedUpdatedAt: String? = nil,
               requiredSession: String? = nil) async throws -> IterateRun {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 16_000 else {
            throw AssistantIssue.invalidInput("Enter a reply of up to 16,000 characters.")
        }
        var body = ["id": requestID.uuidString.lowercased(), "text": text]
        body["expectedUpdatedAt"] = expectedUpdatedAt
        return try await post("/runs/" + id.uuidString.lowercased() + "/reply", body: body, expecting: id, requiredSession: requiredSession)
    }

    func awaitAnswer(
        for run: IterateRun,
        until deadline: ContinuousClock.Instant,
        refresh: @escaping @MainActor @Sendable (UUID) async throws -> IterateRun = { try await AssistantCenter.shared.refresh(id: $0) }
    ) async throws -> IterateRun {
        var latest = run.hasFullResponse ? run : try await refresh(run.id)
        while latest.isPending, ContinuousClock.now.advanced(by: .seconds(2)) < deadline {
            try await Task.sleep(for: .seconds(2))
            let beforeDeadline = try await withThrowingTaskGroup(of: IterateRun?.self) { group in
                group.addTask { try await refresh(run.id) }
                group.addTask { try await Task.sleep(until: deadline, clock: .continuous); return nil }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            guard let beforeDeadline else { break }
            latest = beforeDeadline
        }
        return latest
    }

    private func post(_ path: String, body: [String: Any], expecting id: UUID,
                      requiredSession: String? = nil) async throws -> IterateRun {
        let (data, _) = try await request("POST", path: path, body: body, requiredSession: requiredSession)
        let run = try Self.decoder().decode(IterateRun.self, from: data)
        guard run.id == id else { throw ConnectionIssue.invalidResponse }
        return run
    }

    func request(_ method: String, path: String, body: [String: Any]? = nil, requiredSession: String? = nil) async throws -> (Data, String) {
        var credentials = try await PairedSession.credentials()
        let session = requiredSession ?? credentials.clientID
        guard credentials.clientID == session else { throw AssistantIssue.changedSession }
        let data: Data
        do {
            let link = foregroundSession.flatMap { $0.id == credentials.clientID ? $0.link : nil }
            data = try await transport.request(method, path: path, body: body, using: credentials, over: link)
        } catch ConnectionIssue.refused {
            credentials = try await PairedSession.credentials(replacing: credentials.accessToken)
            guard credentials.clientID == session else { throw AssistantIssue.changedSession }
            data = try await transport.request(method, path: path, body: body, using: credentials)
        } catch ConnectionIssue.lostConnection {
            try Task.checkCancellation()
            guard try CredentialStore().load()?.clientID == session else { throw AssistantIssue.changedSession }
            data = try await transport.request(method, path: path, body: body, using: credentials)
        }
        guard try CredentialStore().load()?.clientID == credentials.clientID else { throw AssistantIssue.changedSession }
        return (data, credentials.clientID)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
            return try Date.ISO8601FormatStyle().parse(string)
        }
        return decoder
    }
}

enum FocusContext {
    static let key = "iterate.focusContext." + Deployment.current.workspaceKey
    static var current: String? { UserDefaults(suiteName: IterateAppGroup.identifier)?.string(forKey: key) }
}
