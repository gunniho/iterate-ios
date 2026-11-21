import AppIntents
import SwiftUI

struct IntegrationSettings: View {
    let connection: MindConnection
    @State private var showDisconnect = false
    @State private var alarmName = "Iterate alarm"
    @State private var date = Date.now.addingTimeInterval(60 * 60)
    @State private var alarmMessage: String?

    private var actionButtonSettings: String {
        if #available(iOS 18, *) {
            return "In Settings → Action Button, choose Controls, then Iterate → New Agent. Press and hold the button to start typing."
        }
        return "In Settings → Action Button, choose Shortcut, then Iterate → New Agent."
    }

    var body: some View {
        Form {
            Section("Mind") {
                LabeledContent("Address", value: Deployment.current.controlHost)
                if connection.hasSavedSession {
                    Button("Disconnect this iPhone", role: .destructive) { showDisconnect = true }
                } else { Text("Open Agents and tap Connect to pair this iPhone.").foregroundStyle(.secondary) }
            }
            Section("Buttons and shortcuts") {
                ShortcutsLink()
                Text(actionButtonSettings)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if #available(iOS 26, *) {
                Section("Alarm") {
                    TextField("Name", text: $alarmName)
                    DatePicker("When", selection: $date, in: Date.now...)
                    Button("Set alarm") {
                        Task {
                            do { _ = try await IterateAlarms.schedule(name: alarmName, date: date); alarmMessage = "Alarm scheduled." }
                            catch { alarmMessage = error.localizedDescription }
                        }
                    }
                    if let alarmMessage { Text(alarmMessage).font(.caption) }
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Disconnect this iPhone from Iterate?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { connection.disconnect() }
        } message: { Text("This removes the drafts saved on this iPhone and disconnects it from your mind.") }
    }
}
