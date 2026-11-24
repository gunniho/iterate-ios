import OSLog
import UserNotifications
import CarPlay
import UIKit

final class IterateApplicationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .carTemplateApplication {
            configuration.sceneClass = CPTemplateApplicationScene.self
            configuration.delegateClass = IterateCarScene.self
        } else {
            configuration.delegateClass = IterateShortcutScene.self
        }
        return configuration
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        IterateCompanions.shared.start()
        UNUserNotificationCenter.current().delegate = self
        // Apple also starts the app in the background for an activity the mind pushed.
        AttentionLiveActivity.observe()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await WaitingPush.register(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        WaitingPush.logger.error("Apple gave no push token (\((error as NSError).code, privacy: .public))")
    }
}

extension IterateApplicationDelegate: UNUserNotificationCenterDelegate {
    // The completion-handler forms, answered on the main thread. UIKit calls these there and
    // requires its handler back there: the async forms answer from another thread and the
    // system ends the app for it when a notification is tapped.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let waiting = response.notification.request.content.categoryIdentifier == WaitingPush.category
        nonisolated(unsafe) let done = completionHandler
        DispatchQueue.main.async {
            if waiting { NativeRouteBus.shared.open(.yourMove) }
            done()
        }
    }
}

/// The alert that says something started to wait for this member, in one line of what is asked.
/// The whole request is read in Your move, over the member's session.
@MainActor
enum WaitingPush {
    nonisolated static let category = "ITERATE_WAITING"
    nonisolated static let logger = Logger(subsystem: Deployment.current.bundleID, category: "Push")
    private static let installationKey = "iterate.waitingPushInstallation"

    /// This installation's name at the mind, for every push registration it makes.
    static var installation: String {
        if let saved = UserDefaults.standard.string(forKey: installationKey) { return saved }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: installationKey)
        return made
    }

    /// Asks once whether alerts are welcome, where the member looks at what waits, and renews the
    /// registration on each later visit: Apple may change the token.
    static func enable() async {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        if status == .authorized || status == .provisional { UIApplication.shared.registerForRemoteNotifications() }
    }

    static func register(token: Data) async {
        do {
            guard let member = try CredentialStore().load()?.clientID else { return }
            try await register(["notificationToken": hex(token)], for: member)
        } catch {
            logger.error("Registering for alerts will retry (\((error as NSError).code, privacy: .public))")
        }
    }

    /// Adds `tokens` to what the mind holds for this installation. A token it is not handed stays.
    static func register(_ tokens: [String: Any], for member: String) async throws {
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let body = tokens.merging(["environment": environment, "bundleID": Deployment.current.bundleID]) { _, fixed in fixed }
        _ = try await AssistantCenter.shared.request("PUT", path: "/devices/" + installation, body: body, requiredSession: member)
    }

    nonisolated static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }
}
