import Foundation
import Observation
import WatchConnectivity
import WidgetKit

struct WatchRelayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()
    private(set) var overview = WatchOverviewCache.read()
    private(set) var reachable = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var overviewWork: Task<Void, Never>?

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        if !UserDefaults.standard.bool(forKey: "IterateLauncherComplication") {
            WidgetCenter.shared.reloadTimelines(ofKind: WatchOverviewCache.widget)
            UserDefaults.standard.set(true, forKey: "IterateLauncherComplication")
        }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func request(_ request: IterateWatchRequest) async throws -> IterateWatchReply {
        start()
        guard WCSession.isSupported() else { throw WatchRelayError(message: "This watch needs a paired iPhone.") }
        let session = WCSession.default
        for _ in 0..<20 where session.activationState != .activated {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard session.isReachable else {
            throw WatchRelayError(message: "Open Iterate on your paired iPhone, then try again.")
        }
        let data = try JSONEncoder().encode(request)
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            session.sendMessageData(data, replyHandler: { @Sendable in continuation.resume(returning: $0) },
                                    errorHandler: { @Sendable in continuation.resume(throwing: $0) })
        }
        try Task.checkCancellation()
        let value = try JSONDecoder().decode(IterateWatchReply.self, from: reply)
        if let snapshot = value.overview { receive(snapshot) }
        if let message = value.error { throw WatchRelayError(message: message) }
        return value
    }

    private func receive(_ snapshot: IterateWatchOverview) {
        if WatchOverviewCache.store(snapshot) {
            overview = snapshot
        }
    }

    private func refreshOverview() {
        guard reachable, overviewWork == nil else { return }
        overviewWork = Task {
            defer { overviewWork = nil }
            _ = try? await request(.init(command: .overview))
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let bytes = session.receivedApplicationContext["iterateOverview"] as? Data
        Task { @MainActor in
            self.reachable = reachable
            if let bytes, let snapshot = try? JSONDecoder().decode(IterateWatchOverview.self, from: bytes) {
                self.receive(snapshot)
            }
            if state == .activated { self.refreshOverview() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            self.refreshOverview()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let bytes = applicationContext["iterateOverview"] as? Data,
              let snapshot = try? JSONDecoder().decode(IterateWatchOverview.self, from: bytes) else { return }
        Task { @MainActor in self.receive(snapshot) }
    }
}
