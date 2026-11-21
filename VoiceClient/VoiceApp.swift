import SwiftUI

@main
struct VoiceApp: App {
    @State private var connection = MindConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ConnectionScreen(phase: connection.phase, hasSavedSession: connection.hasSavedSession,
                             connect: connection.connect, cancel: connection.cancelApproval,
                             disconnect: connection.disconnect, voice: connection.voice)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: connection.activate()
                    case .background: connection.background()
                    default: break
                    }
                }
        }
    }
}
