import LocalAuthentication
import SwiftUI
import WidgetKit

enum ApprovalReviewLink {
    static let inbox = Deployment.current.issuer.appendingPathComponent("secrets/approvals")
    /// The platform's own page for a member's passkeys. It leads back to the inbox when done.
    static let keys = Deployment.current.issuer.appendingPathComponent("keys")
        .appending(queryItems: [URLQueryItem(name: "next", value: "/secrets/approvals")])

    /// What this iPhone confirms a passkey with, in Apple's own name for it.
    @MainActor static var deviceUnlock: (name: String, symbol: String) {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return ("Face ID", "faceid")
        case .touchID: return ("Touch ID", "touchid")
        default: return ("this iPhone", "person.badge.key")
        }
    }

    /// The platform's page where one person signs one statement.
    static let statement = Deployment.current.issuer.appendingPathComponent("statements/sign")

    /// The review page of a held act, or the signing page of a statement. Nothing else opens.
    static func item(_ value: String) -> URL? {
        let signing = statement.absoluteString + "?draft="
        if value.hasPrefix(signing) {
            let draft = value.dropFirst(signing.count)
            let allowed = { (byte: UInt8) in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 95
            }
            guard (8...128).contains(draft.utf8.count), draft.utf8.allSatisfy(allowed) else { return nil }
            return statement.appending(queryItems: [URLQueryItem(name: "draft", value: String(draft))])
        }
        let prefix = inbox.absoluteString + "?digest="
        guard value.hasPrefix(prefix) else { return nil }
        let digest = value.dropFirst(prefix.count)
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return inbox.appending(queryItems: [URLQueryItem(name: "digest", value: String(digest))])
    }
}

/// What a member last read on a review screen. The screen opens on it while it refreshes,
/// and it is dropped with the pairing.
@MainActor
enum ReviewLists {
    private static var seen: [String: (session: String, value: Any)] = [:]

    static func recall<Value>(_ list: String, for session: String) -> Value? {
        seen[list].flatMap { $0.session == session ? $0.value as? Value : nil }
    }

    static func keep<Value>(_ value: Value?, as list: String, for session: String) {
        seen[list] = value.map { (session, $0) }
    }

    static func forget() { seen = [:] }
}

struct PendingApproval: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable {
        case email, action, signature

        var symbol: String {
            switch self {
            case .email: "envelope.fill"
            case .action: "bolt.fill"
            case .signature: "signature"
            }
        }

        var tint: Color {
            switch self {
            case .email: .blue
            case .action: .orange
            case .signature: .teal
            }
        }

        var name: String {
            switch self {
            case .email: "Email"
            case .action: "Agent action"
            case .signature: "Signature request"
            }
        }
    }

    let id: Int
    let kind: Kind
    let title: String
    let recipients: [String]
    let heldAt: Date
    let reviewURL: String
    /// The exact text that waits, where the platform gives it. Never shown before `HeldAct` checks it.
    var text: String?
}

struct DecidedApproval: Decodable, Equatable {
    enum Outcome: String, Decodable { case approved, rejected }

    let id: Int
    let outcome: Outcome
}

struct ApprovalInbox: Decodable {
    let items: [PendingApproval]
    let decided: [DecidedApproval]

    private enum CodingKeys: CodingKey { case items, decided }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decode([PendingApproval].self, forKey: .items)
        decided = try values.decodeIfPresent([DecidedApproval].self, forKey: .decided) ?? []
    }

    @MainActor static func load(sessionID: String) async throws -> ApprovalInbox {
        let (data, _) = try await AssistantCenter.shared.request("GET", path: "/approvals?signatures=1", requiredSession: sessionID)
        return try AssistantCenter.decoder().decode(ApprovalInbox.self, from: data)
    }

    /// How the reviewed act ended, or nil while it still waits.
    func resolution(of review: ApprovalReview) -> ApprovalResolution? {
        guard let id = review.approval, !items.contains(where: { $0.id == id }) else { return nil }
        return ApprovalResolution(kind: review.kind, outcome: decided.first { $0.id == id }?.outcome)
    }
}

/// A todo that cannot wait, as Your move lists it: its words and its project.
struct UrgentTodoRow: View {
    let todo: AttentionSummary.UrgentTodo
    let linked: Bool
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AttentionKind.urgent.symbol)
                .font(.system(size: tile * 0.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(.red, in: .rect(cornerRadius: tile * 0.24, style: .continuous))
                .accessibilityLabel("Urgent todo")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: todo.text).foregroundStyle(.primary).lineLimit(3)
                if !todo.project.isEmpty {
                    Text(verbatim: todo.project).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if linked {
                Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A platform review page, and the held act it was opened for. The whole inbox names no act.
struct ApprovalReview: Identifiable, Equatable {
    let url: URL
    var approval: Int?
    var kind = PendingApproval.Kind.email
    var id: URL { url }
}

struct ApprovalResolution: Equatable {
    let kind: PendingApproval.Kind
    /// nil when the act stopped waiting some other way, such as its day running out.
    let outcome: DecidedApproval.Outcome?

    var title: String {
        switch outcome {
        case .approved: "Approved"
        case .rejected: "Rejected"
        case nil: "No longer waiting"
        }
    }

    var detail: String {
        switch (outcome, kind) {
        case (.approved, .email): "The email is on its way."
        case (.approved, .action): "The action is going ahead."
        case (.rejected, .email): "The email won’t be sent."
        case (.rejected, .action): "The action won’t run."
        case (.approved, .signature): "Your signature is recorded."
        case (.rejected, .signature): "The request was declined."
        case (nil, _): "This request was already settled."
        }
    }

    var symbol: String {
        switch outcome {
        case .approved: "checkmark.circle.fill"
        case .rejected: "xmark.circle.fill"
        case nil: "clock.badge.checkmark"
        }
    }

    @MainActor static func announce(_ result: ApprovalResolution) {
        UINotificationFeedbackGenerator().notificationOccurred(result.outcome == .approved ? .success : .warning)
        AccessibilityNotification.Announcement(result.title + ". " + result.detail).post()
    }
}

struct ApprovalRow: View {
    let kind: PendingApproval.Kind
    let title: String
    let recipients: [String]
    var heldAt: Date?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 30

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: tile * 0.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(kind.tint, in: .rect(cornerRadius: tile * 0.24, style: .continuous))
                .accessibilityLabel(kind.name)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: title).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 0)
                    if !typeSize.isAccessibilitySize { held.fixedSize() }
                }
                if !recipients.isEmpty {
                    Text(verbatim: "To " + recipients.joined(separator: ", "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                if typeSize.isAccessibilitySize { held }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var held: some View {
        if let heldAt {
            Text(heldAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel(Text("Submitted \(heldAt.formatted())"))
        }
    }
}

struct ApprovalsView: View {
    let sessionID: String
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var items: [PendingApproval]?
    @State private var questions: [YourMoveQuestion] = []
    @State private var urgent: [AttentionSummary.UrgentTodo] = []
    @State private var todoList: URL?
    @State private var notice: String?
    @State private var issue: String?
    @State private var review: ApprovalReview?
    @State private var deciding: Deciding?
    @State private var signing: Signing?
    @State private var outcome: ApprovalResolution?
    @State private var outcomeShown = UUID()
    @State private var requestID = UUID()
    @State private var repliesSent = 0

    init(sessionID: String) {
        self.sessionID = sessionID
        _items = State(initialValue: ReviewLists.recall("approvals", for: sessionID))
        _questions = State(initialValue: ReviewLists.recall("questions", for: sessionID) ?? [])
    }

    var body: some View {
        List {
            if let notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            if let issue {
                Section {
                    Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Button("Try again") { Task { await reload() } }
                }
            }
            if !urgent.isEmpty {
                Section("Urgent") {
                    ForEach(urgent) { todo in
                        if let todoList {
                            Link(destination: todoList) { UrgentTodoRow(todo: todo, linked: true) }
                                .accessibilityHint("Opens the todo list.")
                        } else {
                            UrgentTodoRow(todo: todo, linked: false)
                        }
                    }
                }
            }
            if let items {
                if !items.isEmpty {
                    Section("To approve") {
                        ForEach(items) { item in
                            Button { open(item) } label: {
                                ApprovalRow(kind: item.kind, title: item.title, recipients: item.recipients, heldAt: item.heldAt)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(item.kind == .signature ? "Read the request and sign it with your passkey."
                                               : "Review the exact request and approve or reject it with your passkey.")
                        }
                    }
                } else if issue == nil, questions.isEmpty, urgent.isEmpty {
                    ContentUnavailableView("You’re all caught up", systemImage: "checkmark.circle",
                                           description: Text("No approvals, signature requests, questions or urgent todos are waiting for you."))
                        .listRowBackground(Color.clear)
                }
                if !questions.isEmpty {
                    Section("Questions") {
                        ForEach(questions) { question in
                            YourMoveReply(question: question, sessionID: sessionID) { accepted in
                                await answered(question, accepted: accepted)
                            }
                            .id(question.updatedAt)
                        }
                    }
                }
            } else if issue == nil {
                Section("To approve") {
                    ForEach(0..<2, id: \.self) { _ in
                        ApprovalRow(kind: .email, title: "Outgoing email", recipients: ["reader@example.org"], heldAt: .now)
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Checking approvals")
            }
            Section {
                Button { open(nil) } label: {
                    Label("All approval requests", systemImage: "signature")
                }
            } footer: {
                Text("Includes proposed rules and requests that use a secret.")
            }
            Section {
                Button { open(nil, page: ApprovalReviewLink.keys) } label: {
                    Label(unlock.name == "this iPhone" ? "Add a passkey on this iPhone" : "Approve with \(unlock.name)",
                          systemImage: unlock.symbol)
                }
            } footer: {
                Text("Add a passkey on this iPhone once, and each review asks for \(unlock.name == "this iPhone" ? "it" : unlock.name) here. Adding it asks for a passkey you already have.")
            }
        }
        // Rows that come and go by themselves settle without a bounce.
        .animation(reduceMotion ? nil : IterateMotion.standard, value: items?.map(\.id))
        .animation(reduceMotion ? nil : IterateMotion.standard, value: questions.map(\.id))
        .animation(reduceMotion ? nil : IterateMotion.standard, value: urgent)
        .animation(reduceMotion ? nil : IterateMotion.standard, value: issue)
        .sensoryFeedback(.success, trigger: repliesSent)
        .privacySensitive()
        .navigationTitle("Your move")
        .refreshable { await reload() }
        .safeAreaInset(edge: .bottom) {
            if let outcome {
                ApprovalOutcomeNote(outcome: outcome)
                    .transition(.floatingNote(reduceMotion: reduceMotion))
                    .task(id: outcomeShown) {
                        do { try await Task.sleep(for: .seconds(4)) } catch { return }
                        self.outcome = nil
                    }
            }
        }
        .animation(IterateMotion.standard, value: outcome)
        .task(id: scenePhase) {
            // A decision made on another device should leave this list without a pull.
            var quiet = false
            while scenePhase == .active, !Task.isCancelled {
                await reload(quiet: quiet)
                quiet = true
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task { await WaitingPush.enable() }
        .approvalReview($review, sessionID: sessionID) { result in
            if let result {
                outcome = result
                outcomeShown = UUID()
            }
            Task { await reload() }
        }
        .sheet(item: $signing) { signing in
            StatementSignSheet(draft: signing.draft, title: signing.item.title, approvalID: signing.item.id,
                               signPage: signing.page, sessionID: sessionID) { result in
                ApprovalResolution.announce(result)
                WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
                outcome = result
                outcomeShown = UUID()
                Task { await reload() }
            }
        }
        .sheet(item: $deciding) { deciding in
            ApprovalDecisionSheet(act: deciding.act, title: deciding.item.title, kind: deciding.item.kind,
                                  approvalID: deciding.item.id, reviewPage: deciding.page, sessionID: sessionID) { result in
                ApprovalResolution.announce(result)
                WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
                outcome = result
                outcomeShown = UUID()
                Task { await reload() }
            }
        }
    }

    private var unlock: (name: String, symbol: String) { ApprovalReviewLink.deviceUnlock }

    private func answered(_ question: YourMoveQuestion, accepted: Bool) async {
        if accepted {
            questions.removeAll { $0.id == question.id && $0.updatedAt == question.updatedAt }
            notice = "Reply sent."
            repliesSent += 1
        } else {
            notice = "This question changed. Check the latest questions before replying."
        }
        await reload()
    }

    /// A statement this iPhone asks the passkey for itself.
    private struct Signing: Identifiable {
        let item: PendingApproval
        let draft: StatementDraft
        let page: URL
        var id: Int { item.id }
    }

    /// A request this iPhone can decide by itself: its text is here and was checked.
    private struct Deciding: Identifiable {
        let item: PendingApproval
        let act: HeldAct
        let page: URL
        var id: Int { item.id }
    }

    private func open(_ item: PendingApproval?, page: URL = ApprovalReviewLink.inbox) {
        do {
            guard try CredentialStore().load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
            guard let item else { return review = ApprovalReview(url: page) }
            guard let url = ApprovalReviewLink.item(item.reviewURL) else { throw ConnectionIssue.invalidResponse }
            outcome = nil
            notice = nil
            if DeviceApprovalKey.isAvailable, let text = item.text, let act = HeldAct(text: text, reviewURL: item.reviewURL) {
                deciding = Deciding(item: item, act: act, page: url)
            } else if item.kind == .signature {
                // The statement as the platform holds it, for a native sheet. A platform that
                // answers a page alone, or no answer at all, leaves the page to sign.
                Task {
                    if let draft = try? await StatementDraft.load(page: url) {
                        signing = Signing(item: item, draft: draft, page: url)
                    } else {
                        review = ApprovalReview(url: url, approval: item.id, kind: item.kind)
                    }
                }
            } else {
                review = ApprovalReview(url: url, approval: item.id, kind: item.kind)
            }
        } catch {
            requestID = UUID()
            items = nil
            review = nil
            deciding = nil
            signing = nil
            issue = error.localizedDescription
        }
    }

    private func reload(quiet: Bool = false) async {
        let id = UUID()
        requestID = id
        let started = Date.now
        do {
            async let inbox = ApprovalInbox.load(sessionID: sessionID)
            async let asked = YourMoveQuestions.load(sessionID: sessionID)
            // A mind from before the attention activity answers none: the lists above are whole without it.
            async let needed = try? AttentionSummary.load(sessionID: sessionID)
            let (latest, open, attention) = try await (inbox, asked, needed)
            guard !Task.isCancelled, requestID == id else { return }
            items = latest.items
            questions = open
            urgent = attention?.urgentTodos ?? []
            todoList = attention?.todoList
            issue = nil
            // The Lock Screen counts what this screen lists, the moment a decision here changes it.
            if let attention { await AttentionLiveActivity.show(attention) }
            ReviewLists.keep(latest.items, as: "approvals", for: sessionID)
            ReviewLists.keep(open, as: "questions", for: sessionID)
            // The widget counts what this screen lists.
            YourMoveSnapshotStore.save(YourMoveSnapshot(approvalCount: latest.items.count, questionCount: open.count, checkedAt: started),
                                       for: sessionID)
            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            let paired = (try? CredentialStore().load()?.clientID) == sessionID
            if !paired { review = nil }
            // What was last read stays up through a network failure. It goes when the session does.
            if !paired || PairedSession.isAccessDenied(error) {
                items = nil
                questions = []
                urgent = []
                ReviewLists.keep(nil as [PendingApproval]?, as: "approvals", for: sessionID)
                ReviewLists.keep(nil as [YourMoveQuestion]?, as: "questions", for: sessionID)
            } else if quiet, items != nil { return }
            issue = error.localizedDescription
        }
    }
}

struct ApprovalOutcomeNote: View {
    let outcome: ApprovalResolution

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: outcome.symbol).font(.title3)
                .foregroundStyle(outcome.outcome == .approved ? Color.green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.title).font(.subheadline.weight(.semibold))
                Text(outcome.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .modifier(FloatingNoteSurface())
        .padding(.horizontal, 16).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Shows the platform's review page, and closes it when the act it was opened for is decided.
/// The passkey press stays on that page: this only watches for the result.
private struct ApprovalReviewSheet: ViewModifier {
    @Binding var review: ApprovalReview?
    let sessionID: String
    let finished: (ApprovalResolution?) -> Void
    @State private var shown: ApprovalReview?
    @State private var resolution: ApprovalResolution?

    func body(content: Content) -> some View {
        content.sheet(item: $review, onDismiss: close) { page in
            IterateBrowser(url: page.url).ignoresSafeArea()
                .task(id: page) {
                    shown = page
                    resolution = nil
                    guard let found = await decision(for: page) else { return }
                    resolution = found
                    review = nil
                }
        }
    }

    private func decision(for page: ApprovalReview) async -> ApprovalResolution? {
        guard page.approval != nil else { return nil }
        while true {
            do { try await Task.sleep(for: .seconds(2)) } catch { return nil }
            if let found = try? await ApprovalInbox.load(sessionID: sessionID).resolution(of: page) { return found }
            if Task.isCancelled { return nil }
        }
    }

    private func close() {
        WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
        let page = shown, known = resolution
        shown = nil
        resolution = nil
        Task {
            var result = known
            // Done can be tapped a moment after the passkey press, before the watch has seen it.
            if result == nil, let page {
                result = try? await ApprovalInbox.load(sessionID: sessionID).resolution(of: page)
            }
            if let result { ApprovalResolution.announce(result) }
            finished(result)
        }
    }
}

extension View {
    func approvalReview(_ review: Binding<ApprovalReview?>, sessionID: String,
                        finished: @escaping (ApprovalResolution?) -> Void) -> some View {
        modifier(ApprovalReviewSheet(review: review, sessionID: sessionID, finished: finished))
    }
}

#Preview("Approval rows") {
    NavigationStack {
        List {
            Section("Waiting for you") {
                ApprovalRow(kind: .email, title: "Schedule for Thursday", recipients: ["reader@example.org"], heldAt: .now.addingTimeInterval(-240))
                ApprovalRow(kind: .action, title: "itx.calendar.send", recipients: [], heldAt: .now.addingTimeInterval(-3600))
                ApprovalRow(kind: .signature, title: "Create example.org/banana", recipients: [], heldAt: .now.addingTimeInterval(-60))
            }
        }
        .safeAreaInset(edge: .bottom) { ApprovalOutcomeNote(outcome: .init(kind: .email, outcome: .approved)) }
        .navigationTitle("Your move")
    }
}
