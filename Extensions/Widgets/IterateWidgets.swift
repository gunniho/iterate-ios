import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

private struct TodayEntry: TimelineEntry { let date: Date }

private struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .init(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(.init(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        completion(.init(entries: [.init(date: .now)], policy: .never))
    }
}

private struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: Image(systemName: "waveform").accessibilityLabel("Open Iterate")
            case .accessoryInline, .accessoryRectangular: Label("Open Iterate", systemImage: "waveform")
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Iterate").font(.headline)
                    Button(intent: TalkToIterate()) { Label("Talk", systemImage: "waveform") }
                    Button(intent: CaptureWithIterate()) { Label("Capture", systemImage: "viewfinder") }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color(uiColor: .secondarySystemBackground) }
        .widgetURL(NativeDestination.talk.url)
    }
}

struct IterateTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Deployment.current.bundleID + ".today", provider: TodayProvider()) { _ in TodayWidgetView() }
            .configurationDisplayName("Iterate")
            .description("Talk to Iterate or capture something for your assistant.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@available(iOS 18, *)
struct IterateNewAgentControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Deployment.current.bundleID + ".control.new-agent") {
            ControlWidgetButton(action: StartNewIterateAgent()) {
                Label("New Agent", systemImage: "square.and.pencil")
            }
        }.displayName("New Agent").description("Open an empty Iterate conversation.")
    }
}

@available(iOS 18, *)
struct IterateTalkControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Deployment.current.bundleID + ".control.talk") {
            ControlWidgetButton(action: OpenIterateControl(.talk)) { Label("Talk to Iterate", systemImage: "waveform") }
        }.displayName("Talk to Iterate").description("Start a voice conversation.")
    }
}

@available(iOS 18, *)
struct IterateCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Deployment.current.bundleID + ".control.capture") {
            ControlWidgetButton(action: OpenIterateControl(.capture)) { Label("Capture with Iterate", systemImage: "bookmark") }
        }.displayName("Capture with Iterate").description("Save a thought or an item.")
    }
}

@available(iOS 26, *)
struct IterateAlarmActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<IterateAlarmMetadata>.self) { context in
            VStack(alignment: .leading) {
                Label(context.attributes.metadata?.name ?? "Iterate alarm", systemImage: "alarm")
                countdown(context.state)
            }.padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "alarm") }
                DynamicIslandExpandedRegion(.bottom) { countdown(context.state) }
            } compactLeading: { Image(systemName: "alarm") }
              compactTrailing: { countdown(context.state).frame(maxWidth: 54) }
              minimal: { Image(systemName: "alarm.fill") }
        }
    }
    @ViewBuilder private func countdown(_ state: AlarmPresentationState) -> some View {
        switch state.mode {
        case .countdown(let countdown): Text(timerInterval: countdown.startDate...max(countdown.startDate, countdown.fireDate), countsDown: true).monospacedDigit()
        case .paused: Text("Paused")
        case .alert: Text("Alarm")
        @unknown default: Text("Iterate")
        }
    }
}

@main
enum IterateWidgetExtension {
    @MainActor static func main() {
        if #available(iOS 18, *) { IterateWidgetBundle.main() }
        else { OriginalWidgetBundle.main() }
    }
}

private struct OriginalWidgetBundle: WidgetBundle {
    var body: some Widget {
        IterateTodayWidget()
    }
}

@available(iOS 18, *)
private struct IterateWidgetBundle: WidgetBundle {
    var body: some Widget {
        IterateTodayWidget()
        IterateNewAgentControl()
        IterateTalkControl()
        IterateCaptureControl()
        IterateCameraControl()
        if #available(iOS 26, *) { IterateAlarmActivity() }
    }
}
