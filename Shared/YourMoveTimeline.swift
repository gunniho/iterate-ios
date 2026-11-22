import Foundation

struct YourMoveCounts: Decodable {
    let approvalCount: Int
    let questionCount: Int

    private enum CodingKeys: String, CodingKey { case approvalCount, questionCount }

    init(approvalCount: Int, questionCount: Int) throws {
        guard approvalCount >= 0, questionCount >= 0, approvalCount <= Int.max - questionCount else {
            throw ConnectionIssue.invalidResponse
        }
        self.approvalCount = approvalCount
        self.questionCount = questionCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(approvalCount: values.decode(Int.self, forKey: .approvalCount),
                      questionCount: values.decode(Int.self, forKey: .questionCount))
    }

    func snapshot(checkedAt: Date) -> YourMoveSnapshot {
        YourMoveSnapshot(approvalCount: approvalCount, questionCount: questionCount, checkedAt: checkedAt)
    }

    @MainActor static func fetch(requiredSession: String? = nil) async throws -> YourMoveSnapshot {
        guard let member = try requiredSession ?? CredentialStore().load()?.clientID else { throw AssistantIssue.unpaired }
        let started = Date.now
        do {
            let (data, _) = try await AssistantCenter.shared.request("GET", path: "/your-move/summary", requiredSession: member)
            try Task.checkCancellation()
            let snapshot = try JSONDecoder().decode(Self.self, from: data).snapshot(checkedAt: started)
            return try YourMoveSnapshotStore.confirmed(snapshot, for: member)
        } catch {
            if PairedSession.isAccessDenied(error) { YourMoveSnapshotStore.invalidate(for: member, through: started) }
            throw error
        }
    }
}

struct YourMoveTimeline: Sendable {
    enum State: Equatable, Sendable {
        case ready(approvals: Int, questions: Int)
        case stale, unpaired
    }

    let state: State
    let expiresAt: Date?
    let retryAt: Date

    static func live(_ snapshot: YourMoveSnapshot, now: Date) -> Self {
        plan(snapshot, now: now, retryAfter: 30 * 60)
    }

    static func recover(_ snapshot: YourMoveSnapshot?, now: Date) -> Self {
        // Space retries out once the last known counts expire, especially during overnight locks.
        plan(snapshot, now: now, retryAfter: snapshot?.isFresh(at: now) == true ? 5 * 60 : 20 * 60)
    }

    static func unpaired(now: Date) -> Self {
        .init(state: .unpaired, expiresAt: nil, retryAt: now.addingTimeInterval(30 * 60))
    }

    static func afterFailure(_ error: Error, cached: @autoclosure () -> YourMoveSnapshot?, now: Date) -> Self {
        if PairedSession.isAccessDenied(error) { return unpaired(now: now) }
        switch error {
        case AssistantIssue.changedSession, ConnectionIssue.wrongMind:
            return recover(nil, now: now)
        default:
            return recover(cached(), now: now)
        }
    }

    private static func plan(_ snapshot: YourMoveSnapshot?, now: Date, retryAfter: TimeInterval) -> Self {
        let retry = now.addingTimeInterval(retryAfter)
        guard let snapshot, snapshot.isFresh(at: now) else {
            return .init(state: .stale, expiresAt: nil, retryAt: retry)
        }
        return .init(state: .ready(approvals: snapshot.approvalCount, questions: snapshot.questionCount),
                     expiresAt: snapshot.expiresAt, retryAt: min(retry, snapshot.expiresAt))
    }
}
