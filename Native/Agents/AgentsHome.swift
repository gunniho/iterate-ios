import SwiftUI
import UIKit

struct AgentsHome: View {
    let connection: MindConnection
    let isVisible: Bool
    let connect: () -> Void
    let open: (IterateAgent) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var archiveFailure: ArchiveFailure?
    @State private var archiveExits: [String: UUID] = [:]
    @State private var archived: ArchivedNote?

    private struct ArchiveFailure {
        let id = UUID()
        let agent: IterateAgent
        let message: String
        var restoring = false
    }

    /// The agent a swipe just archived, while the swipe can still be taken back.
    private struct ArchivedNote {
        let id = UUID()
        let agent: IterateAgent
    }

    private var displayedRows: [IterateAgent]? {
        connection.directory.rows?.filter { agent in
            archiveExits[agent.path] != nil || !connection.directory.archivedPaths.contains(agent.path)
        }
    }

    var body: some View {
        content
            .navigationTitle("Agents")
            .safeAreaInset(edge: .bottom) { undoNote }
            .animation(IterateMotion.standard, value: archived?.id)
            .sensoryFeedback(trigger: archiveFailure?.id) { _, failure in failure == nil ? nil : .error }
            .alert(failureTitle, isPresented: Binding(
                get: { archiveFailure != nil }, set: { if !$0 { archiveFailure = nil } }
            ), presenting: archiveFailure) { failure in
                Button("Try again") { tryAgain(failure) }
                Button("Cancel", role: .cancel) {}
            } message: { failure in
                Text("\(failure.agent.name): \(failure.message)")
            }
            .onChange(of: connection.pairing) { _, _ in
                archiveFailure = nil
                archiveExits.removeAll()
                archived = nil
            }
            .task(id: isVisible && scenePhase == .active ? connection.agentLink.map(ObjectIdentifier.init) : nil) {
                if isVisible, scenePhase == .active, let link = connection.agentLink {
                    await connection.directory.refresh(on: link)
                    if !Task.isCancelled { connection.preloadRecentConversations() }
                }
            }
    }

    private var failureTitle: LocalizedStringKey {
        archiveFailure?.restoring == true ? "Couldn’t restore agent" : "Couldn’t archive agent"
    }

    private func tryAgain(_ failure: ArchiveFailure) {
        let pairing = connection.pairing
        Task {
            if failure.restoring { await restore(failure.agent, for: pairing) }
            else { _ = await archive(failure.agent, for: pairing) }
        }
    }

    @ViewBuilder private var undoNote: some View {
        if let archived {
            ArchivedAgentNote(name: archived.agent.name) {
                let pairing = connection.pairing
                Task { await restore(archived.agent, for: pairing) }
            }
            .transition(.floatingNote(reduceMotion: reduceMotion))
            .task(id: archived.id) {
                // VoiceOver needs longer to reach the button than a glance does.
                do { try await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 20 : 6)) } catch { return }
                if self.archived?.id == archived.id { self.archived = nil }
            }
        }
    }

    private var content: some View {
        Group {
            if let rows = displayedRows, connection.hasSavedSession {
                List {
                    if rows.isEmpty {
                        ContentUnavailableView(connection.directory.rows?.isEmpty == false ? "No active agents" : "No agents yet",
                                               systemImage: "bubble.left.and.bubble.right")
                            .listRowSeparator(.hidden)
                    }
                    ForEach(rows) { agent in archiveableRow(agent) }
                    if let issue { Section { retryView(issue) } }
                }
                .listStyle(.plain)
                .refreshable { await refresh() }
            } else if let issue {
                ContentUnavailableView {
                    Label("Couldn’t load agents", systemImage: "wifi.exclamationmark")
                } description: { Text(issue) } actions: {
                    Button("Try again") { Task { await refresh() } }
                }
            } else if connection.pairing == .unpaired {
                ContentUnavailableView {
                    Label("Connect to Iterate", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Pair this iPhone to see your agents.")
                } actions: {
                    Button("Connect", action: connect).buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView("Loading agents…")
            }
        }
    }

    private func archiveableRow(_ agent: IterateAgent) -> some View {
        let pairing = connection.pairing
        return AgentArchiveRow(agent: agent, open: { open(agent) },
                               archive: { await archive(agent, for: pairing) },
                               retain: { id, retain in
                                   if retain, connection.pairing == pairing { archiveExits[agent.path] = id }
                                   else if archiveExits[agent.path] == id { archiveExits[agent.path] = nil }
                               })
            .listRowInsets(EdgeInsets())
    }

    private func archive(_ agent: IterateAgent, for pairing: DevicePairing) async -> Bool {
        guard case .paired(let member) = pairing, connection.pairing == pairing else { return false }
        do {
            try await connection.directory.archive(agent.path) {
                if connection.agentLink == nil { connection.connect() }
                let (link, _) = try await connection.agentSession(for: member)
                _ = try await NativeMindTransport().invoke("PUT", path: "/agents/archive",
                    body: ["path": agent.path, "archived": true], over: link)
            }
            let confirmed = connection.pairing == .paired(member) && connection.directory.archivedPaths.contains(agent.path)
            if confirmed {
                // A swipe is easy to make by accident, so it can be taken back.
                archived = ArchivedNote(agent: agent)
                AccessibilityNotification.Announcement("Archived \(agent.name)").post()
            }
            return confirmed
        } catch is CancellationError {
            return false
        } catch {
            if connection.pairing == .paired(member) {
                archiveFailure = ArchiveFailure(agent: agent, message: error.localizedDescription)
            }
            return false
        }
    }

    private func restore(_ agent: IterateAgent, for pairing: DevicePairing) async {
        guard case .paired(let member) = pairing, connection.pairing == pairing else { return }
        archived = nil
        do {
            try await connection.directory.unarchive(agent.path, perform: {
                if connection.agentLink == nil { connection.connect() }
                let (link, _) = try await connection.agentSession(for: member)
                _ = try await NativeMindTransport().invoke("PUT", path: "/agents/archive",
                    body: ["path": agent.path, "archived": false], over: link)
            }, show: { change in withAnimation(reduceMotion ? nil : IterateMotion.standard, change) })
            AccessibilityNotification.Announcement("Restored \(agent.name)").post()
            // The widget's list of recent agents is rebuilt by a refresh.
            if let link = connection.agentLink { await connection.directory.refresh(on: link) }
        } catch is CancellationError {
        } catch {
            if connection.pairing == .paired(member) {
                archiveFailure = ArchiveFailure(agent: agent, message: error.localizedDescription, restoring: true)
            }
        }
    }

    private var issue: String? {
        if case .failed(let message) = connection.phase { return message }
        return connection.directory.refreshError
    }

    private func retryView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Try again") { Task { await refresh() } }.buttonStyle(.borderless).tapTarget()
        }
    }

    private func refresh() async {
        if let link = connection.agentLink { await connection.directory.refresh(on: link) }
        else if connection.hasSavedSession { connection.connect() }
        else { connect() }
    }
}

// Distances are in points, velocity in points per second. Positive x is always screen-right.
struct AgentArchiveKinematics {
    enum Release: Equatable { case close, reveal, archive }
    static let revealWidth: CGFloat = 84

    static func accepts(x: CGFloat, y: CGFloat, revealed: Bool) -> Bool {
        abs(x) > abs(y) * 1.25 && (x > 0 || revealed)
    }

    /// A flick is carried on as a scroll view decelerates, between its fast rate and its normal one:
    /// far enough that a short throw takes the row out, and not so far that a nudge does.
    static let decelerationRate: CGFloat = 0.993

    /// How far right the row must be, or be thrown, for a release to archive it.
    static func commitDistance(width: CGFloat) -> CGFloat { max(revealWidth + 40, width * 0.53) }

    /// Where the row is drawn for a finger at `position`: with the finger to the right of rest,
    /// and giving less and less to the left of it, where there is nothing to reveal.
    static func tracked(_ position: CGFloat, width: CGFloat, elastic: Bool) -> CGFloat {
        if position >= 0 { return position }
        return elastic ? IterateMotion.rubberBand(position, dimension: width) : 0
    }

    static func release(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Release {
        let projected = offset + IterateMotion.projection(velocity, decelerationRate: decelerationRate)
        let threshold = commitDistance(width: width)
        if offset >= 28, velocity > -250, max(offset, projected) >= threshold { return .archive }
        return projected >= revealWidth / 2 ? .reveal : .close
    }

    static func springVelocity(_ velocity: CGFloat, from offset: CGFloat, to target: CGFloat) -> Double {
        let distance = target - offset
        guard abs(distance) > 1 else { return 0 }
        return Double(min(12, max(-12, velocity / distance)))
    }

    static func exitTarget(width: CGFloat) -> CGFloat { width + 32 }
}

private struct AgentArchiveRow: View {
    let agent: IterateAgent
    let open: () -> Void
    let archive: @MainActor () async -> Bool
    let retain: (UUID, Bool) -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var startOffset: CGFloat = 0
    @State private var live = LiveValue()
    /// Whether letting go now would archive, which the rail shows and a tap in the hand marks.
    @State private var armed = false
    @State private var crossings = 0
    @State private var attempt: UUID?
    @State private var didExit = false
    @State private var didConfirm = false

    var body: some View {
        let busy = attempt != nil
        ZStack {
            if offset > 0 || busy {
                archiveRail(busy: busy)
            }
            AgentRow(agent: agent, isArchiving: busy, inset: 20) {
                if offset > 0 { settle(at: 0, velocity: 0) }
                else if !busy { open() }
            }
            .accessibilityActions { if !busy { archiveButton } }
            .background(Color(uiColor: .systemBackground))
            .modifier(TrackedOffset(x: offset, live: live))
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .background(AgentArchivePan(enabled: !busy, revealed: offset > 0, onPan: pan))
        .contextMenu { if !busy { archiveButton } }
        .sensoryFeedback(.impact(weight: .medium), trigger: crossings)
    }

    private var archiveButton: some View {
        Button { commit(width: 0, velocity: 0, animate: false) } label: {
            Label("Archive", systemImage: "archivebox")
        }
    }

    private func archiveRail(busy: Bool) -> some View {
        let left: Alignment = layoutDirection == .leftToRight ? .leading : .trailing
        return ZStack(alignment: left) {
            if busy {
                Color(uiColor: .secondarySystemBackground)
                Color.accentColor.frame(width: AgentArchiveKinematics.revealWidth)
                ProgressView().tint(.white)
                    .frame(width: AgentArchiveKinematics.revealWidth)
                    .accessibilityHidden(true)
            } else {
                Color.accentColor
                Button { commit(width: 0, velocity: 0, animate: false) } label: {
                    VStack(spacing: 3) {
                        // The box fills once letting go would archive.
                        Image(systemName: "archivebox").font(.title3)
                            .symbolVariant(armed ? .fill : .none)
                            .scaleEffect(armed && !reduceMotion ? 1.15 : 1)
                        Text("Archive").font(.caption.weight(.medium))
                    }
                    .animation(reduceMotion ? nil : IterateMotion.momentum, value: armed)
                    .frame(width: AgentArchiveKinematics.revealWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityHidden(true) // The row exposes the equivalent named action.
            }
        }
    }

    private func pan(_ state: UIGestureRecognizer.State, _ x: CGFloat, _ velocity: CGFloat, _ width: CGFloat) {
        guard attempt == nil, width > 0 else { return }
        // A settle may still be in flight: the finger takes the row from where it is drawn.
        if state == .began { startOffset = live.value }
        if state == .began || state == .changed || state == .ended {
            // The row follows the finger with Reduce Motion on too. Only what moves by itself is stilled.
            let tracked = AgentArchiveKinematics.tracked(startOffset + x, width: width, elastic: !reduceMotion)
            var direct = Transaction(animation: nil)
            direct.disablesAnimations = true
            withTransaction(direct) { offset = tracked }
            let reached = state != .ended && tracked >= AgentArchiveKinematics.commitDistance(width: width)
            if reached != armed {
                if state == .changed { crossings += 1 }
                armed = reached
            }
            if state == .ended {
                switch AgentArchiveKinematics.release(offset: tracked, velocity: velocity, width: width) {
                case .archive: commit(width: width, velocity: velocity, animate: !reduceMotion)
                case .reveal: settle(at: AgentArchiveKinematics.revealWidth, velocity: velocity)
                case .close: settle(at: 0, velocity: velocity)
                }
            }
        } else if state == .cancelled || state == .failed {
            armed = false
            settle(at: startOffset > 0 ? AgentArchiveKinematics.revealWidth : 0, velocity: 0)
        }
    }

    private func settle(at target: CGFloat, velocity: CGFloat) {
        guard !reduceMotion else { offset = target; return }
        let initial = AgentArchiveKinematics.springVelocity(velocity, from: live.value, to: target)
        withAnimation(IterateMotion.released(response: 0.29, dampingRatio: 0.93, velocity: initial)) {
            offset = target
        }
    }

    private func commit(width: CGFloat, velocity: CGFloat, animate: Bool) {
        guard attempt == nil else { return }
        let id = UUID()
        attempt = id
        didConfirm = false
        didExit = !animate
        retain(id, true)
        if animate {
            let target = AgentArchiveKinematics.exitTarget(width: width)
            let initial = AgentArchiveKinematics.springVelocity(velocity, from: live.value, to: target)
            // Thrown clear of the list, so it leaves without a bounce.
            withAnimation(IterateMotion.released(response: 0.32, dampingRatio: 1, velocity: initial),
                          completionCriteria: .logicallyComplete) {
                offset = target
            } completion: {
                guard attempt == id else { return }
                didExit = true
                finishIfReady()
            }
        }
        Task {
            let confirmed = await archive()
            guard attempt == id else { return }
            if confirmed {
                didConfirm = true
                finishIfReady()
            } else {
                attempt = nil
                retain(id, false)
                settle(at: 0, velocity: 0)
            }
        }
    }

    private func finishIfReady() {
        guard didConfirm, didExit, let attempt else { return }
        // The model is already archived. End the hold after the row has cleared the list.
        if reduceMotion { retain(attempt, false) }
        else { withAnimation(.easeOut(duration: 0.16)) { retain(attempt, false) } }
    }
}

// Attach to the stationary list cell, rather than overlaying the SwiftUI Button or the scroll view.
// UIKit lets a vertical pan fail here before the List's own pan starts, and leaves taps untouched.
private struct AgentArchivePan: UIViewRepresentable {
    let enabled: Bool
    let revealed: Bool
    let onPan: (UIGestureRecognizer.State, CGFloat, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: Anchor, context: Context) {
        context.coordinator.config = self
        context.coordinator.attach(to: view)
    }

    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.detach() }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.attach(to: self)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var config: AgentArchivePan
        private weak var anchor: UIView?
        private weak var listPan: UIPanGestureRecognizer?
        private lazy var gesture: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = true
            return pan
        }()

        init(_ config: AgentArchivePan) { self.config = config }

        func attach(to view: UIView) {
            anchor = view
            var ancestor = view.superview
            var cell: UIView?
            while let parent = ancestor {
                if cell == nil, parent is UICollectionViewCell || parent is UITableViewCell { cell = parent }
                if let scroll = parent as? UIScrollView {
                    listPan = scroll.panGestureRecognizer
                    break
                }
                ancestor = parent.superview
            }
            if gesture.view !== cell {
                gesture.view?.removeGestureRecognizer(gesture)
                cell?.addGestureRecognizer(gesture)
            }
        }

        func detach() { gesture.view?.removeGestureRecognizer(gesture) }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            let velocity = gesture.velocity(in: anchor)
            return config.enabled && AgentArchiveKinematics.accepts(x: velocity.x, y: velocity.y, revealed: config.revealed)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other === listPan
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            guard let anchor, let cell = pan.view else { return }
            let rightEdge = cell.bounds.maxX - anchor.convert(anchor.bounds, to: cell).minX
            config.onPan(pan.state, pan.translation(in: anchor).x, pan.velocity(in: anchor).x,
                         max(anchor.bounds.width, rightEdge))
        }
    }
}

private struct AgentRow: View {
    let agent: IterateAgent
    var isArchiving = false
    /// Space at each side, inside the highlight, for a row that reaches the edges of the screen.
    var inset: CGFloat = 0
    let open: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                    if typeSize.isAccessibilitySize, let date = agent.lastActive { timestamp(date) }
                }
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize, let date = agent.lastActive { timestamp(date) }
                if isArchiving {
                    ProgressView().controlSize(.small).accessibilityLabel("Archiving")
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, inset)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        // The row draws its own background, which hides the list's highlight.
        .buttonStyle(RowPressFeedback())
        .accessibilityIdentifier("iterate.agent.row")
        #if DEBUG
        .onAppear { AgentLaunchTiming.mark("first row", finish: true) }
        #endif
    }

    private func timestamp(_ date: Date) -> some View {
        Text(verbatim: AgentActivityAge.compactLabel(for: date))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(Text(date, format: .relative(presentation: .named)))
    }
}

/// Says what a swipe just did, with the way back.
private struct ArchivedAgentNote: View {
    let name: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Archived \(name)").font(.subheadline.weight(.medium)).lineLimit(1)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .fixedSize()
                .tapTarget()
                .accessibilityHint("Puts the agent back in the list.")
                .accessibilityIdentifier("iterate.agent.undoArchive")
        }
        .padding(.leading, 16).padding(.trailing, 8)
        .modifier(FloatingNoteSurface())
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

enum AgentActivityAge {
    static func compactLabel(for date: Date, relativeTo now: Date = .now) -> String {
        let elapsed = now.timeIntervalSince(date)
        switch elapsed {
        case ..<60: return String(localized: "Now")
        case ..<3_600: return "\(Int(elapsed / 60))m"
        case ..<86_400: return "\(Int(elapsed / 3_600))h"
        default: return "\(Int(elapsed / 86_400))d"
        }
    }
}

#Preview("Agent rows") {
    NavigationStack {
        List {
            AgentRow(agent: .init(path: "/agents/assistant", name: "Personal assistant", lastActive: .now.addingTimeInterval(-20 * 60))) {}
            AgentRow(agent: .init(path: "/agents/travel", name: "Travel plans", lastActive: .now.addingTimeInterval(-15 * 3_600))) {}
            AgentRow(agent: .init(path: "/agents/reading", name: "Reading notes", lastActive: nil)) {}
        }.listStyle(.plain).navigationTitle("Agents")
            .safeAreaInset(edge: .bottom) { ArchivedAgentNote(name: "Travel plans") {} }
    }
}
