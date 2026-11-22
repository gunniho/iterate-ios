import Foundation

struct RecentAgentsSnapshot: PairedWidgetSnapshot, Equatable, Sendable {
    static let maximumRows = 10
    static let service = WidgetSnapshotService.recentAgents
    let rows: [IterateAgent]
    let checkedAt: Date

    init(rows: [IterateAgent], checkedAt: Date) {
        self.rows = Array(rows.prefix(Self.maximumRows))
        self.checkedAt = checkedAt
    }

    func isFresh(at date: Date) -> Bool {
        checkedAt.timeIntervalSinceReferenceDate.isFinite && checkedAt <= date &&
        rows.count <= Self.maximumRows && Set(rows.map(\.path)).count == rows.count &&
        rows.allSatisfy { row in
            row.widgetURL != nil && !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            row.lastActive?.timeIntervalSinceReferenceDate.isFinite != false
        }
    }
}

typealias RecentAgentsSnapshotStore = PairedWidgetSnapshotStore<RecentAgentsSnapshot>

extension PairedWidgetSnapshotStore where Snapshot == RecentAgentsSnapshot {
    static func remove(path: String, for sessionID: String, at date: Date) {
        shared.remove(path: path, for: sessionID, at: date)
    }

    func remove(path: String, for sessionID: String, at date: Date) {
        amend(for: sessionID, at: date) { previous in
            RecentAgentsSnapshot(rows: previous.rows.filter { $0.path != path }, checkedAt: previous.checkedAt)
        }
    }
}
