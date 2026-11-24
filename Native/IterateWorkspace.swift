import AppIntents
import LockedCameraCapture
import SwiftUI
import WidgetKit

@MainActor
struct IterateWindow: View {
    let connection: MindConnection
    @EnvironmentObject private var scene: IterateShortcutScene

    var body: some View {
        IterateWorkspace(connection: connection, requestedAgents: scene.requestedAgents, consume: scene.consume)
    }
}

@MainActor
struct IterateWorkspace: View {
    private enum Screen: Hashable { case pair, capture, settings, yourMove, approvals, agent(String), newAgent(AgentConversation) }
    private struct BrowserPage: Identifiable { let id: URL }

    let connection: MindConnection
    private let requestedAgents: [AgentConversation]
    private let consume: ([AgentConversation]) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Screen]
    @State private var captureMode: IterateCaptureMode = .library
    @State private var captureVisit = UUID()
    @State private var lockedPhotoID: UUID?
    @State private var browser: BrowserPage?
    @State private var message: String?
    /// The new agent that "Talk to Iterate" opened, which calls as soon as it is on screen.
    @State private var calling: AgentConversation?
    @State private var waitingApprovals = 0
    @State private var lastYourMoveReload: (session: String, date: Date)?

    init(connection: MindConnection, requestedAgents: [AgentConversation], consume: @escaping ([AgentConversation]) -> Void) {
        self.connection = connection
        self.requestedAgents = requestedAgents
        self.consume = consume
        _path = State(initialValue: requestedAgents.map(Screen.newAgent))
    }

    var body: some View {
        NavigationStack(path: $path) {
            AgentsHome(connection: connection, isVisible: path.isEmpty, connect: pair) { path.append(.agent($0.path)) }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { path = [.settings] } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    approvalsItem
                    ToolbarItem(placement: .topBarTrailing) {
                        // A tap here pushes the screen in, the way it will leave.
                        Button { openNewAgent(AgentConversation(), animated: true) } label: { Label("New Agent", systemImage: "plus") }
                            .accessibilityIdentifier("iterate.agents.new")
                    }
                }
                .navigationDestination(for: Screen.self, destination: screen)
        }
        .tint(.accentColor)
        .onAppear {
            IterateCameraLaunch.bind { showCapture(.camera) }
            if let destination = NativeRouteBus.shared.take() { route(destination, startVoice: true) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { connection.activate() }
            else if phase == .background { connection.background() }
        }
        .onChange(of: connection.pairing, initial: true) { previous, pairing in
            guard pairing != .checking else { return }
            let paired = connection.hasSavedSession
            if previous != pairing {
                WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
                WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.recentAgentsWidgetKind)
            }
            if !paired, IterateCompanions.shared.paired { clearPrivateState() }
            IterateCompanions.shared.setPaired(paired)
            if paired, path.last == .pair { path.removeLast() }
        }
        .onChange(of: connection.agentLink.map(ObjectIdentifier.init)) { _, link in
            if link == nil { IterateScreenShare.shared.stop() }
        }
        .task(id: scenePhase == .active && path.last == .capture) {
            if scenePhase == .active, path.last == .capture { await refreshFocus() }
        }
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await TaskInboxUpgrade.removeLocalInbox() }
        }
        .task(id: approvalCountScope) {
            guard let sessionID = approvalCountScope else { return }
            // A request that starts waiting while this screen is up should reach the badge unasked.
            while !Task.isCancelled {
                if let counts = try? await YourMoveCounts.fetch(requiredSession: sessionID), !Task.isCancelled {
                    waitingApprovals = counts.approvalCount + counts.questionCount
                }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .task(id: connection.agentLink != nil && scenePhase == .active) {
            if connection.agentLink != nil, scenePhase == .active { await TaskInboxUpgrade.retirePushRegistration() }
        }
        .task(id: foregroundWidgetSession) {
            if let session = foregroundWidgetSession { await refreshYourMove(for: session) }
        }
        .task(id: attentionSession) {
            // Only an app in front may start the activity itself. The mind's pushes keep it true after.
            if let session = attentionSession { await AttentionLiveActivity.refresh(sessionID: session) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .iterateRouteChanged)) { _ in
            if let destination = NativeRouteBus.shared.take() { route(destination, startVoice: true) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let target = IterateAgent.linkedPath(url) else { return .systemAction }
            if path.last != .agent(target) { path.append(.agent(target)) }
            return .handled
        })
        .onOpenURL(perform: openLink)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) {
            if let url = $0.webpageURL { openLink(url) }
        }
        .sheet(item: $browser) { IterateBrowser(url: $0.id).ignoresSafeArea() }
        .alert("Iterate", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .modifier(LockedPhotoContinuation { id in showCapture(.lockedPhoto, id: id) })
        .handlesExternalEvents(preferring: [StartNewIterateAgent.sceneIdentifier], allowing: ["*"])
        .onChange(of: requestedAgents, initial: true) { _, requests in
            for draft in requests where !path.contains(.newAgent(draft)) { openNewAgent(draft) }
            consume(requests)
        }
    }

    private var approvalsButton: some View {
        Button { path = [.yourMove] } label: { Label("Your move", systemImage: "tray") }
            .accessibilityValue(waitingApprovals > 0 ? Text("\(waitingApprovals) waiting") : Text(""))
    }

    private var approvalsItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            // Toolbar buttons draw a badge from iOS 26. Earlier systems get a dot.
            if #available(iOS 26, *) { approvalsButton.badge(waitingApprovals) }
            else {
                approvalsButton.overlay(alignment: .topTrailing) {
                    if waitingApprovals > 0 {
                        Circle().fill(.red).frame(width: 8, height: 8).offset(x: 2, y: -2).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private var approvalCountScope: String? {
        guard scenePhase == .active, path.isEmpty, case .paired(let sessionID) = connection.pairing else { return nil }
        return sessionID
    }

    @ViewBuilder private func screen(_ destination: Screen) -> some View {
        switch destination {
        case .newAgent(let draft):
            AgentConversationView(draft: draft, connection: connection, startsCall: calling === draft, pair: {
                path.append(.pair)
                connection.connect()
            }).id(draft)
        case .agent(let target):
            if case .paired(let session) = connection.pairing,
               let agent = connection.directory.rows?.first(where: { $0.path == target }) {
                AgentConversationView(agent: agent, connection: connection).id([session, target])
            } else if connection.pairing == .unpaired { connectionScreen }
            else {
                Group {
                    if case .failed(let reason) = connection.phase {
                        ContentUnavailableView {
                            Label("Couldn’t load agent", systemImage: "wifi.exclamationmark")
                        } description: { Text(reason) } actions: { Button("Try again", action: connection.connect) }
                    } else if let issue = connection.directory.refreshError, let link = connection.agentLink {
                        ContentUnavailableView {
                            Label("Couldn’t load agent", systemImage: "wifi.exclamationmark")
                        } description: { Text(issue) } actions: {
                            Button("Try again") { Task { await connection.directory.refresh(on: link) } }
                        }
                    } else if connection.directory.rows == nil { ProgressView("Loading agent…") }
                    else { ContentUnavailableView("Agent unavailable", systemImage: "bubble.left.and.bubble.right") }
                }
                .task(id: connection.agentLink.map(ObjectIdentifier.init)) {
                    if let link = connection.agentLink { await connection.directory.refresh(on: link) }
                }
            }
        case .pair: connectionScreen
        case .approvals, .yourMove:
            if case .paired(let sessionID) = connection.pairing {
                ApprovalsView(sessionID: sessionID).id(sessionID)
            } else if connection.pairing == .checking {
                ProgressView("Checking your connection…")
            } else { connectionScreen }
        case .capture:
            IterateCaptureView(initialMode: captureMode, lockedPhotoID: lockedPhotoID)
                .navigationTitle("Capture")
                .id(captureVisit)
        case .settings: IntegrationSettings(connection: connection)
        }
    }

    private var connectionScreen: some View {
        ConnectionScreen(phase: connection.phase, hasSavedSession: connection.hasSavedSession, connect: connection.connect,
                         cancel: connection.cancelApproval, disconnect: connection.disconnect, voice: connection.voice)
    }

    private func pair() {
        path = [.pair]
        connection.connect()
    }

    private func openLink(_ url: URL) {
        if let target = IterateAgent.linkedPath(url) { openAgents(target) }
        else if let destination = NativeDestination(url: url) { route(destination, startVoice: false) }
    }

    private func openAgents(_ target: String? = nil) {
        browser = nil
        message = nil
        path = target.map { [.agent($0)] } ?? []
    }

    private func newAgent() {
        openNewAgent(AgentConversation())
    }

    /// A button, a shortcut or a launch opens the composer already in place, ready for typing.
    private func openNewAgent(_ draft: AgentConversation, animated: Bool = false) {
        var transaction = Transaction()
        if !animated {
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        withTransaction(transaction) {
            browser = nil
            message = nil
            path.append(.newAgent(draft))
        }
    }

    private func showWeb(_ url: URL) { browser = BrowserPage(id: url) }

    private func showCapture(_ mode: IterateCaptureMode, id: UUID? = nil) {
        captureMode = mode
        lockedPhotoID = id
        captureVisit = UUID()
        path = [.capture]
    }

    private func route(_ destination: NativeDestination, startVoice: Bool) {
        switch destination {
        case .agents: openAgents()
        case .newAgent: newAgent()
        case .yourMove:
            browser = nil
            path = [.yourMove]
        case .capture: showCapture(.library)
        case .camera: showCapture(.camera)
        case .talk:
            let draft = AgentConversation()
            if startVoice { calling = draft }
            openNewAgent(draft)
        case .web(let url): showWeb(url)
        case .briefing:
            // The request waits in the message field, for the person to send or change.
            let draft = AgentConversation()
            draft.draft = AssistantCenter.briefingPrompt
            openNewAgent(draft)
        }
    }

    private func refreshFocus() async {
        do {
            let filter = try await IterateFocusFilter.current
            _ = try await filter.perform()
        } catch SetFocusFilterIntentError.notFound {
            UserDefaults(suiteName: IterateAppGroup.identifier)?.removeObject(forKey: FocusContext.key)
        } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }

    private var foregroundWidgetSession: String? {
        guard scenePhase == .active, connection.agentLink != nil,
              case .paired(let session) = connection.pairing else { return nil }
        return session
    }

    private var attentionSession: String? {
        guard scenePhase == .active, case .paired(let session) = connection.pairing else { return nil }
        return session
    }

    private func refreshYourMove(for session: String) async {
        let now = Date.now
        let recent = now.addingTimeInterval(-120)...now
        if let reload = lastYourMoveReload, reload.session == session, recent.contains(reload.date) { return }
        let installed = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let widgets = (try? result.get()) ?? []
                continuation.resume(returning: widgets.contains { $0.kind == IterateAppGroup.yourMoveWidgetKind })
            }
        }
        guard installed, !Task.isCancelled, foregroundWidgetSession == session else { return }
        let checkedAt = YourMoveSnapshotStore.load()?.checkedAt
        if !recent.contains(checkedAt ?? .distantPast) {
            guard (try? await YourMoveCounts.fetch(requiredSession: session)) != nil else { return }
        }
        guard !Task.isCancelled, foregroundWidgetSession == session else { return }
        lastYourMoveReload = (session, .now)
        WidgetCenter.shared.reloadTimelines(ofKind: IterateAppGroup.yourMoveWidgetKind)
    }

    private func clearPrivateState() {
        if case .newAgent(let draft) = path.last {
            path = [.newAgent(draft.isLocalDraft ? draft : AgentConversation())]
        } else {
            path = []
        }
        calling = nil
        browser = nil
        waitingApprovals = 0
        IterateScreenShare.shared.stop()
        Task { await AttentionLiveActivity.clear() }
        lockedPhotoID = nil
        captureVisit = UUID()
        do { try IterateCaptureInbox.clear() } catch { message = error.localizedDescription }
    }
}

private struct LockedPhotoContinuation: ViewModifier {
    let open: (UUID?) -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { activity in
                open((activity.userInfo?["iterateCaptureID"] as? String).flatMap(UUID.init(uuidString:)))
            }
        } else { content }
    }
}
