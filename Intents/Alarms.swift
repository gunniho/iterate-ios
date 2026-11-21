import AlarmKit
import AppIntents
import SwiftUI

@available(iOS 26, *)
struct IterateAlarmMetadata: AlarmMetadata { var name: String }

@available(iOS 26, *)
enum IterateAlarms {
    static func schedule(name: String, date: Date? = nil, duration: TimeInterval? = nil) async throws -> UUID {
        let manager = AlarmManager.shared
        guard try await manager.requestAuthorization() == .authorized else {
            throw AssistantIssue.invalidInput("Allow alarms for Iterate in Settings to schedule this alert.")
        }
        let snooze = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = .init(title: "\(name)", secondaryButton: snooze, secondaryButtonBehavior: .countdown)
        } else {
            alert = .init(title: "\(name)", stopButton: .init(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
                          secondaryButton: snooze, secondaryButtonBehavior: .countdown)
        }
        let resume = AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill")
        let presentation = AlarmPresentation(alert: alert, countdown: .init(title: "\(name)"),
                                             paused: .init(title: "\(name)", resumeButton: resume))
        let attributes = AlarmAttributes(presentation: presentation, metadata: IterateAlarmMetadata(name: name), tintColor: .mint)
        let configuration: AlarmManager.AlarmConfiguration<IterateAlarmMetadata>
        if let date {
            guard date > .now else { throw AssistantIssue.invalidInput("Choose a future alarm time.") }
            configuration = .init(countdownDuration: .init(preAlert: nil, postAlert: 9 * 60),
                                  schedule: .fixed(date), attributes: attributes)
        } else if let duration, duration > 0, duration.isFinite {
            configuration = .init(countdownDuration: .init(preAlert: duration, postAlert: 9 * 60), attributes: attributes)
        } else { throw AssistantIssue.invalidInput("Choose a positive timer duration.") }
        let id = UUID()
        _ = try await manager.schedule(id: id, configuration: configuration)
        return id
    }
}

@available(iOS 26, *)
struct SetIterateAlarm: AppIntent {
    static let title: LocalizedStringResource = "Set Iterate Alarm"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @Parameter(title: "Name", default: "Iterate alarm") var name: String
    @Parameter(title: "Date and time") var date: Date
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IterateAlarms.schedule(name: name, date: date)
        return .result(dialog: "Your alarm is set.")
    }
}

@available(iOS 26, *)
struct StartIterateTimer: AppIntent {
    static let title: LocalizedStringResource = "Start Iterate Timer"
    @Parameter(title: "Name", default: "Iterate timer") var name: String
    @Parameter(title: "Minutes") var minutes: Double
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IterateAlarms.schedule(name: name, duration: minutes * 60)
        return .result(dialog: "Your timer has started.")
    }
}
