import ActivityKit
import Foundation
import OSLog

/// What `/attention` answers the member's own session: the counts the activity shows, when the
/// first of them can no longer be decided, and the urgent todos by their words.
struct AttentionSummary: Decodable, Equatable, Sendable {
    struct UrgentTodo: Decodable, Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
        let project: String
    }

    let state: IterateAttentionAttributes.ContentState
    let until: Date?
    let urgentTodos: [UrgentTodo]
    /// The page that lists the todos, where the mind names one. Only a secure address is followed.
    let todoList: URL?

    private enum CodingKeys: CodingKey { case until, urgentTodos, todoList }

    init(state: IterateAttentionAttributes.ContentState, until: Date? = nil, urgentTodos: [UrgentTodo] = [], todoList: URL? = nil) {
        self.state = state
        self.until = until
        self.urgentTodos = urgentTodos
        self.todoList = todoList
    }

    init(from decoder: Decoder) throws {
        state = try IterateAttentionAttributes.ContentState(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let milliseconds = try values.decodeIfPresent(Double.self, forKey: .until) ?? 0
        until = milliseconds > 0 ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
        urgentTodos = try values.decodeIfPresent([UrgentTodo].self, forKey: .urgentTodos) ?? []
        let page = try values.decodeIfPresent(String.self, forKey: .todoList).flatMap(URL.init(string:))
        todoList = page?.scheme == "https" && page?.host != nil ? page : nil
    }

    @MainActor static func load(sessionID: String) async throws -> AttentionSummary {
        let (data, _) = try await AssistantCenter.shared.request("GET", path: "/attention", requiredSession: sessionID)
        return try JSONDecoder().decode(AttentionSummary.self, from: data)
    }
}

/// The Live Activity that says what needs the member. The mind keeps it true over Apple's push
/// service while the app is closed. This keeps it true while the app is open, tells the mind which
/// tokens reach this iPhone, and says when the member took the activity away.
@MainActor
enum AttentionLiveActivity {
    typealias Attention = Activity<IterateAttentionAttributes>
    typealias Content = IterateAttentionAttributes.ContentState

    private static let logger = Logger(subsystem: Deployment.current.bundleID, category: "Attention")
    private static let dismissedKey = "iterate.attentionDismissed"
    private static var observing = false
    private static var tracked: Set<String> = []
    private static var ended: Set<String> = []
    /// The start token the mind holds for this installation, and for which pairing.
    private static var registered: (member: String, token: String?)?

    /// Follows every attention activity on this iPhone, and the token that starts one. Runs once
    /// for each launch, also when Apple starts the app in the background for a pushed activity.
    static func observe() {
        guard !observing else { return }
        observing = true
        for activity in Attention.activities { track(activity) }
        Task { for await activity in Attention.activityUpdates { track(activity) } }
        Task { for await _ in ActivityAuthorizationInfo().activityEnablementUpdates { await registerStartToken() } }
        if #available(iOS 17.2, *) {
            Task { for await _ in Attention.pushToStartTokenUpdates { await registerStartToken() } }
        }
    }

    /// Reads what waits and shows it. Called while the app is in front: only then may it start
    /// an activity itself.
    static func refresh(sessionID: String) async {
        observe()
        await registerStartToken()
        do { await show(try await AttentionSummary.load(sessionID: sessionID)) }
        catch { logger.notice("What needs you was not read (\((error as NSError).code, privacy: .public))") }
    }

    /// Brings the activity on this iPhone to `summary`. One the member swiped away stays away
    /// until the counts change.
    static func show(_ summary: AttentionSummary) async {
        // An activity is named by its id from here on: one is looked up again for each call it takes.
        let live = Attention.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        let ids = live.map(\.id), shown = live.first?.content.state
        for extra in ids.dropFirst() { await end(extra) }
        let content = ActivityContent(state: summary.state, staleDate: summary.until,
                                      relevanceScore: summary.state.urgent + summary.state.approvals + summary.state.signatures > 0 ? 100 : 50)
        switch AttentionActivityStep.from(shown: shown, to: summary.state,
                                          enabled: ActivityAuthorizationInfo().areActivitiesEnabled, dismissed: dismissed) {
        case .none: return
        case .update:
            for activity in Attention.activities where activity.id == ids.first { await activity.update(content) }
        case .end:
            for id in ids { await end(id) }
        case .start:
            do {
                track(try Attention.request(attributes: IterateAttentionAttributes(), content: content, pushType: .token))
                dismissed = nil
            } catch {
                logger.notice("The attention activity did not start (\((error as NSError).code, privacy: .public))")
            }
        }
    }

    /// Ends the activity `id` at once, as this app's own doing and not the member's.
    private static func end(_ id: String) async {
        ended.insert(id)
        for activity in Attention.activities where activity.id == id { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The pairing ended: nothing of it stays on the Lock Screen.
    static func clear() async {
        dismissed = nil
        registered = nil
        for id in Attention.activities.map(\.id) { await end(id) }
    }

    private static var dismissed: Content? {
        get { UserDefaults.standard.data(forKey: dismissedKey).flatMap { try? JSONDecoder().decode(Content.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: dismissedKey) }
    }

    private static func track(_ activity: Attention) {
        guard tracked.insert(activity.id).inserted else { return }
        Task {
            for await token in activity.pushTokenUpdates { await report(token: WaitingPush.hex(token)) }
        }
        Task {
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                // Taken away while it still counted something: the member's doing, not an ending.
                let swiped = state == .dismissed && !ended.contains(activity.id)
                ended.insert(activity.id)
                if swiped { dismissed = activity.content.state }
                // A newer activity's token is the one the mind holds: this one's end is no news.
                if !Attention.activities.contains(where: { $0.id != activity.id && $0.activityState == .active }) {
                    await report(token: nil, dismissed: swiped)
                }
                if state == .dismissed { break }
            }
            tracked.remove(activity.id)
        }
    }

    /// Tells the mind the token that starts the activity here, or that there is none while Live
    /// Activities are off. Once for each pairing and token.
    private static func registerStartToken() async {
        guard let member = try? CredentialStore().load()?.clientID else { return }
        var token: String?
        if #available(iOS 17.2, *), ActivityAuthorizationInfo().areActivitiesEnabled {
            token = Attention.pushToStartToken.map(WaitingPush.hex)
        }
        if let registered, registered.member == member, registered.token == token { return }
        do {
            try await WaitingPush.register(["attentionStartToken": token ?? NSNull()], for: member)
            registered = (member, token)
        } catch {
            logger.notice("Registering the attention activity will retry (\((error as NSError).code, privacy: .public))")
        }
    }

    private static func report(token: String?, dismissed: Bool = false) async {
        guard let member = try? CredentialStore().load()?.clientID else { return }
        var body: [String: Any] = ["deviceId": WaitingPush.installation, "token": token ?? NSNull()]
        if dismissed { body["dismissed"] = true }
        for attempt in 0..<2 {
            do {
                _ = try await AssistantCenter.shared.request("PUT", path: "/attention/activity", body: body, requiredSession: member)
                return
            } catch AssistantIssue.conflict(_) where attempt == 0 {
                // The mind does not know this installation yet: an activity can start before any alert was allowed.
                registered = nil
                await registerStartToken()
            } catch {
                logger.notice("The attention activity's token was not sent (\((error as NSError).code, privacy: .public))")
                return
            }
        }
    }
}
