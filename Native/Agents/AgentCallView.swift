import AVFAudio
import SwiftUI

@MainActor
struct AgentCallView: View {
    let conversation: AgentConversation
    let connection: MindConnection
    let member: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var destination: VoiceDestination?
    @State private var error: String?
    @State private var denied = false
    @State private var retry = 0

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: live ? "waveform" : "phone.fill")
                .font(.system(size: 34, weight: .medium))
                .accessibilityHidden(true)
            Text(status).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .accessibilityIdentifier("iterate.chat.callStatus")
            if let detail {
                Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
                if denied || ownsCall && connection.voice.phase == .microphoneDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.buttonStyle(.bordered)
                } else if failed {
                    Button("Try again") { retry += 1 }.buttonStyle(.bordered)
                }
                Button(live ? "End call" : (failed || denied ? "Done" : "Cancel")) {
                    end()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(live ? .red : .primary)
                .accessibilityIdentifier("iterate.chat.endCall")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        .task(id: retry) { await begin() }
        .onChange(of: connection.voice.phase) { _, phase in
            if ownsCall, phase == .permission || phase == .dialing || phase == .live { conversation.voiceConnected() }
        }
        .onChange(of: connection.pairing) { _, pairing in
            if pairing != .paired(member) { dismiss() }
        }
        .onDisappear(perform: end)
    }

    private var ownsCall: Bool { destination != nil && connection.voice.destination == destination }
    private var live: Bool { ownsCall && connection.voice.phase == .live }
    private var failed: Bool { error != nil || (ownsCall && voiceFailure != nil) }
    private var voiceFailure: String? {
        if case .failed(let reason) = connection.voice.phase { return reason }
        return nil
    }
    private var status: String {
        if denied || ownsCall && connection.voice.phase == .microphoneDenied { return "Microphone access is off" }
        if failed { return "Call unavailable" }
        if live { return "Live with your agent" }
        if ownsCall, connection.voice.phase == .ending { return "Ending call…" }
        if destination != nil, !ownsCall { return "Call disconnected" }
        return "Calling agent…"
    }
    private var detail: String? { error ?? (ownsCall ? (voiceFailure ?? connection.voice.caption) : nil) }

    private func begin() async {
        error = nil
        denied = false
        guard !connection.voice.isBusy else { error = "End the current voice call first."; return }
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard !Task.isCancelled else { return }
        guard allowed else { denied = true; return }
        do {
            let session = try await connection.agentSession(for: member)
            try Task.checkCancellation()
            guard connection.pairing == .paired(member), connection.agentLink === session.link else {
                throw AssistantIssue.changedSession
            }
            guard !connection.voice.isBusy else { error = "End the current voice call first."; return }
            let target = try conversation.voiceDestination(member: member, email: session.email)
            BriefingPlayer.shared.stop()
            destination = target
            connection.voice.start(for: target)
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func end() {
        if ownsCall { connection.voice.hangUp() }
        destination = nil
    }
}
