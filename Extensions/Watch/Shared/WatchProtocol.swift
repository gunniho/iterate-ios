import Foundation

struct IterateWatchOverview: Codable, Sendable {
    var workspace = Deployment.current.workspaceKey
    let paired: Bool
    let publishedAt: Date
}

struct IterateWatchRequest: Codable, Sendable {
    enum Command: String, Codable { case ask, refresh, reply, overview }
    var workspace = Deployment.current.workspaceKey
    let command: Command
    var text: String?
    var runID: UUID?
    var requestID: UUID?
}

struct IterateWatchReply: Codable, Sendable {
    var overview: IterateWatchOverview?
    var runID: UUID?
    var status: String?
    var answer: String?
    var error: String?

    func data() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data(#"{"error":"Invalid reply from Iterate."}"#.utf8)
    }
}

#if os(watchOS)
enum WatchOverviewCache {
    static let key = "IterateWatchOverview." + Deployment.current.workspaceKey
    static let widget = Deployment.current.bundleID + ".watch.status"

    static func read() -> IterateWatchOverview? {
        guard let bytes = UserDefaults(suiteName: Deployment.current.appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(IterateWatchOverview.self, from: bytes)
    }

    @discardableResult
    static func store(_ overview: IterateWatchOverview) -> Bool {
        guard overview.workspace == Deployment.current.workspaceKey,
              let defaults = UserDefaults(suiteName: Deployment.current.appGroup),
              read().map({ $0.publishedAt <= overview.publishedAt }) ?? true,
              let bytes = try? JSONEncoder().encode(overview) else { return false }
        defaults.set(bytes, forKey: key)
        return true
    }
}
#endif
