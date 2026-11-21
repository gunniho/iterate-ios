import Foundation
import Observation

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
    @ObservationIgnored private var socket: MindSocket?
    @ObservationIgnored private var channel: AgentChatChannel?
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

    func open(on link: MindSocket?) async {
        close()
        readError = nil
        guard !isNewDraft, let link else { return }
        socket = link
        do {
            guard let path else { throw ConnectionIssue.invalidResponse }
            let live = try AgentChatChannel(socket: link, path: path)
            channel = live
            if let offset = firstReceiptToFollow {
                // Replay any reply that arrived before the first send was acknowledged.
                try await follow(live, after: offset)
                try requireCurrent(link)
                firstReceiptToFollow = nil
            } else {
                let head = try await live.head()
                try requireCurrent(link)
                if let through, through > head { self.through = nil; floor = nil; messages = [] }
                let start = through ?? max(0, head - AgentChatChannel.window)
                let latest = try await live.messages(after: start, through: head)
                try requireCurrent(link)
                merge(latest)
                if floor == nil { floor = start }
                through = head
                try await follow(live, after: head)
            }
            try requireCurrent(link)
            connected = true
        } catch {
            guard socket === link, !Task.isCancelled else { return }
            close()
            readError = error.localizedDescription
        }
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
        socket = nil
        connected = false
        loadingEarlier = false
    }

    func loadEarlier() async {
        guard let live = channel, let link = socket, let end = floor, end > 0, !loadingEarlier else { return }
        loadingEarlier = true
        defer { if channel === live { loadingEarlier = false } }
        do {
            let start = max(0, end - AgentChatChannel.window)
            let older = try await live.messages(after: start, through: end)
            try requireCurrent(link)
            guard channel === live else { return }
            merge(older)
            floor = start
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

    private func requireCurrent(_ link: MindSocket) throws {
        try Task.checkCancellation()
        guard socket === link else { throw CancellationError() }
    }
}
