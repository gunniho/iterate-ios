import AppIntents
import Foundation

@MainActor
enum IterateCameraLaunch {
    private static var handler: (() -> Void)?
    private static var pending = false

    static func bind(_ action: @escaping () -> Void) {
        handler = action
        if pending {
            pending = false
            action()
        }
    }

    static func open() {
        if let handler { handler() } else { pending = true }
    }
}

@available(iOS 18.0, *)
struct IterateCameraIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "Open Iterate Camera"
    static let description = IntentDescription("Open the camera to capture a photo for Iterate.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IterateCameraLaunch.open()
        return .result()
    }
}
