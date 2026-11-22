import SwiftUI
import WidgetKit

struct YourMoveQuestion: Decodable, Identifiable {
    let id: UUID
    let title: String
    let question: String
    let updatedAt: String
    let responseLength: Int

    var completePreview: String? {
        question.utf16.count == responseLength ? question : nil
    }

    func completeText(from run: IterateRun) throws -> String {
        let dated = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let revision = (try? dated.parse(updatedAt)) ?? (try? Date.ISO8601FormatStyle().parse(updatedAt))
        guard let revision, run.id == id else { throw ConnectionIssue.invalidResponse }
        guard run.status == .needsInput, run.updatedAt == revision else {
            throw AssistantIssue.conflict("This question has changed.")
        }
        guard let text = run.response, run.hasFullResponse,
              responseLength == text.utf16.count else { throw ConnectionIssue.invalidResponse }
        return text
    }
}

/// The questions of `/your-move`. What else waits is read from `/approvals`.
struct YourMoveQuestions: Decodable {
    let questions: [YourMoveQuestion]

    @MainActor static func load(sessionID: String) async throws -> [YourMoveQuestion] {
        let (data, _) = try await AssistantCenter.shared.request("GET", path: "/your-move", requiredSession: sessionID)
        return try JSONDecoder().decode(YourMoveQuestions.self, from: data).questions
    }
}

struct YourMoveReply: View {
    let question: YourMoveQuestion
    let sessionID: String
    let resolved: (Bool) async -> Void
    @State private var text = ""
    @State private var requestID = UUID()
    @State private var sending = false
    @State private var issue: String?
    @State private var expanded = false
    @State private var fullQuestion: String?
    @State private var readIssue: String?
    @State private var readAttempt = 0

    private var questionText: String? { fullQuestion ?? question.completePreview }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let questionText {
                    Text(verbatim: questionText).textSelection(.enabled)
                    replyEditor
                } else if let readIssue {
                    Text(readIssue).font(.footnote).foregroundStyle(.secondary)
                    Button("Try again") { readAttempt += 1 }
                } else {
                    ProgressView("Loading question…")
                }
            }
            .padding(.vertical, 6)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: question.title.isEmpty ? "Follow-up question" : question.title)
                    .foregroundStyle(.primary)
                if !expanded, question.question != question.title {
                    Text(verbatim: question.question).font(.subheadline)
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .task(id: expanded ? readAttempt : nil) {
            guard expanded, questionText == nil else { return }
            readIssue = nil
            do {
                let run = try await AssistantCenter.shared.refresh(id: question.id, requiredSession: sessionID)
                try Task.checkCancellation()
                fullQuestion = try question.completeText(from: run)
            } catch {
                guard !Task.isCancelled else { return }
                readIssue = error.localizedDescription
                if case AssistantIssue.conflict = error { await resolved(false) }
            }
        }
    }

    @ViewBuilder private var replyEditor: some View {
        TextField("Your reply", text: $text, axis: .vertical)
            .textFieldStyle(.roundedBorder).lineLimit(1...6)
            .disabled(sending)
            .onChange(of: text) { _, _ in
                requestID = UUID()
                issue = nil
            }
        if let issue { Text(issue).font(.footnote).foregroundStyle(.secondary) }
        Button { Task { await send() } } label: {
            if sending { ProgressView().accessibilityLabel("Sending reply") }
            else { Label("Send reply", systemImage: "arrow.up.circle") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func send() async {
        guard !sending, questionText != nil else { return }
        sending = true
        issue = nil
        defer { sending = false }
        do {
            _ = try await AssistantCenter.shared.reply(to: question.id, text: text, requestID: requestID,
                                                       expectedUpdatedAt: question.updatedAt, requiredSession: sessionID)
            await resolved(true)
        } catch AssistantIssue.conflict(_) {
            await resolved(false)
        } catch {
            issue = error.localizedDescription
        }
    }
}
