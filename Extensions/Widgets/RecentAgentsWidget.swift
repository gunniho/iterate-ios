import SwiftUI
import WidgetKit

struct RecentAgentsEntry: TimelineEntry, Sendable {
    let date: Date
    let state: RecentAgentsTimeline.State
}

private struct RecentAgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentAgentsEntry {
        let now = Date.now
        let titles = ["Daily briefing", "Calendar", "Reading list", "Travel plans", "Meeting notes", "Research"]
        let agents = titles.enumerated().map { index, title in
            IterateAgent(path: "/agents/preview-\(index)", name: title,
                        lastActive: now.addingTimeInterval(-Double(index + 1) * 3600))
        }
        return .init(date: now, state: .list(.init(rows: agents, checkedAt: now)))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (RecentAgentsEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let now = Date.now
        let plan = RecentAgentsTimeline.cached(RecentAgentsSnapshotStore.load(), now: now)
        completion(.init(date: now, state: plan.state))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RecentAgentsEntry>) -> Void) {
        Task {
            let plan: RecentAgentsTimeline
            do {
                let snapshot = try await fetchWidgetSnapshot { try await AssistantCenter.shared.recentAgentsSnapshot() }
                plan = .live(snapshot, now: .now)
            } catch {
                plan = .afterFailure(error, cached: RecentAgentsSnapshotStore.load(), now: .now)
            }
            let entry = RecentAgentsEntry(date: .now, state: plan.state)
            completion(Timeline(entries: [entry], policy: .after(plan.retryAt)))
        }
    }
}

@available(iOS 27, *)
struct RecentAgentsWidgetView: View {
    let entry: RecentAgentsEntry
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Iterate").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Link(destination: NativeDestination.agents.url) {
                    HStack(spacing: 4) {
                        if !typeSize.isAccessibilitySize { Text("All agents") }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                }
                .accessibilityLabel("All agents")
            }
            switch entry.state {
            case .list(let snapshot) where !snapshot.rows.isEmpty:
                GeometryReader { geometry in
                    let height = max(44, rowHeight) * (typeSize.isAccessibilitySize ? 1.45 : 1)
                    let capacity = max(1, Int(geometry.size.height / height))
                    let rows = snapshot.rows.prefix(capacity)
                    VStack(spacing: 0) {
                        ForEach(rows) { agent in
                            if let url = agent.widgetURL {
                                Link(destination: url) {
                                    row(for: agent)
                                        .frame(height: height)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .overlay(alignment: .bottom) {
                                    if agent.id != rows.last?.id { Divider() }
                                }
                            }
                        }
                    }
                }
                .privacySensitive()
            case .list:
                message("No recent agents", symbol: "bubble.left.and.bubble.right")
            case .unpaired:
                message("Open Iterate to connect", symbol: "link")
            case .unavailable:
                message("Waiting to refresh", symbol: "arrow.clockwise")
            }
            if case .list(let snapshot) = entry.state {
                Text("Updated \(snapshot.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .widgetURL(NativeDestination.agents.url)
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }

    @ViewBuilder private func row(for agent: IterateAgent) -> some View {
        let title = Text(verbatim: agent.name)
            .font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                title
                if let date = agent.lastActive { timestamp(date) }
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 10) {
                title
                Spacer(minLength: 0)
                if let date = agent.lastActive { timestamp(date).fixedSize(horizontal: true, vertical: false) }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private func message(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@available(iOS 27, *)
struct RecentAgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: IterateAppGroup.recentAgentsWidgetKind, provider: RecentAgentsProvider()) { entry in
            RecentAgentsWidgetView(entry: entry)
        }
        .configurationDisplayName("Iterate")
        .description("See agents by recent activity and open their conversations.")
        .supportedFamilies([.systemExtraLargePortrait])
    }
}
