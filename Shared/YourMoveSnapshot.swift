import Foundation

struct YourMoveSnapshot: PairedWidgetSnapshot, Equatable, Sendable {
    static let service = WidgetSnapshotService.yourMove
    let approvalCount: Int
    let questionCount: Int
    let checkedAt: Date

    var expiresAt: Date { checkedAt.addingTimeInterval(60 * 60) }

    func isFresh(at date: Date) -> Bool {
        approvalCount >= 0 && questionCount >= 0 && approvalCount <= Int.max - questionCount &&
        checkedAt <= date && date < expiresAt
    }
}

typealias YourMoveSnapshotStore = PairedWidgetSnapshotStore<YourMoveSnapshot>
