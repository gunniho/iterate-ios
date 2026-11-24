import ActivityKit
import Foundation

/// What needs the member now, as the Lock Screen and the Dynamic Island show it: how much waits,
/// and the first things in their own words. The mind starts, updates and ends the activity over
/// Apple's push service (`attention.js`), so the type's name and its fields are the push's own.
/// The whole request is read in Your move.
struct IterateAttentionAttributes: ActivityAttributes {
    /// One thing that waits, in one line: a todo's words, who a mail goes to and its subject,
    /// what a statement or a question asks.
    struct Item: Codable, Hashable, Sendable {
        var kind: String
        var text: String

        /// The kind this item is listed as, or nil for one a newer mind names that this build does not know.
        var attentionKind: AttentionKind? {
            switch kind {
            case "urgent": .urgent
            case "approval": .approvals
            case "signature": .signatures
            case "question": .questions
            default: nil
            }
        }
    }

    struct ContentState: Codable, Hashable, Sendable {
        /// How many things the activity names in words. The rest are counted.
        static let mostItems = 3

        var approvals: Int
        var signatures: Int
        var questions: Int
        var urgent: Int
        /// When the oldest of them started to wait, in seconds since 1970. 0 for none.
        var since: Int
        /// The first things that wait, in the order Your move lists them.
        var items: [Item]

        private enum CodingKeys: String, CodingKey { case approvals, signatures, questions, urgent, since, items }

        init(approvals: Int = 0, signatures: Int = 0, questions: Int = 0, urgent: Int = 0, since: Int = 0, items: [Item] = []) {
            self.approvals = Self.count(approvals)
            self.signatures = Self.count(signatures)
            self.questions = Self.count(questions)
            self.urgent = Self.count(urgent)
            self.since = max(0, since)
            let waiting = self.approvals + self.signatures + self.questions + self.urgent
            self.items = Array(items.lazy
                .map { Item(kind: $0.kind, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { $0.attentionKind != nil && !$0.text.isEmpty }
                .prefix(min(Self.mostItems, waiting)))
        }

        /// A push from a newer or older mind may leave a field out. None is read as nothing waiting,
        /// and counts with no words are shown as counts.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            func read(_ key: CodingKeys) -> Int { (try? values.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
            self.init(approvals: read(.approvals), signatures: read(.signatures), questions: read(.questions),
                      urgent: read(.urgent), since: read(.since),
                      items: (try? values.decodeIfPresent([Item].self, forKey: .items)) ?? [])
        }

        private static func count(_ value: Int) -> Int { min(max(0, value), 999) }
    }
}

/// One kind of thing that needs the member, in the order the activity lists them.
enum AttentionKind: CaseIterable, Sendable {
    case urgent, approvals, signatures, questions

    var symbol: String {
        switch self {
        case .urgent: "flag.fill"
        case .approvals: "checkmark.seal.fill"
        case .signatures: "signature"
        case .questions: "questionmark.bubble.fill"
        }
    }

    func label(_ count: Int) -> String {
        switch self {
        case .urgent: "\(count) urgent"
        case .approvals: "\(count) to approve"
        case .signatures: "\(count) to sign"
        case .questions: count == 1 ? "1 question" : "\(count) questions"
        }
    }
}

extension IterateAttentionAttributes.ContentState {
    var total: Int { approvals + signatures + questions + urgent }

    func count(of kind: AttentionKind) -> Int {
        switch kind {
        case .urgent: urgent
        case .approvals: approvals
        case .signatures: signatures
        case .questions: questions
        }
    }

    /// The kinds that have something waiting, the most pressing first.
    var kinds: [AttentionKind] { AttentionKind.allCases.filter { count(of: $0) > 0 } }

    /// The kind that leads the compact presentations: the first thing's own, where it is named.
    var leading: AttentionKind? { items.first?.attentionKind ?? kinds.first }

    /// How many things wait beyond the ones named in words.
    var unnamed: Int { max(0, total - items.count) }

    var waitingSince: Date? { since > 0 ? Date(timeIntervalSince1970: TimeInterval(since)) : nil }

    /// "1 urgent · 2 to approve": every kind that waits, in one line.
    var line: String { kinds.map { $0.label(count(of: $0)) }.joined(separator: " · ") }

    var spoken: String {
        guard total > 0 else { return "Nothing needs you in Iterate" }
        guard !items.isEmpty else { return "Waiting for you in Iterate: " + kinds.map { $0.label(count(of: $0)) }.joined(separator: ", ") }
        return "Waiting for you in Iterate: " + items.map(\.text).joined(separator: ". ") + (unnamed > 0 ? ". And \(unnamed) more." : "")
    }
}

/// What to do with the activity on this iPhone, given the one it shows and what waits now.
enum AttentionActivityStep: Equatable, Sendable {
    case none, start, update, end

    /// `shown`: the content of the activity on screen, or nil for none. A member who turned Live
    /// Activities off is shown none, and one that is up then is taken away. `dismissed`: the
    /// content of the activity the member last swiped away, which the same counts do not bring back.
    static func from(shown: IterateAttentionAttributes.ContentState?, to next: IterateAttentionAttributes.ContentState,
                     enabled: Bool, dismissed: IterateAttentionAttributes.ContentState? = nil) -> Self {
        guard enabled, next.total > 0 else { return shown == nil ? .none : .end }
        guard let shown else { return next == dismissed ? .none : .start }
        return shown == next ? .none : .update
    }
}
