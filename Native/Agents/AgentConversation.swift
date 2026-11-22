import Foundation
import Observation
import WidgetKit

@MainActor @Observable
final class AgentConversation: Hashable {
    nonisolated static func == (lhs: AgentConversation, rhs: AgentConversation) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    private struct Outgoing {
        let text: String
        let key = UUID().uuidString.lowercased()
    }

    private let newAgentID: UUID?
    private var path: String?
    private(set) var firstMessageTitle: String?
    private var firstReceiptToFollow: Int?
    @ObservationIgnored private var firstDeliveryWasUncertain = false
    private var openedForVoice = false
    var isNewDraft: Bool { newAgentID != nil && firstMessageTitle == nil && !openedForVoice }
    var isLocalDraft: Bool { isNewDraft && firstMember == nil }

    @ObservationIgnored private(set) var receivedInput = false
    func markInput() { receivedInput = true }
    var draft = "" {
        didSet { if draft != oldValue { markInput() } }
    }
    private(set) var messages: [AgentChatMessage] = []
    private(set) var floor: Int?
    private(set) var connected = false
    private(set) var loadingEarlier = false
    private(set) var sending = false
    private(set) var readError: String?
    private(set) var sendError: String?
    private(set) var lastSent: Int?
    @ObservationIgnored private var through: Int?
    @ObservationIgnored private var visit: UUID?
    @ObservationIgnored private var screens: Set<UUID> = []
    @ObservationIgnored private var channel: AgentChatChannel?
    @ObservationIgnored private var preloading: Task<Void, Never>?
    private var pending: Outgoing?
    var outgoingText: String? { sending || sendError != nil ? pending?.text : nil }
    @ObservationIgnored private var firstMember: String?

    init(path: String) {
        self.path = path
        newAgentID = nil
    }

    init(newAgentID: UUID = UUID()) {
        self.newAgentID = newAgentID
        floor = 0
    }

    /// Dash groups Iterate agents by the normalized local part of their member's email.
    static func newAgentPath(id: UUID, email: String?) -> String {
        let local = (email ?? "").prefix { $0 != "@" }.lowercased()
        let slug = local.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let person = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let parent = person.isEmpty ? "/agents/web" : "/agents/people/\(person)/web"
        return parent + "/" + id.uuidString.lowercased()
    }

    func voiceDestination(member: String, email: String?) throws -> VoiceDestination {
        if let id = newAgentID {
            return .agent(path: try claimDraft(id, member: member, email: email), draftID: id)
        }
        guard let path else { throw ConnectionIssue.invalidResponse }
        return .agent(path: path, draftID: nil)
    }

    func voiceConnected() {
        guard isNewDraft else { return }
        firstReceiptToFollow = 0
        openedForVoice = true
    }

    private func claimDraft(_ id: UUID, member: String, email: String?) throws -> String {
        guard firstMember == nil || firstMember == member else { throw AssistantIssue.changedSession }
        firstMember = member
        let target = path ?? Self.newAgentPath(id: id, email: email)
        path = target
        return target
    }

    /// A kept conversation can be on more than one screen. It stays live until the last one leaves.
    func open(on link: MindSocket?, for screen: UUID) async {
        screens.insert(screen)
        await open(on: link)
    }

    func leave(_ screen: UUID) {
        screens.remove(screen)
        if screens.isEmpty { close() }
    }

    func open(on link: MindSocket?) async {
        close()
        readError = nil
        guard !isNewDraft, let link else { return }
        let visit = UUID()
        self.visit = visit
        // A read that is already on its way serves this visit.
        await preloading?.value
        guard self.visit == visit, !Task.isCancelled else { return }
        do {
            guard let path else { throw ConnectionIssue.invalidResponse }
            let live = try AgentChatChannel(socket: link, path: path)
            channel = live
            if let offset = firstReceiptToFollow {
                // Replay any reply that arrived before the first send was acknowledged.
                try await follow(live, after: offset)
                try requireCurrent(visit)
                firstReceiptToFollow = nil
            } else if let held = through {
                // The words are already on screen. One round trip replays what was missed and goes live.
                async let head = live.head()
                try await follow(live, after: held)
                let latest = try await head
                try requireCurrent(visit)
                if held > latest {
                    // The agent's log was replaced. Read it again from its end.
                    through = nil; floor = nil; messages = []
                    await open(on: link)
                    return
                }
            } else {
                let tail = try await live.latest()
                try requireCurrent(visit)
                show(tail)
                try await follow(live, after: tail.head)
            }
            try requireCurrent(visit)
            connected = true
        } catch {
            guard self.visit == visit, !Task.isCancelled else { return }
            close()
            readError = error.localizedDescription
        }
    }

    /// Read the newest messages ahead of a visit, so the conversation opens on them.
    func preload(on link: MindSocket) {
        guard !isNewDraft, through == nil, visit == nil, preloading == nil, let path else { return }
        preloading = Task {
            defer { preloading = nil }
            guard let reader = try? AgentChatChannel(socket: link, path: path) else { return }
            defer { reader.close() }
            guard let tail = try? await reader.latest(), through == nil else { return }
            show(tail)
        }
    }

    private func show(_ tail: (head: Int, floor: Int, messages: [AgentChatMessage])) {
        merge(tail.messages)
        floor = tail.floor
        through = tail.head
    }

    private func follow(_ live: AgentChatChannel, after offset: Int) async throws {
        try await live.follow(after: offset) { [weak self, weak live] events in
            guard let self, let live, self.channel === live else { return }
            self.merge(events.compactMap(AgentChatMessage.init(event:)))
            if let offset = events.compactMap({ $0["offset"] as? Int }).max() {
                self.through = max(self.through ?? 0, offset)
            }
        }
    }

    func close() {
        channel?.close()
        channel = nil
        visit = nil
        connected = false
        loadingEarlier = false
    }

    func loadEarlier() async {
        guard let live = channel, let end = floor, end > 0, !loadingEarlier else { return }
        loadingEarlier = true
        defer { if channel === live { loadingEarlier = false } }
        do {
            let older = try await live.earlier(than: end)
            guard channel === live, !Task.isCancelled else { return }
            merge(older.messages)
            floor = older.floor
            readError = nil
        } catch {
            if channel === live, !Task.isCancelled { readError = error.localizedDescription }
        }
    }

    func sendDraft(using connection: MindConnection) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, sendError == nil,
              case .paired(let member) = connection.pairing, isNewDraft || connected else { return }
        let outgoing = pending.flatMap { $0.text == text ? $0 : nil } ?? Outgoing(text: text)
        draft = ""
        await deliver(outgoing, for: member, using: connection)
    }

    func retryFailedSend(using connection: MindConnection) async {
        guard !sending, sendError != nil, let pending, case .paired(let member) = connection.pairing else { return }
        await deliver(pending, for: member, using: connection)
    }

    func dismissFailedSend() {
        guard !sending, sendError != nil, let pending else { return }
        if draft.isEmpty { draft = pending.text }
        sendError = nil
    }

    private func deliver(_ outgoing: Outgoing, for member: String, using connection: MindConnection) async {
        let text = outgoing.text
        pending = outgoing
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            if isNewDraft, let id = newAgentID {
                guard firstMember == nil || firstMember == member else { throw AssistantIssue.changedSession }
                firstMember = member
                let session = try await connection.agentSession(for: member)
                let target = try claimDraft(id, member: member, email: session.email)
                guard connection.pairing == .paired(member) else { throw AssistantIssue.changedSession }
                let receipt = try await AgentChatChannel.startAgent(at: target, text: text, key: outgoing.key, on: session.link)
                guard connection.pairing == .paired(member) else { throw AssistantIssue.changedSession }
                merge([receipt])
                through = receipt.id
                firstReceiptToFollow = firstDeliveryWasUncertain ? 0 : receipt.id
                firstMessageTitle = String(text.prefix { !$0.isNewline }.prefix(80))
            } else {
                guard let live = channel else { throw ConnectionIssue.lostConnection }
                merge([try await live.send(text, key: outgoing.key)])
            }
            WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.recentAgentsWidgetKind)
        } catch {
            if pending?.key == outgoing.key {
                if isNewDraft { firstDeliveryWasUncertain = true }
                sendError = error.localizedDescription
            }
        }
    }

    private func merge(_ added: [AgentChatMessage]) {
        guard !added.isEmpty else { return }
        messages = AgentChatMessage.merge(added, into: messages)
        if openedForVoice, firstMessageTitle == nil, let first = messages.first(where: { $0.role == .input && !$0.text.isEmpty }) {
            firstMessageTitle = String(first.text.prefix { !$0.isNewline }.prefix(80))
        }
        if let pending, let receipt = added.first(where: { $0.sendKey == "agent-message:" + pending.key && $0.text == pending.text }) {
            if !sending, sendError == nil, draft == pending.text { draft = "" }
            lastSent = receipt.id
            self.pending = nil
            sendError = nil
        }
    }

    private func requireCurrent(_ visit: UUID) throws {
        try Task.checkCancellation()
        guard self.visit == visit else { throw CancellationError() }
    }
}

/// The conversations read in this pairing. Returning to one shows its words at once, and the
/// agents at the top of the list are read before they are opened.
@MainActor
final class AgentConversations {
    static let capacity = 12
    private var held: [String: AgentConversation] = [:]
    private var recent: [String] = []

    func conversation(for path: String) -> AgentConversation {
        recent.removeAll { $0 == path }
        recent.append(path)
        if let conversation = held[path] { return conversation }
        let conversation = AgentConversation(path: path)
        held[path] = conversation
        // A screen that still shows a dropped conversation keeps it alive on its own.
        while recent.count > Self.capacity { held[recent.removeFirst()] = nil }
        return conversation
    }

    func preload(_ paths: [String], on link: MindSocket) {
        for path in paths where held[path] == nil || held[path]?.floor == nil {
            conversation(for: path).preload(on: link)
        }
    }

    func forget() {
        for conversation in held.values { conversation.close() }
        held = [:]
        recent = []
    }
}
