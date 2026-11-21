import AppIntents
import SwiftUI

@main
struct IterateWatch: App {
    var body: some Scene {
        WindowGroup { WristAssistant() }
    }
}

private struct WristAssistant: View {
    @State private var relay = WatchRelay.shared
    @State private var question = ""
    @State private var sentQuestion = ""
    @State private var requestID = UUID()
    @State private var runID: UUID?
    @State private var awaitingReply = false
    @State private var reply: String?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if relay.overview?.paired == false {
                    Text("Pair Iterate on your iPhone to get started.").font(.footnote)
                } else if !relay.reachable {
                    Text("Open Iterate on your paired iPhone to connect.").font(.footnote)
                }
                if let reply { Text(reply) }
                TextField(awaitingReply ? "Your reply" : "Ask a question", text: $question)
                    .accessibilityLabel(awaitingReply ? "Reply to Iterate" : "Question for Iterate")
                Button(awaitingReply ? "Send reply" : "Ask Iterate", systemImage: "paperplane") { ask() }
                    .disabled(busy || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if let runID {
                    Button("Check reply", systemImage: "arrow.clockwise") {
                        perform(.init(command: .refresh, runID: runID))
                    }.disabled(busy)
                }
                if awaitingReply {
                    Button("New question") {
                        awaitingReply = false; runID = nil; reply = nil; question = ""; sentQuestion = ""
                    }.disabled(busy)
                }
            }
            .navigationTitle("Iterate")
            .task { relay.start() }
            .onChange(of: relay.overview?.paired) { _, paired in
                if paired == false {
                    reply = nil; runID = nil; sentQuestion = ""; question = ""; requestID = UUID()
                    awaitingReply = false
                }
            }
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = (awaitingReply ? runID?.uuidString ?? "" : "") + "\n" + text
        if sentQuestion != key {
            requestID = UUID()
            sentQuestion = key
        }
        perform(.init(command: awaitingReply ? .reply : .ask, text: text, runID: runID, requestID: requestID))
    }

    private func perform(_ request: IterateWatchRequest) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await relay.request(request)
                let complete = ["completed", "failed", "cancelled"].contains(result.status ?? "")
                awaitingReply = result.status == "needsInput"
                runID = complete ? nil : result.runID
                if let answer = result.answer, !answer.isEmpty { reply = answer }
                else {
                    switch result.status {
                    case "completed": reply = "Iterate finished without a written reply."
                    case "failed", "cancelled": reply = "Iterate couldn’t finish this request."
                    case "needsInput": reply = "Iterate has a follow-up question."
                    default: reply = "Iterate is working on your reply."
                    }
                }
                if request.command == .ask || request.command == .reply { question = ""; sentQuestion = ""; requestID = UUID() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct OpenIterateWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Iterate"
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult { .result() }
}

struct AskIterateWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Iterate from Watch"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Question") var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else { throw WatchRelayError(message: "Enter a question of 2,000 characters or fewer.") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var result = try await WatchRelay.shared.request(.init(command: .ask, text: text, requestID: UUID()))
        while ["queued", "running"].contains(result.status), let id = result.runID,
              ContinuousClock.now.advanced(by: .seconds(2)) < deadline {
            try await Task.sleep(for: .seconds(2))
            result = try await WatchRelay.shared.request(.init(command: .refresh, runID: id))
        }
        let answer: String
        if let response = result.answer, !response.isEmpty { answer = response }
        else if ["queued", "running", "needsInput"].contains(result.status), let id = result.runID {
            answer = "Continue in your browser at \(Deployment.current.runURL(id).absoluteString)"
        } else { answer = "Iterate finished without a written reply." }
        return .result(value: answer, dialog: "\(answer)")
    }
}

struct IterateWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskIterateWatchIntent(), phrases: ["Ask \(.applicationName) from my watch"],
                    shortTitle: "Ask Iterate", systemImageName: "waveform")
        AppShortcut(intent: OpenIterateWatchIntent(), phrases: ["Open \(.applicationName) on my watch"],
                    shortTitle: "Open Iterate", systemImageName: "bubble.left")
    }
}
