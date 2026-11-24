import AVFAudio
import SwiftUI

@MainActor
struct AgentCallView: View {
    let conversation: AgentConversation
    let connection: MindConnection
    let member: String
    /// Opens Apple's screen picker as soon as the call is live.
    var sharesScreen = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var destination: VoiceDestination?
    @State private var error: String?
    @State private var denied = false
    @State private var retry = 0
    @State private var offeredScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 34

    var body: some View {
        // Screen sharing adds its controls and Iterate's answer, which can outgrow the half-height sheet.
        GeometryReader { area in
            ScrollView {
                content
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: area.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        .task(id: retry) { await begin() }
        .onChange(of: connection.voice.phase) { _, phase in
            if ownsCall, phase == .permission || phase == .dialing || phase == .live { conversation.voiceConnected() }
        }
        .onChange(of: live) { _, live in
            guard live, sharesScreen, !offeredScreen else { return }
            offeredScreen = true
            IterateScreenShare.shared.start(voice: connection.voice)
        }
        .onChange(of: connection.pairing) { _, pairing in
            if pairing != .paired(member) { dismiss() }
        }
        .onDisappear(perform: end)
    }

    private var content: some View {
        VStack(spacing: 20) {
            // The handset becomes a waveform that keeps moving for as long as the line is open.
            Image(systemName: live ? "waveform" : "phone.fill")
                .font(.system(size: symbolSize, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: live && !reduceMotion)
                .accessibilityHidden(true)
            Text(status).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(IterateMotion.standard, value: status)
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
            // Sharing belongs to a live call, and ends with it.
            if live, IterateScreenShare.shared.available {
                IterateScreenShareControl(voice: connection.voice)
                    .buttonStyle(.bordered)
            }
        }
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
