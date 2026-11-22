import SwiftUI
import WidgetKit

enum ApprovalReviewLink {
    static let inbox = Deployment.current.issuer.appendingPathComponent("secrets/approvals")

    static func item(_ value: String) -> URL? {
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

struct PendingApproval: Decodable, Identifiable {
    enum Kind: String, Decodable { case email, action }

    let id: Int
    let kind: Kind
    let title: String
    let recipients: [String]
    let heldAt: Date
    let reviewURL: String
}

struct ApprovalsView: View {
    private struct Inbox: Decodable { let items: [PendingApproval] }
    private struct Review: Identifiable { let id: URL }

    let sessionID: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var items: [PendingApproval]?
    @State private var issue: String?
    @State private var reviewing: Review?
    @State private var requestID = UUID()

    init(sessionID: String) {
        self.sessionID = sessionID
        _items = State(initialValue: ReviewLists.recall("approvals", for: sessionID))
    }

    var body: some View {
        List {
            if let issue {
                Section {
                    Text(issue)
                    Button("Try again") { Task { await reload() } }
                }
            }
            if let items {
                if items.isEmpty {
                    ContentUnavailableView("No pending mail or actions", systemImage: "tray")
                        .listRowBackground(Color.clear)
                } else {
                    Section("Waiting for review") {
                        ForEach(items) { item in
                            Button { open(ApprovalReviewLink.item(item.reviewURL)) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: item.kind == .email ? "envelope" : "bolt")
                                        .frame(width: 24).foregroundStyle(.secondary)
                                        .accessibilityLabel(item.kind == .email ? "Email" : "Agent action")
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(verbatim: item.title).foregroundStyle(.primary)
                                        if !item.recipients.isEmpty {
                                            Text(verbatim: item.recipients.joined(separator: ", "))
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                        Text(item.heldAt, style: .relative)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .accessibilityLabel(Text("Submitted \(item.heldAt.formatted())"))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                                }
                            }.accessibilityHint("Review the exact request and approve or reject it with your passkey.")
                        }
                    }
                }
            } else if issue == nil {
                ProgressView("Checking approvals…")
            }
            Section {
                Button { open(ApprovalReviewLink.inbox) } label: {
                    Label("All approval requests", systemImage: "signature")
                }
            } footer: {
                Text("Includes proposed rules and requests that use a secret.")
            }
        }
        .privacySensitive()
        .navigationTitle("Approvals")
        .refreshable { await reload() }
        .task(id: scenePhase) {
            if scenePhase == .active { await reload() }
        }
        .sheet(item: $reviewing, onDismiss: {
            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
            Task { await reload() }
        }) { review in
            IterateBrowser(url: review.id).ignoresSafeArea()
        }
    }

    private func open(_ url: URL?) {
        do {
            guard try CredentialStore().load()?.clientID == sessionID else { throw AssistantIssue.changedSession }
            guard let url else { throw ConnectionIssue.invalidResponse }
            reviewing = Review(id: url)
        } catch {
            requestID = UUID()
            items = nil
            reviewing = nil
            issue = error.localizedDescription
        }
    }

    private func reload() async {
        let id = UUID()
        requestID = id
        do {
            let (data, _) = try await AssistantCenter.shared.request("GET", path: "/approvals", requiredSession: sessionID)
            let latest = try AssistantCenter.decoder().decode(Inbox.self, from: data)
            guard !Task.isCancelled, requestID == id else { return }
            items = latest.items
            issue = nil
            ReviewLists.keep(latest.items, as: "approvals", for: sessionID)
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            let paired = (try? CredentialStore().load()?.clientID) == sessionID
            if !paired { reviewing = nil }
            // What was last read stays up through a network failure. It goes when the session does.
            if !paired || PairedSession.isAccessDenied(error) {
                items = nil
                ReviewLists.keep(nil as [PendingApproval]?, as: "approvals", for: sessionID)
            }
            issue = error.localizedDescription
        }
    }
}
