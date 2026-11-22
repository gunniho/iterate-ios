import SwiftUI
import WidgetKit

struct YourMoveApproval: Decodable, Identifiable {
    let id: Int
    let subject: String
    let to: [String]
    let reviewURL: String

    var trustedReviewURL: URL? {
        ApprovalReviewLink.item(reviewURL)
    }
}

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

private struct YourMoveDetails: Decodable {
    let approvals: [YourMoveApproval]
    var questions: [YourMoveQuestion]
}

struct YourMoveView: View {
    let sessionID: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var details: YourMoveDetails?
    @State private var loadingID = UUID()
    @State private var issue: String?
    @State private var notice: String?
    @State private var reviewing: YourMoveApproval?

    init(sessionID: String) {
        self.sessionID = sessionID
        _details = State(initialValue: ReviewLists.recall("your-move", for: sessionID))
    }

    var body: some View {
        List {
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            if let issue {
                Section {
                    Text(issue)
                    Button("Try again") { Task { await reload() } }
                }
            }
            if let details {
                if details.approvals.isEmpty && details.questions.isEmpty {
                    ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle",
                                           description: Text("No mail approvals or questions are waiting for you."))
                        .listRowBackground(Color.clear)
                }
                if !details.approvals.isEmpty {
                    Section("Mail to approve") {
                        ForEach(details.approvals) { approval in
                            Button { review(approval) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: approval.subject.isEmpty ? "Untitled email" : approval.subject)
                                            .foregroundStyle(.primary)
                                        if !approval.to.isEmpty {
                                            Text(verbatim: approval.to.joined(separator: ", "))
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                                }
                            }
                            .accessibilityHint("Review this email with your passkey.")
                        }
                    }
                }
                if !details.questions.isEmpty {
                    Section("Questions") {
                        ForEach(details.questions) { question in
                            YourMoveReply(question: question, sessionID: sessionID) { accepted in
                                if accepted {
                                    self.details?.questions.removeAll { $0.id == question.id && $0.updatedAt == question.updatedAt }
                                    notice = "Reply sent."
                                } else {
                                    notice = "This question changed. Check the latest questions before replying."
                                }
                                await reload()
                            }
                            .id(question.updatedAt)
                        }
                    }
                }
            } else if issue == nil {
                ProgressView("Checking what needs you…")
            }
        }
        .privacySensitive()
        .navigationTitle("Your move")
        .refreshable { await reload() }
        .task(id: scenePhase) {
            if scenePhase == .active { await reload() }
        }
        .sheet(item: $reviewing, onDismiss: {
            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
            Task { await reload() }
        }) { approval in
            if let url = approval.trustedReviewURL {
                IterateBrowser(url: url).ignoresSafeArea()
            }
        }
    }

    private func review(_ approval: YourMoveApproval) {
        do {
            guard try CredentialStore().load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
            guard approval.trustedReviewURL != nil else { throw ConnectionIssue.invalidResponse }
            notice = nil
            reviewing = approval
        } catch {
            details = nil
            issue = error.localizedDescription
        }
    }

    private func reload() async {
        let requestID = UUID()
        loadingID = requestID
        let started = Date.now
        do {
            let (data, _) = try await AssistantCenter.shared.request("GET", path: "/your-move", requiredSession: sessionID)
            let latest = try JSONDecoder().decode(YourMoveDetails.self, from: data)
            guard !Task.isCancelled, loadingID == requestID else { return }
            details = latest
            issue = nil
            ReviewLists.keep(latest, as: "your-move", for: sessionID)
            let snapshot = YourMoveSnapshot(approvalCount: latest.approvals.count,
                                            questionCount: latest.questions.count, checkedAt: started)
            YourMoveSnapshotStore.save(snapshot, for: sessionID)
            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
        } catch {
            guard !Task.isCancelled, loadingID == requestID else { return }
            let rejected = PairedSession.isAccessDenied(error)
            if rejected {
                YourMoveSnapshotStore.invalidate(for: sessionID, through: started)
                WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
            }
            let paired = (try? CredentialStore().load()?.clientID) == sessionID
            if !paired { reviewing = nil }
            // What was last read stays up through a network failure. It goes when the session does.
            if !paired || rejected {
                details = nil
                ReviewLists.keep(nil as YourMoveDetails?, as: "your-move", for: sessionID)
            }
            issue = error.localizedDescription
        }
    }
}

private struct YourMoveReply: View {
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
