import Foundation
import Observation

actor AgentDirectoryCache {
    static let shared = AgentDirectoryCache()

    private struct Snapshot: Codable {
        let account: String
        let sessionID: String
        let rows: [IterateAgent]
    }

    private let file: URL
    private let credentials: CredentialStore

    init(file: URL = URL.cachesDirectory.appendingPathComponent("IterateAgents-" + Deployment.current.workspaceKey + ".json"),
         credentials: CredentialStore = CredentialStore()) {
        self.file = file
        self.credentials = credentials
    }

    func load(for sessionID: String) -> [IterateAgent]? {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.account == credentials.account, snapshot.sessionID == sessionID else { return nil }
        return snapshot.rows
    }

    func save(_ rows: [IterateAgent], for sessionID: String) throws {
        guard try credentials.load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
        let data = try JSONEncoder().encode(Snapshot(account: credentials.account, sessionID: sessionID, rows: rows))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    func remove(for sessionID: String) {
        if load(for: sessionID) != nil { try? FileManager.default.removeItem(at: file) }
    }
}

@MainActor @Observable
final class AgentDirectory {
    private(set) var rows: [IterateAgent]?
    private(set) var refreshError: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var restore: Task<Void, Never>?
    @ObservationIgnored private var request: (link: MindSocket, task: Task<Void, Never>)?
    private let cache: AgentDirectoryCache

    init(cache: AgentDirectoryCache = .shared) { self.cache = cache }

    func selectSession(_ id: String?) {
        guard sessionID != id else { return }
        restore?.cancel()
        request?.task.cancel()
        request = nil
        if let previous = sessionID { Task { await cache.remove(for: previous) } }
        sessionID = id
        rows = nil
        refreshError = nil
        guard let id else { return }
        restore = Task {
            let saved = await cache.load(for: id)
            guard !Task.isCancelled, sessionID == id, rows == nil else { return }
            rows = saved
            #if DEBUG
            if saved != nil { AgentLaunchTiming.mark("cached catalog ready") }
            #endif
        }
    }

    func refresh(on link: MindSocket) async {
        guard let id = sessionID else { return }
        if let request, request.link === link {
            await request.task.value
            return
        }
        request?.task.cancel()
        let task = Task {
            do {
                let wire = try await link.call(path: ["mind", "agents", "list"])
                let latest = try IterateAgent.catalog(from: wire)
                try Task.checkCancellation()
                guard sessionID == id else { return }
                rows = latest
                #if DEBUG
                AgentLaunchTiming.mark("fresh catalog ready")
                #endif
                refreshError = nil
                // The catalog is usable even when iOS cannot retain a local copy.
                try? await cache.save(latest, for: id)
            } catch {
                if !Task.isCancelled, sessionID == id { refreshError = error.localizedDescription }
            }
        }
        request = (link, task)
        await task.value
        if request?.link === link, sessionID == id { request = nil }
    }
}
