import ActivityKit
import CoreSpotlight
import FileProvider
import OSLog
import UIKit
import UserNotifications
import WidgetKit

// The old attribute name and fields allow the upgraded app to dismiss only its task activities.
struct IterateRunAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let status: String
        let updatedAt: String
    }
    let runID: String
}

@MainActor
enum TaskInboxUpgrade {
    private static let logger = Logger(subsystem: Deployment.current.bundleID, category: "Upgrade")
    private static let finishedKey = "IterateTaskInboxRemoved." + Deployment.current.workspaceKey
    private static var clearing = false
    private static var retiring = false

    static func removeLocalInbox() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: finishedKey), !clearing else { return }
        clearing = true
        defer { clearing = false }
        do {
            let root = try IterateAppGroup.container()
            WidgetCenter.shared.reloadTimelines(ofKind: Deployment.current.bundleID + ".today")
            if UIApplication.shared.isRegisteredForRemoteNotifications { UIApplication.shared.unregisterForRemoteNotifications() }
            for activity in Activity<IterateRunAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }

            let center = UNUserNotificationCenter.current()
            let categories: Set<String> = ["ITERATE_DECISION", "ITERATE_RESULT"]
            let pending = await center.pendingNotificationRequests().filter { categories.contains($0.content.categoryIdentifier) }
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            let delivered = await center.deliveredNotifications().map(\.request).filter { categories.contains($0.content.categoryIdentifier) }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.identifier))
            let installed = await center.notificationCategories()
            center.setNotificationCategories(installed.filter { !categories.contains($0.identifier) })

            let hadIndex = defaults.object(forKey: "iterate.searchableTasks") != nil ||
                FileManager.default.fileExists(atPath: root.appendingPathComponent("AssistantCache/runs.json").path)
            if hadIndex { defaults.set(true, forKey: "IterateTaskIndexCleanupPending") }
            try removeCachedResults(in: root)
            defaults.removeObject(forKey: "iterate.apns")
            defaults.removeObject(forKey: "iterate.searchableTasks")
            UserDefaults(suiteName: IterateAppGroup.identifier)?.removeObject(forKey: "trackRuns")

            if defaults.bool(forKey: "IterateTaskIndexCleanupPending") {
                // All items indexed by build 3 were task records, including its IndexedEntity entries.
                try await CSSearchableIndex.default().deleteAllSearchableItems()
                defaults.removeObject(forKey: "IterateTaskIndexCleanupPending")
            }
            if defaults.object(forKey: IterateCompanions.pairingKey) != nil {
                do {
                    if let domain = try await NSFileProviderManager.domains().first(where: { $0.identifier.rawValue == "iterate-results" }) {
                        try await NSFileProviderManager.remove(domain)
                    }
                } catch let error as NSFileProviderError where error.code == .providerNotFound {
                    // The OS already retired the removed extension.
                }
            }
            defaults.set(true, forKey: finishedKey)
        } catch {
            logger.error("Task inbox cleanup will retry (\((error as NSError).code, privacy: .public))")
        }
    }

    static func removeCachedResults(in root: URL) throws {
        for name in ["AssistantCache/runs.json", "AssistantCache/glance.json", "AssistantCache/cache.lock",
                     "IterateReplies", "VisualMemoryTerms", "Library/Caches/IterateFileVersions"] {
            try removeIfPresent(root.appendingPathComponent(name))
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }

    static func retirePushRegistration() async {
        guard !retiring else { return }
        retiring = true
        defer { retiring = false }
        do {
            let savedID = try IterateAppGroup.container().appendingPathComponent("AssistantCache/installation.json")
            let data: Data
            do { data = try Data(contentsOf: savedID) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
            let id = try JSONDecoder().decode(UUID.self, from: data)
            guard let member = try CredentialStore().load()?.clientID else { return }
            _ = try await AssistantCenter.shared.request("DELETE", path: "/devices/" + id.uuidString.lowercased(), requiredSession: member)
            try removeIfPresent(savedID)
        } catch {
            logger.error("Retiring task push registration will retry (\((error as NSError).code, privacy: .public))")
        }
    }
}
