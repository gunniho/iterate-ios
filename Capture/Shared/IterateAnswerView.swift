import SwiftUI
import WidgetKit

/// Reads only the reply to a question opened by the person using this view.
struct IterateAnswerView: View {
    @Binding var run: IterateRun
    @Environment(\.scenePhase) private var scenePhase
    @State private var attempt = 0
    @State private var reading = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if reading && run.isPending {
                ProgressView("Waiting for Iterate…")
            } else {
                Text(run.answerText).textSelection(.enabled)
            }
            if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            if !reading && (run.isPending || !run.hasFullResponse || issue != nil) {
                Button("Check for reply") { attempt += 1 }.buttonStyle(.borderless)
            }
            if run.status == .needsInput {
                Link("Continue in browser", destination: run.url)
            }
        }
        .onChange(of: run.status) { previous, current in
            if previous == .needsInput || current == .needsInput {
                WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
            }
        }
        .task(id: scenePhase == .background ? nil : attempt) {
            guard scenePhase != .background, run.isPending || !run.hasFullResponse else { return }
            let initial = run
            reading = true
            issue = nil
            defer { if !Task.isCancelled { reading = false } }
            do {
                let latest = try await AssistantCenter.shared.awaitAnswer(for: initial, until: .now.advanced(by: .seconds(30)))
                try Task.checkCancellation()
                if run.id == latest.id { run = latest }
            } catch {
                if !Task.isCancelled, run.id == initial.id { issue = error.localizedDescription }
            }
        }
    }
}
