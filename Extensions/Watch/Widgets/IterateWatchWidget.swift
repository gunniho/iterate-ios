import SwiftUI
import WidgetKit

private struct WristEntry: TimelineEntry { let date: Date }

private struct WristTimeline: TimelineProvider {
    func placeholder(in context: Context) -> WristEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (WristEntry) -> Void) {
        completion(.init(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WristEntry>) -> Void) {
        completion(.init(entries: [.init(date: .now)], policy: .never))
    }
}

private struct WristWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: Image(systemName: "text.bubble")
            case .accessoryCorner: Image(systemName: "text.bubble").widgetLabel { Text("Ask Iterate") }
            default: Label("Ask Iterate", systemImage: "text.bubble")
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .accessibilityLabel("Ask Iterate")
    }
}

@main
struct IterateWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchOverviewCache.widget, provider: WristTimeline()) { _ in WristWidgetView() }
            .configurationDisplayName("Iterate")
            .description("Open Iterate to ask a question.")
            .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryCorner, .accessoryRectangular])
    }
}
