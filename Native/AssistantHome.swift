import AppIntents
import SwiftUI

struct AssistantHome: View {
    let connection: MindConnection
    @Binding var showBriefing: Bool
    @State private var answer: IterateRun?
    @State private var question = ""
    @State private var context = ""
    @State private var requestID = UUID()
    @State private var briefingID = UUID()
    @State private var busy = false
    @State private var issue: String?
    @State private var selectingContext = false
    @FocusState private var editing: Bool

    var body: some View {
        ScrollViewReader { scroll in
            assistantList.onChange(of: answer?.id) { _, id in
                if let id { scroll.scrollTo(id, anchor: .top) }
            }
        }
        .navigationTitle("Assistant")
        .sheet(isPresented: $selectingContext) {
            IterateDeviceContextView { value in
                context = [context, value].filter { !$0.isEmpty }.joined(separator: "\n\n")
                selectingContext = false
            }
        }
        .confirmationDialog("Prepare your briefing?", isPresented: $showBriefing, titleVisibility: .visible) {
            Button("Prepare briefing") { Task { await send(briefing: true) } }
        } message: { Text(context.isEmpty ? "Iterate will review your commitments and what needs your attention." : "Include the iPhone context you selected.") }
        .onChange(of: question) { _, _ in requestID = UUID() }
        .onChange(of: context) { _, _ in requestID = UUID(); briefingID = UUID() }
    }
    private var assistantList: some View {
        List {
            Section {
                HStack {
                    Image("MindMark").resizable().renderingMode(.template).scaledToFit()
                        .frame(width: 45, height: 45).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Deployment.current.apexHost).font(.system(.title2, design: .serif).weight(.medium))
                        Text(voiceStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: tapVoice) {
                        Image(systemName: callInProgress ? "phone.down.fill" : "waveform")
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(callInProgress ? "End voice conversation" : "Talk to Iterate")
                    .disabled(connection.voice.phase == .ending)
                }
                if let caption = connection.voice.caption { Text(caption).font(.subheadline).textSelection(.enabled) }
                if case .failed(let reason) = connection.voice.phase { Text(reason).font(.caption).foregroundStyle(.red) }
                IterateScreenShareControl(voice: connection.voice)
            }

            if let reply = Binding($answer) {
                Section(reply.wrappedValue.kind == "briefing" ? "Your briefing" : "Iterate’s reply") {
                    IterateAnswerView(run: reply).id(reply.wrappedValue.id)
                    if let text = reply.wrappedValue.response, !text.isEmpty, !reply.wrappedValue.isPending {
                        ShareLink(item: text) { Label("Share reply", systemImage: "square.and.arrow.up") }
                        Button {
                            do {
                                if BriefingPlayer.shared.runID == reply.wrappedValue.id { BriefingPlayer.shared.stop() }
                                else { try BriefingPlayer.shared.read(reply.wrappedValue) }
                            } catch { issue = error.localizedDescription }
                        } label: {
                            Label(BriefingPlayer.shared.runID == reply.wrappedValue.id ? "Stop reading" : "Read aloud",
                                  systemImage: "speaker.wave.2")
                        }.disabled(callInProgress)
                    }
                }
            }
            Section("Ask Iterate") {
                TextField("What would you like me to do?", text: $question, axis: .vertical)
                    .lineLimit(2...7).focused($editing).accessibilityLabel("Question")
                if !context.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(context).font(.footnote).lineLimit(6)
                        Button("Remove context") { context = "" }.font(.caption)
                    }
                }
                Button { selectingContext = true } label: { Label("Add from iPhone", systemImage: "plus.circle") }
                Button { Task { await send(briefing: false) } } label: {
                    HStack { Label("Send", systemImage: "arrow.up.circle.fill"); if busy { Spacer(); ProgressView() } }
                }.disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(busy)

            Section {
                Button { showBriefing = true } label: { Label("Prepare a briefing", systemImage: "sunrise") }.disabled(busy)
            }
            if let issue { Section { Text(issue).font(.footnote).foregroundStyle(.red) } }
        }
    }

    private var callInProgress: Bool {
        [.live, .permission, .dialing].contains(connection.voice.phase)
    }
    private var voiceStatus: String {
        switch connection.voice.phase {
        case .ready: "Ready to talk"
        case .live: "Voice conversation in progress"
        case .dialing: "Starting conversation"
        case .permission: "Requesting microphone access"
        case .microphoneDenied: "Microphone access is off"
        case .ending: "Ending conversation"
        case .failed: "Voice unavailable"
        case .preparing: "Connecting voice"
        }
    }
    private func tapVoice() {
        if callInProgress { connection.voice.hangUp() }
        else { BriefingPlayer.shared.stop(); connection.voice.start(); _ = TalkToIterate().donate() }
    }
    @MainActor private func send(briefing: Bool) async {
        guard !busy else { return }
        busy = true; editing = false; issue = nil
        defer { busy = false }
        do {
            let run: IterateRun
            if briefing {
                run = try await AssistantCenter.shared.briefing(context: context, requestID: briefingID)
                briefingID = UUID()
            } else {
                let text = [question, context].filter { !$0.isEmpty }.joined(separator: "\n\n")
                run = try await AssistantCenter.shared.submit(text: text, requestID: requestID)
                let intent = AskIterate()
                intent.question = question
                _ = try? await intent.donate()
                question = ""
            }
            context = ""
            BriefingPlayer.shared.stop()
            answer = run
        } catch { issue = error.localizedDescription }
    }
}
