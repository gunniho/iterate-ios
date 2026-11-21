import os
import WatchConnectivity

/// Relays a paired Apple Watch’s current conversation to the mind.
@MainActor
final class IterateCompanions: NSObject, WCSessionDelegate {
    static let shared = IterateCompanions()
    private let logger = Logger(subsystem: Deployment.current.bundleID, category: "Companions")
    private var started = false
    static let pairingKey = "IterateCompanionsPaired." + Deployment.current.workspaceKey
    private(set) var paired = UserDefaults.standard.bool(forKey: IterateCompanions.pairingKey)
    private var pairingGeneration = 0

    func start() {
        guard !started else { return }
        started = true
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func setPaired(_ value: Bool) {
        guard value != paired else { return }
        paired = value
        pairingGeneration += 1
        UserDefaults.standard.set(value, forKey: Self.pairingKey)
        pushOverview()
    }

    private func overview() -> IterateWatchOverview { .init(paired: paired, publishedAt: .now) }

    private func pushOverview() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        do {
            let data = try JSONEncoder().encode(overview())
            try session.updateApplicationContext(["iterateOverview": data])
        } catch { logger.error("Watch overview update failed (\((error as NSError).code, privacy: .public))") }
    }

    private func answer(_ request: IterateWatchRequest) async -> IterateWatchReply {
        guard request.workspace == Deployment.current.workspaceKey else {
            return .init(error: "Use the same Iterate workspace on your watch and iPhone.")
        }
        guard paired else { return .init(overview: overview(), error: "Pair Iterate on iPhone first.") }
        let generation = pairingGeneration
        do {
            let run: IterateRun
            switch request.command {
            case .overview: return .init(overview: overview())
            case .ask, .reply:
                let text = (request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 2000, let requestID = request.requestID else {
                    return .init(error: "Enter a question of 2,000 characters or fewer.")
                }
                if request.command == .reply {
                    guard let id = request.runID else { return .init(error: "Ask Iterate a question first.") }
                    run = try await AssistantCenter.shared.reply(to: id, text: text, requestID: requestID)
                } else {
                    run = try await AssistantCenter.shared.submit(text: text, requestID: requestID)
                }
            case .refresh:
                guard let id = request.runID else { return .init(error: "Ask Iterate a question first.") }
                run = try await AssistantCenter.shared.refresh(id: id)
            }
            guard paired, generation == pairingGeneration else { return .init(overview: overview(), error: "Iterate was disconnected.") }
            // WatchConnectivity messages have a transfer-size limit.
            let reply = run.response.map { text in
                let preview = String(text.prefix(4000))
                return preview == text ? text : preview + "\n\n" + run.url.absoluteString
            }
            return .init(overview: overview(), runID: run.id, status: run.status.rawValue, answer: reply)
        } catch { return .init(overview: overview(), error: error.localizedDescription) }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.pushOverview() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushOverview() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        guard messageData.count <= 16384, let request = try? JSONDecoder().decode(IterateWatchRequest.self, from: messageData) else {
            replyHandler(IterateWatchReply(error: "Invalid Apple Watch request.").data())
            return
        }
        let reply = WatchReplyCallback(replyHandler)
        Task { @MainActor in reply.send(await self.answer(request).data()) }
    }
}

// WatchConnectivity provides this one-shot completion on its delegate queue and accepts it asynchronously.
private final class WatchReplyCallback: @unchecked Sendable {
    let send: (Data) -> Void
    init(_ send: @escaping (Data) -> Void) { self.send = send }
}
