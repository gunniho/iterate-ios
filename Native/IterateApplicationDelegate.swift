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
        return true
    }
}
