import ActivityKit
import AlarmKit
import OSLog
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

// Leave time for WidgetKit to render even when the member socket stalls.
func fetchWidgetSnapshot<Value: Sendable>(_ fetch: @escaping @Sendable () async throws -> Value) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { tasks in
        tasks.addTask(operation: fetch)
        tasks.addTask {
            try await Task.sleep(for: .seconds(8))
            throw URLError(.timedOut)
        }
        defer { tasks.cancelAll() }
        guard let first = try await tasks.next() else { throw CancellationError() }
        return first
    }
}

struct YourMoveEntry: TimelineEntry, Sendable {
    let date: Date
    let state: YourMoveTimeline.State
}

private struct YourMoveProvider: TimelineProvider {
    private static let log = Logger(subsystem: Deployment.current.bundleID + ".widgets", category: "YourMove")

    func placeholder(in context: Context) -> YourMoveEntry {
        .init(date: .now, state: .ready(approvals: 1, questions: 2))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (YourMoveEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let now = Date.now
        let plan = YourMoveTimeline.recover(YourMoveSnapshotStore.load(), now: now)
        completion(.init(date: now, state: plan.state))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<YourMoveEntry>) -> Void) {
        Task {
            let plan = await refresh()
            var entries = [YourMoveEntry(date: .now, state: plan.state)]
            if let expiresAt = plan.expiresAt {
                entries.append(.init(date: expiresAt, state: .stale))
            }
            completion(Timeline(entries: entries, policy: .after(plan.retryAt)))
        }
    }

    private func refresh() async -> YourMoveTimeline {
        do {
            let snapshot = try await fetchWidgetSnapshot { try await YourMoveCounts.fetch() }
            return .live(snapshot, now: .now)
        } catch {
            let failure = error as NSError
            Self.log.notice("Summary refresh deferred: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            return .afterFailure(error, cached: YourMoveSnapshotStore.load(), now: .now)
        }
    }
}

struct YourMoveWidgetView: View {
    let entry: YourMoveEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if case .ready(0, 0) = entry.state {
                message("arrow.up.forward.app", "Open Iterate")
            } else {
                reviewCard.widgetURL(NativeDestination.yourMove.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .accessibilityElement(children: .combine)
        .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your move").font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 6)
            switch entry.state {
            case .ready(let approvals, let questions):
                Text((approvals + questions).formatted())
                    .font(.system(size: 51, weight: .medium, design: .rounded).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .foregroundStyle(colorScheme == .dark ? Color(red: 1, green: 0.73, blue: 0.46) :
                                        Color(red: 0.63, green: 0.31, blue: 0.10))
                    .widgetAccentable()
                    .accessibilityHidden(true)
                if approvals > 0 && questions > 0 {
                    Text(approvals == 1 ? "1 email to approve" : "\(approvals.formatted()) emails to approve")
                    Text(questions == 1 ? "1 question" : "\(questions.formatted()) questions")
                } else if approvals > 0 {
                    Text(approvals == 1 ? "Email to approve" : "Emails to approve")
                        .accessibilityLabel(approvals == 1 ? "1 email to approve" : "\(approvals.formatted()) emails to approve")
                } else {
                    Text(questions == 1 ? "Question to answer" : "Questions to answer")
                        .accessibilityLabel(questions == 1 ? "1 question to answer" : "\(questions) questions to answer")
                }
            case .unpaired: message("link", "Connect to Iterate")
            case .stale: message("arrow.clockwise", "Open to check")
            }
        }
        .font(.footnote.weight(.medium))
        .privacySensitive()
    }

    private func message(_ symbol: String, _ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct YourMoveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: IterateAppGroup.yourMoveWidgetKind, provider: YourMoveProvider()) { entry in
            YourMoveWidgetView(entry: entry)
        }
        .configurationDisplayName("Your move")
        .description("See approvals and questions waiting for you in Iterate.")
        .supportedFamilies([.systemSmall])
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
        YourMoveWidget()
    }
}

@available(iOS 18, *)
private struct IterateWidgetBundle: WidgetBundle {
    var body: some Widget {
        IterateTodayWidget()
        YourMoveWidget()
        if #available(iOS 27, *) { RecentAgentsWidget() }
        IterateNewAgentControl()
        IterateTalkControl()
        IterateCaptureControl()
        IterateCameraControl()
        if #available(iOS 26, *) { IterateAlarmActivity() }
    }
}
