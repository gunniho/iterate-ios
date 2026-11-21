import AppIntents
import UIKit

enum NewAgentTarget: String, AppEnum {
    case newAgent
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent destination"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.newAgent: "New Agent"]
}

struct StartNewIterateAgent: OpenIntent {
    static let title: LocalizedStringResource = "New Agent"
    static let description = IntentDescription("Start typing to a new Iterate agent.")
    static let sceneIdentifier = Deployment.current.bundleID + ".new-agent"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let openAppWhenRun = true
    @available(iOS 26, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Destination", default: .newAgent) var target: NewAgentTarget

    init() { target = .newAgent }

    @MainActor func perform() async throws -> some IntentResult {
        if #unavailable(iOS 26) { NativeRouteBus.shared.open(.newAgent) }
        return .result()
    }
}

@available(iOS 26, *)
extension StartNewIterateAgent: UISceneAppIntent {
    var contentIdentifier: String { Self.sceneIdentifier }
}
#if ITERATE_SIRI_PREVIEW
@AppIntent(.tool)
#endif
struct TalkToIterate: AppIntent {
    static let title: LocalizedStringResource = "Talk to Iterate"
    static let description = IntentDescription("Start a live voice conversation with your paired Iterate mind.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult {
        NativeRouteBus.shared.open(.talk)
        return .result()
    }
}

#if ITERATE_SIRI_PREVIEW
@AppIntent(.tool)
#endif
struct CaptureWithIterate: AppIntent {
    static let title: LocalizedStringResource = "Capture with Iterate"
    static let description = IntentDescription("Open Iterate’s capture inbox to review a photo, file, or note.")
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @MainActor func perform() async throws -> some IntentResult {
        NativeRouteBus.shared.open(.capture)
        return .result()
    }
}

enum IterateControlDestination: String, AppEnum {
    case talk, capture
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Iterate action"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.talk: "Talk to Iterate", .capture: "Capture"]
}

@available(iOS 18, *)
struct OpenIterateControl: OpenIntent {
    static let title: LocalizedStringResource = "Open Iterate Action"
    static let openAppWhenRun = true
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Action") var target: IterateControlDestination
    init() {}
    init(_ target: IterateControlDestination) { self.target = target }

    @MainActor func perform() async throws -> some IntentResult {
        NativeRouteBus.shared.open(target == .talk ? .talk : .capture)
        return .result()
    }
}
