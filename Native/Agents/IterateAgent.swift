import Foundation

struct IterateAgent: Identifiable, Codable, Equatable, Sendable {
    let path: String
    let name: String
    let lastActive: Date?

    var id: String { path }

    static func linkedPath(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let path: String
        switch (parts.scheme?.lowercased(), parts.host?.lowercased()) {
        case (Deployment.current.urlScheme, "agents"):
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
}
