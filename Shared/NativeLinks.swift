import Foundation

enum NativeDestination: Equatable, Hashable, Sendable {
    case agents, newAgent, talk, capture, camera, briefing, yourMove
    case web(URL)

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        if url == NativeDestination.yourMove.url { self = .yourMove; return }
        if url == NativeDestination.agents.url { self = .agents; return }
        let segments: [String]
        if parts.scheme == "https", parts.host?.lowercased() == Deployment.current.apexHost {
            segments = parts.path.split(separator: "/").map(String.init)
        } else if parts.scheme?.lowercased() == Deployment.current.urlScheme, let host = parts.host {
            segments = [host] + parts.path.split(separator: "/").map(String.init)
        } else { return nil }
        switch segments {
        case ["new-agent"]: self = .newAgent
        case ["talk"]: self = .talk
        case ["capture"]: self = .capture
        case ["camera"]: self = .camera
        case ["briefing"]: self = .briefing
        case ["runs"], ["inbox"]: self = .web(Deployment.current.website.appendingPathComponent("runs"))
        default:
            guard segments.count == 2, ["runs", "read"].contains(segments[0]),
                  let id = UUID(uuidString: segments[1]) else { return nil }
            self = .web(Deployment.current.runURL(id))
        }
    }

    var url: URL {
        let path: String
        switch self {
        case .agents: return URL(string: Deployment.current.urlScheme + "://agents")!
        case .newAgent: path = "new-agent"
        case .talk: path = "talk"
        case .capture: path = "capture"
        case .camera: path = "camera"
        case .briefing: path = "briefing"
        case .yourMove: return URL(string: Deployment.current.urlScheme + "://your-move")!
        case let .web(url): return url
        }
        return Deployment.current.website.appendingPathComponent(path)
    }
}

extension Notification.Name {
    static let iterateRouteChanged = Notification.Name(Deployment.current.bundleID + ".routeChanged")
}

@MainActor
final class NativeRouteBus {
    static let shared = NativeRouteBus()
    private(set) var destination: NativeDestination?

    func open(_ destination: NativeDestination) {
        self.destination = destination
        NotificationCenter.default.post(name: .iterateRouteChanged, object: nil)
    }

    func take() -> NativeDestination? {
        defer { destination = nil }
        return destination
    }
}
