import SwiftUI

@main
struct IterateApp: App {
    @UIApplicationDelegateAdaptor(IterateApplicationDelegate.self) private var delegate
    @State private var connection = MindConnection.shared

    init() {
        #if DEBUG
        AgentLaunchTiming.begin()
        #endif
        MindConnection.shared.prepareForLaunch()
    }

    var body: some Scene {
        WindowGroup {
            IterateWindow(connection: connection)
        }
        .handlesExternalEvents(matching: ["*"])
    }
}

#if DEBUG
/// Opt-in device timing from SwiftUI app initialization to the first agent row entering the view.
@MainActor
enum AgentLaunchTiming {
    private static var start: ContinuousClock.Instant?

    static func begin() {
        if ProcessInfo.processInfo.environment["ITERATE_MEASURE_LAUNCH"] == "1" { start = .now }
    }

    static func mark(_ milestone: String, finish: Bool = false) {
        guard let start else { return }
        let elapsed = start.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        print("Iterate launch \(milestone) \(milliseconds) ms")
        if finish { self.start = nil }
    }
}
#endif
