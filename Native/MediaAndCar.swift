import AppIntents
import CarPlay
import Combine
import UIKit

@MainActor
final class IterateCarScene: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CPInterfaceController?
    private var voiceTemplate: CPVoiceControlTemplate?
    private var updates: Task<Void, Never>?
    private var ownsCall = false
    private let mind = MindConnection.shared

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        controller = interfaceController
        mind.activate()
        let item = CPListItem(text: "Talk to Iterate", detailText: nil)
        item.handler = { [weak self] _, done in self?.showVoice(); done() }
        let root = CPListTemplate(title: "Iterate", sections: [.init(items: [item])])
        interfaceController.setRootTemplate(root, animated: false) { [weak self] success, _ in
            if success { self?.showVoice() }
        }
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        finish()
        controller = nil
    }

    func sceneWillResignActive(_ scene: UIScene) { finish() }

    private func showVoice() {
        guard let controller, voiceTemplate == nil else { return }
        let labels = [("connecting", "Connecting"), ("ready", "Ready"), ("live", "Listening"),
                      ("phone", "Open Iterate on iPhone"), ("ended", "Conversation ended")]
        let states = labels.map { CPVoiceControlState(identifier: $0.0, titleVariants: [$0.1], image: nil, repeats: false) }
        let template = CPVoiceControlTemplate(voiceControlStates: states)
        if #available(iOS 26.4, *) {
            template.trailingNavigationBarButtons = [CPBarButton(title: "End") { [weak self] _ in self?.finish() }]
        }
        voiceTemplate = template
        controller.presentTemplate(template, animated: true) { [weak self] success, _ in
            guard let self, success else { self?.voiceTemplate = nil; return }
            updates = Task {
                var requested = false
                while !Task.isCancelled, voiceTemplate === template {
                    switch mind.phase {
                    case .connected:
                        if !requested, mind.voice.phase == .ready {
                            requested = true
                            ownsCall = true
                            mind.voice.start()
                        }
                        let state: String
                        switch mind.voice.phase {
                        case .live: state = "live"
                        case .ready: state = requested ? "ended" : "ready"
                        case .microphoneDenied, .failed: state = "phone"
                        default: state = "connecting"
                        }
                        template.activateVoiceControlState(withIdentifier: state)
                    case .disconnected, .failed, .approval: template.activateVoiceControlState(withIdentifier: "phone")
                    default: template.activateVoiceControlState(withIdentifier: "connecting")
                    }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                }
            }
        }
    }
    private func finish() {
        updates?.cancel()
        updates = nil
        if ownsCall { mind.voice.hangUp(); ownsCall = false }
        if voiceTemplate != nil { controller?.dismissTemplate(animated: false, completion: nil) }
        voiceTemplate = nil
        if UIApplication.shared.applicationState == .background { mind.background() }
    }
}

@MainActor
final class IterateShortcutScene: UIResponder, UIWindowSceneDelegate, ObservableObject {
    @Published private(set) var requestedAgents: [AgentConversation] = []
    private weak var connectingDraft: AgentConversation?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if #available(iOS 26, *), options.appIntent is StartNewIterateAgent {
            openConnectingDraft()
        }
        if let shortcut = options.shortcutItem { _ = route(shortcut) }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        connectingDraft = nil
    }

    func openConnectingDraft() {
        let draft = AgentConversation()
        connectingDraft = draft
        requestedAgents.append(draft)
    }

    func openRequestedAgent() {
        // A cold launch can deliver the connecting intent a second time before activation.
        if let draft = connectingDraft {
            connectingDraft = nil
            if draft.isLocalDraft, !draft.receivedInput { return }
        }
        requestedAgents.append(AgentConversation())
    }

    func consume(_ requests: [AgentConversation]) {
        guard !requests.isEmpty else { return }
        requestedAgents.removeAll(where: requests.contains)
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(route(shortcutItem))
    }
    private func route(_ item: UIApplicationShortcutItem) -> Bool {
        let destination: NativeDestination
        switch item.type {
        case "talk": destination = .talk
        case "capture": destination = .capture
        default: return false
        }
        NativeRouteBus.shared.open(destination)
        return true
    }
}

@available(iOS 26, *)
extension IterateShortcutScene: AppIntentSceneDelegate {
    nonisolated func scene(_ scene: UIScene, willPerformAppIntent intent: any UISceneAppIntent) {
        guard intent is StartNewIterateAgent else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { openRequestedAgent() }
        } else {
            DispatchQueue.main.async { self.openRequestedAgent() }
        }
    }
}
