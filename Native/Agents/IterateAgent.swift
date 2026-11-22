import Foundation

struct IterateAgent: Identifiable, Codable, Equatable, Sendable {
    let path: String
    let name: String
    let lastActive: Date?

    var id: String { path }

    var widgetURL: URL? {
        guard Self.isAgentPath(path),
              var parts = URLComponents(url: NativeDestination.agents.url, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "contextPath", value: path)]
        return parts.url
    }

    static func linkedPath(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path: String
        switch (parts.scheme?.lowercased(), parts.host?.lowercased()) {
        case (Deployment.current.urlScheme, "agents") where parts.path.isEmpty:
            guard parts.fragment == nil,
                  let items = parts.queryItems, items.count == 1, items[0].name == "contextPath",
                  let context = items[0].value else { return nil }
            path = context
        case (Deployment.current.urlScheme, "agents"):
            // A link that names its agent twice is refused.
            guard parts.queryItems?.contains(where: { $0.name == "contextPath" }) != true else { return nil }
            path = "/agents" + parts.path
        case ("https", Deployment.current.dashHost):
            if parts.path == "/agents", let context = parts.queryItems?.first(where: { $0.name == "contextPath" })?.value {
                path = context
            } else if parts.path.hasPrefix("/agents/agents/") {
                path = String(parts.path.dropFirst("/agents".count))
            } else { return nil }
        default:
            return nil
        }
        return isAgentPath(path) ? path : nil
    }

    private static func isAgentPath(_ path: String) -> Bool {
        path.hasPrefix("/agents/") && path.count > "/agents/".count
    }

    @MainActor static func catalog(from wire: Any) throws -> [IterateAgent] {
        guard let records = try NativeMindTransport.decodeLiteral(wire) as? [[String: Any]] else {
            throw ConnectionIssue.invalidResponse
        }
        var agents: [IterateAgent] = []
        var paths = Set<String>()
        for record in records {
            guard let path = record["path"] as? String, isAgentPath(path) else { throw ConnectionIssue.invalidResponse }
            guard paths.insert(path).inserted else { continue }
            let title = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? String(path.split(separator: "/").last!)
            let active = timestamp(record["lastActivityAt"]) ?? timestamp(record["createdAt"])
            agents.append(IterateAgent(path: path, name: name, lastActive: active))
        }
        return agents.sorted {
            if $0.lastActive != $1.lastActive { return ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
            return $0.path < $1.path
        }
    }

    private static func timestamp(_ field: Any?) -> Date? {
        guard let text = field as? String else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    static func recent(in sortedCatalog: [IterateAgent], excluding archived: Set<String>, limit: Int) -> [IterateAgent] {
        Array(sortedCatalog.lazy.filter { !archived.contains($0.path) }.prefix(max(0, limit)))
    }
}

@MainActor
extension MindSocket {
    func agentCatalog() async throws -> [IterateAgent] {
        try IterateAgent.catalog(from: await call(path: ["mind", "agents", "list"]))
    }

    func archivedAgentPaths() async throws -> Set<String> {
        struct Archive: Decodable { let paths: Set<String> }
        let data = try await NativeMindTransport().invoke("GET", path: "/agents/archive", body: nil, over: self)
        return try JSONDecoder().decode(Archive.self, from: data).paths
    }
}

extension AssistantCenter {
    func recentAgentsSnapshot() async throws -> RecentAgentsSnapshot {
        guard let member = try CredentialStore().load()?.clientID else { throw AssistantIssue.unpaired }
        let started = Date.now
        do {
            let (snapshot, _) = try await withPairedSession(requiredSession: member) { link in
                async let archive = link.archivedAgentPaths()
                let catalog = try await link.agentCatalog()
                return try await RecentAgentsSnapshot(catalog: catalog, excluding: archive, checkedAt: started)
            }
            try Task.checkCancellation()
            return try RecentAgentsSnapshotStore.confirmed(snapshot, for: member)
        } catch {
            if PairedSession.isAccessDenied(error) { RecentAgentsSnapshotStore.invalidate(for: member, through: started) }
            throw error
        }
    }
}

extension RecentAgentsSnapshot {
    init(catalog: [IterateAgent], excluding archive: Set<String>, checkedAt: Date) {
        self.init(rows: IterateAgent.recent(in: catalog, excluding: archive, limit: Self.maximumRows), checkedAt: checkedAt)
    }
}
