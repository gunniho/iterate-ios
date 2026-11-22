import Foundation

struct RecentAgentsTimeline: Sendable {
    enum State: Equatable, Sendable {
        case list(RecentAgentsSnapshot)
        case unpaired, unavailable
    }

    let state: State
    let retryAt: Date

    static func live(_ snapshot: RecentAgentsSnapshot, now: Date) -> Self {
        guard snapshot.isFresh(at: now) else { return cached(nil, now: now) }
        return .init(state: .list(snapshot), retryAt: now.addingTimeInterval(30 * 60))
    }

    static func cached(_ snapshot: RecentAgentsSnapshot?, now: Date) -> Self {
        guard let snapshot, snapshot.isFresh(at: now) else {
            return .init(state: .unavailable, retryAt: now.addingTimeInterval(20 * 60))
        }
        let retryMinutes = now.timeIntervalSince(snapshot.checkedAt) < 3600 ? 5.0 : 20.0
        return .init(state: .list(snapshot), retryAt: now.addingTimeInterval(retryMinutes * 60))
    }

    static func afterFailure(_ error: Error, cached snapshot: @autoclosure () -> RecentAgentsSnapshot?, now: Date) -> Self {
        if PairedSession.isAccessDenied(error) {
            return .init(state: .unpaired, retryAt: now.addingTimeInterval(30 * 60))
        }
        switch error {
        case AssistantIssue.changedSession, ConnectionIssue.wrongMind:
            return cached(nil, now: now)
        default:
            return cached(snapshot(), now: now)
        }
    }
}
