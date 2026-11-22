import Foundation
import Security

protocol PairedWidgetSnapshot: Codable {
    static var service: WidgetSnapshotService { get }
    var checkedAt: Date { get }
    func isFresh(at date: Date) -> Bool
}

enum WidgetSnapshotService: CaseIterable {
    case yourMove, recentAgents

    var name: String {
        switch self {
        case .yourMove: Deployment.current.bundleID + ".your-move-counts"
        case .recentAgents: Deployment.current.bundleID + ".recent-agents-list"
        }
    }

    static func selectPairing(_ id: String?) {
        for service in allCases {
            WidgetSnapshotItem(service: service, account: Deployment.current.credentialAccount).select(id)
        }
    }
}

struct PairedWidgetSnapshotStore<Snapshot: PairedWidgetSnapshot> {
    private struct Record: Codable {
        let sessionID: String?
        let snapshot: Snapshot?
        let invalidatedThrough: Date?
        // An archive edits the existing list without making its other rows any fresher.
        let amendedThrough: Date?
    }

    static var shared: Self {
        Self(account: Deployment.current.credentialAccount, session: { try CredentialStore().load()?.clientID })
    }

    static func load(for sessionID: String? = nil) -> Snapshot? {
        shared.readFresh(at: .now, for: sessionID)
    }

    static func save(_ snapshot: Snapshot, for sessionID: String) {
        shared.write(snapshot, for: sessionID, at: .now)
    }

    static func confirmed(_ snapshot: Snapshot, for sessionID: String) throws -> Snapshot {
        try shared.confirm(snapshot, for: sessionID, at: .now)
    }

    static func invalidate(for sessionID: String, through checkedAt: Date) {
        shared.discard(for: sessionID, through: checkedAt)
    }

    let account: String
    let session: () throws -> String?

    private var item: WidgetSnapshotItem { WidgetSnapshotItem(service: Snapshot.service, account: account) }

    func readFresh(at date: Date, for sessionID: String? = nil) -> Snapshot? {
        guard let record = try? item.read(Record.self)?.record, let id = record.sessionID,
              sessionID == nil || sessionID == id,
              let snapshot = record.snapshot, snapshot.isFresh(at: date) else { return nil }
        do {
            guard try session() == id else { return nil }
        } catch {
            let error = error as NSError
            guard error.domain == NSOSStatusErrorDomain, error.code == Int(errSecInteractionNotAllowed) else { return nil }
            // The snapshot item remains accessible while locked. Sign-out invalidates its pairing first.
        }
        return snapshot
    }

    func write(_ snapshot: Snapshot, for id: String, at date: Date) {
        guard snapshot.isFresh(at: date) else { return }
        item.update(Record.self) { previous in
            guard try session() == id,
                  previous == nil || previous?.sessionID == id else { return nil }
            if let denied = previous?.invalidatedThrough, snapshot.checkedAt <= denied { return nil }
            if let amended = previous?.amendedThrough, snapshot.checkedAt <= amended { return nil }
            if let last = previous?.snapshot, last.isFresh(at: date), last.checkedAt >= snapshot.checkedAt { return nil }
            return Record(sessionID: id, snapshot: snapshot, invalidatedThrough: previous?.invalidatedThrough, amendedThrough: nil)
        }
    }

    func confirm(_ snapshot: Snapshot, for id: String, at date: Date) throws -> Snapshot {
        guard snapshot.isFresh(at: date) else { throw ConnectionIssue.invalidResponse }
        write(snapshot, for: id, at: date)
        guard try session() == id else { throw AssistantIssue.changedSession }
        // A verified response is usable even when the optional Keychain cache is unavailable.
        guard let record = try? item.read(Record.self)?.record else { return snapshot }
        guard record.sessionID == id else { throw AssistantIssue.changedSession }
        if let latest = record.snapshot, latest.isFresh(at: date), latest.checkedAt >= snapshot.checkedAt { return latest }
        if let denied = record.invalidatedThrough, snapshot.checkedAt <= denied {
            throw AssistantIssue.accessDenied("Open Iterate to verify your connection.")
        }
        if let amended = record.amendedThrough, snapshot.checkedAt <= amended {
            guard let latest = record.snapshot, latest.isFresh(at: date) else { throw ConnectionIssue.lostConnection }
            return latest
        }
        return snapshot
    }

    func amend(for id: String, at date: Date, _ transform: (Snapshot) -> Snapshot) {
        item.update(Record.self) { previous in
            if let previous {
                guard previous.sessionID == id else { return nil }
                if let latest = previous.snapshot, latest.checkedAt > date { return nil }
                if let denied = previous.invalidatedThrough, denied >= date { return nil }
            } else {
                guard try session() == id else { return nil }
            }
            let through = max(previous?.amendedThrough ?? date, date)
            return Record(sessionID: id, snapshot: previous?.snapshot.map(transform),
                          invalidatedThrough: previous?.invalidatedThrough, amendedThrough: through)
        }
    }

    func discard(for id: String, through date: Date) {
        item.update(Record.self) { previous in
            if let previous {
                guard previous.sessionID == id else { return nil }
                if let latest = previous.snapshot, latest.checkedAt > date { return nil }
                if let denied = previous.invalidatedThrough, denied >= date { return nil }
            } else {
                guard try session() == id else { return nil }
            }
            return Record(sessionID: id, snapshot: nil, invalidatedThrough: date, amendedThrough: previous?.amendedThrough)
        }
    }

    func select(_ id: String?) { item.select(id) }
}

private struct WidgetSnapshotItem {
    let service: WidgetSnapshotService
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service.name,
         kSecAttrAccount as String: account]
    }

    func select(_ id: String?) {
        // Read only the pairing so that every extension can clear all snapshot types at sign-out.
        struct Pairing: Codable { let sessionID: String? }
        update(Pairing.self) { previous in
            guard previous == nil || previous?.sessionID != id else { return nil }
            return Pairing(sessionID: id)
        }
    }

    func read<Value: Decodable>(_ type: Value.Type) throws -> (revision: Data, record: Value?)? {
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let revision = attributes[kSecAttrGeneric as String] as? Data,
              let data = attributes[kSecValueData as String] as? Data else { throw AssistantIssue.storage }
        return (revision, try? JSONDecoder().decode(type, from: data))
    }

    // Match the revision so concurrent extension and app updates can't overwrite a newer result or sign-out.
    func update<Value: Codable>(_ type: Value.Type, _ next: (Value?) throws -> Value?) {
        for _ in 0..<5 {
            do {
                let old = try read(type)
                guard let record = try next(old?.record) else { return }
                let attributes: [String: Any] = [
                    kSecValueData as String: try JSONEncoder().encode(record),
                    kSecAttrGeneric as String: Data(UUID().uuidString.utf8)
                ]
                if let old {
                    var match = query
                    match[kSecAttrGeneric as String] = old.revision
                    let status = SecItemUpdate(match as CFDictionary, attributes as CFDictionary)
                    if status != errSecItemNotFound { return }
                } else {
                    var item = query.merging(attributes) { _, new in new }
                    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    let status = SecItemAdd(item as CFDictionary, nil)
                    if status != errSecDuplicateItem { return }
                }
            } catch { return }
        }
    }
}
