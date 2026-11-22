import Foundation
import Observation
import WidgetKit

actor AgentDirectoryCache {
    static let shared = AgentDirectoryCache()

    struct Snapshot: Codable, Sendable {
        let account: String
        let sessionID: String
        let rows: [IterateAgent]
        let archivedPaths: Set<String>? // Optional for snapshots written by older builds.
    }

    private let file: URL
    private let credentials: CredentialStore

    init(file: URL = URL.cachesDirectory.appendingPathComponent("IterateAgents-" + Deployment.current.workspaceKey + ".json"),
         credentials: CredentialStore = CredentialStore()) {
        self.file = file
        self.credentials = credentials
    }

    func load(for sessionID: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.account == credentials.account, snapshot.sessionID == sessionID else { return nil }
        return snapshot
    }

    func save(_ rows: [IterateAgent], archivedPaths: Set<String>, for sessionID: String) throws {
        guard try credentials.load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
        let data = try JSONEncoder().encode(Snapshot(account: credentials.account, sessionID: sessionID, rows: rows,
                                                     archivedPaths: archivedPaths))
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
    private(set) var archivedPaths: Set<String> = []
    private(set) var archivingPaths: Set<String> = []
    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var archiveRevision = UUID()
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var restore: Task<Void, Never>?
    @ObservationIgnored private var request: (link: MindSocket, task: Task<Void, Never>)?
    @ObservationIgnored private var early: (link: MindSocket, asked: Date, answer: Task<Catalog, Error>)?
    private let cache: AgentDirectoryCache
    private typealias Catalog = (rows: [IterateAgent], archive: Result<Set<String>, Error>)

    init(cache: AgentDirectoryCache = .shared) { self.cache = cache }

    func selectSession(_ id: String?) {
        guard sessionID != id else { return }
        restore?.cancel()
        request?.task.cancel()
        request = nil
        early?.answer.cancel()
        early = nil
        if let previous = sessionID { Task { await cache.remove(for: previous) } }
        sessionID = id
        sessionGeneration = UUID()
        archivedPaths = []
        archivingPaths = []
        rows = nil
        refreshError = nil
        guard let id else { return }
        restore = Task {
            let saved = await cache.load(for: id)
            guard !Task.isCancelled, sessionID == id, rows == nil else { return }
            archivedPaths.formUnion(saved?.archivedPaths ?? [])
            rows = saved?.rows
            #if DEBUG
            if saved != nil { AgentLaunchTiming.mark("cached catalog ready") }
            #endif
        }
    }

    /// Ask for the catalog as the socket opens, while the mind is still confirming who it is.
    /// The first refresh on this link uses the answer, and only a confirmed link is refreshed.
    func ask(on link: MindSocket) {
        guard sessionID != nil, early?.link !== link else { return }
        early?.answer.cancel()
        early = (link, .now, Task { try await Self.catalog(on: link) })
    }

    private static func catalog(on link: MindSocket) async throws -> Catalog {
        async let archive = link.archivedAgentPaths()
        let rows = try await link.agentCatalog()
        do { return (rows, .success(try await archive)) }
        catch { return (rows, .failure(error)) }
    }

    func refresh(on link: MindSocket) async {
        guard let id = sessionID else { return }
        let generation = sessionGeneration
        if let request, request.link === link {
            await request.task.value
            return
        }
        request?.task.cancel()
        let revision = archiveRevision
        var started = Date.now
        var asked: Task<Catalog, Error>?
        if let early, early.link === link, started.timeIntervalSince(early.asked) < 10 {
            asked = early.answer
            started = early.asked
        }
        early = nil
        let task = Task {
            do {
                let (latest, archiveResult): Catalog
                if let asked { (latest, archiveResult) = try await asked.value }
                else { (latest, archiveResult) = try await Self.catalog(on: link) }
                // Preserve the paired device’s cached archive if the server cannot load it.
                if case .failure = archiveResult { await restore?.value }
                try Task.checkCancellation()
                guard sessionGeneration == generation else { return }
                rows = latest
                #if DEBUG
                AgentLaunchTiming.mark("fresh catalog ready")
                #endif
                switch archiveResult {
                case .success(let paths):
                    refreshError = nil
                    if archiveRevision == revision {
                        archivedPaths = paths
                        let snapshot = RecentAgentsSnapshot(catalog: latest, excluding: paths, checkedAt: started)
                        let previous = RecentAgentsSnapshotStore.load(for: id)
                        if let saved = try? RecentAgentsSnapshotStore.confirmed(snapshot, for: id),
                           previous?.rows != saved.rows {
                            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.recentAgentsWidgetKind)
                        }
                    }
                case .failure(let error):
                    handleRefreshError(error, for: id, started: started)
                }
                // The catalog is usable even when iOS cannot retain a local copy.
                try? await cache.save(latest, archivedPaths: archivedPaths, for: id)
            } catch {
                if !Task.isCancelled, sessionGeneration == generation { handleRefreshError(error, for: id, started: started) }
            }
        }
        request = (link, task)
        await task.value
        if request?.link === link, sessionGeneration == generation { request = nil }
    }

    private func handleRefreshError(_ error: Error, for id: String, started: Date) {
        refreshError = error.localizedDescription
        if PairedSession.isAccessDenied(error) {
            RecentAgentsSnapshotStore.invalidate(for: id, through: started)
            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.recentAgentsWidgetKind)
        }
    }

    func archive(_ path: String, onConfirmed: (@MainActor () -> Void)? = nil,
                 perform: @MainActor () async throws -> Void) async throws {
        guard let id = sessionID else { throw AssistantIssue.unpaired }
        guard !archivedPaths.contains(path), archivingPaths.insert(path).inserted else { return }
        let generation = sessionGeneration
        defer { if sessionGeneration == generation { archivingPaths.remove(path) } }
        do { try await perform() }
        catch {
            guard sessionGeneration == generation else { throw CancellationError() }
            throw error
        }
        guard sessionGeneration == generation else { throw CancellationError() }
        // A refresh that started before this write must not put the row back.
        archiveRevision = UUID()
        archivedPaths.insert(path)
        RecentAgentsSnapshotStore.remove(path: path, for: id, at: .now)
        WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.recentAgentsWidgetKind)
        // Stage the visible exit in the same main-actor turn as the confirmed archive.
        onConfirmed?()
        if let rows { try? await cache.save(rows, archivedPaths: archivedPaths, for: id) }
    }
}
