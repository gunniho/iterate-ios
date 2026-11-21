import SwiftUI

struct AgentsHome: View {
    let connection: MindConnection
    let isVisible: Bool
    let connect: () -> Void
    let open: (IterateAgent) -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let rows = connection.directory.rows, connection.hasSavedSession {
                List {
                    if rows.isEmpty {
                        ContentUnavailableView("No agents yet", systemImage: "bubble.left.and.bubble.right")
                            .listRowSeparator(.hidden)
                    }
                    ForEach(rows) { agent in
                        AgentRow(agent: agent) { open(agent) }
                    }
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
        .navigationTitle("Agents")
        .task(id: isVisible && scenePhase == .active ? connection.agentLink.map(ObjectIdentifier.init) : nil) {
            if isVisible, scenePhase == .active, let link = connection.agentLink {
                await connection.directory.refresh(on: link)
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
            Button("Try again") { Task { await refresh() } }.buttonStyle(.borderless)
        }
    }

    private func refresh() async {
        if let link = connection.agentLink { await connection.directory.refresh(on: link) }
        else if connection.hasSavedSession { connection.connect() }
        else { connect() }
    }
}

private struct AgentRow: View {
    let agent: IterateAgent
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
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("iterate.agent.row")
        #if DEBUG
        .onAppear { AgentLaunchTiming.mark("first row", finish: true) }
        #endif
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
    }
}

#Preview("Agent rows") {
    NavigationStack {
        List {
            AgentRow(agent: .init(path: "/agents/assistant", name: "Personal assistant", lastActive: .now)) {}
            AgentRow(agent: .init(path: "/agents/reading", name: "Reading notes", lastActive: nil)) {}
        }.listStyle(.plain).navigationTitle("Agents")
    }
}
