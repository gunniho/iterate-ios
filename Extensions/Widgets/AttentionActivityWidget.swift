import ActivityKit
import SwiftUI
import WidgetKit

/// The amber of the Your move widget's count. The Dynamic Island is always dark.
private func attentionTint(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(red: 1, green: 0.73, blue: 0.46) : Color(red: 0.63, green: 0.31, blue: 0.10)
}

/// Every kind that waits, in one line of counts. Where the words do not fit, the symbols and counts do.
private struct AttentionKinds: View {
    let state: IterateAttentionAttributes.ContentState

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row { kind in Label(kind.label(state.count(of: kind)), systemImage: kind.symbol) }
            row { kind in Label(state.count(of: kind).formatted(), systemImage: kind.symbol) }
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    private func row(@ViewBuilder _ item: @escaping (AttentionKind) -> some View) -> some View {
        HStack(spacing: 10) {
            ForEach(state.kinds, id: \.self) { kind in item(kind).fixedSize() }
        }
    }
}

/// What waits, in its own words: one line for each of the first `limit` things. A content with
/// no words, from a mind that sends none, is told by its counts.
private struct AttentionItems: View {
    let state: IterateAttentionAttributes.ContentState
    let limit: Int
    let tint: Color

    private var shown: [IterateAttentionAttributes.Item] { Array(state.items.prefix(limit)) }
    /// How many things wait beyond the lines shown here.
    var more: Int { max(0, state.total - shown.count) }

    var body: some View {
        if shown.isEmpty {
            AttentionKinds(state: state)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.attentionKind?.symbol ?? "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(tint)
                            .frame(width: 14)
                        Text(verbatim: item.text).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
        }
    }
}

struct AttentionLockScreenView: View {
    let state: IterateAttentionAttributes.ContentState
    let isStale: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let items = AttentionItems(state: state, limit: IterateAttentionAttributes.ContentState.mostItems, tint: attentionTint(colorScheme))
        HStack(alignment: .top, spacing: 14) {
            if state.total > 0 {
                Text(state.total.formatted())
                    .font(.system(size: 40, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(attentionTint(colorScheme))
                    .contentTransition(.numericText())
                    .frame(minWidth: 36)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Your move").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if state.total == 0 {
                    Text("You’re all caught up").font(.footnote).foregroundStyle(.secondary)
                } else {
                    items.font(.footnote.weight(.medium))
                    footer(more: state.items.isEmpty ? 0 : items.more)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isStale ? "Open Iterate to check what is waiting for you" : state.spoken)
    }

    /// How many more wait, and for how long the oldest has. The clock runs on the Lock Screen with no push.
    @ViewBuilder private func footer(more: Int) -> some View {
        if isStale {
            Text("Open Iterate to check")
        } else if let since = state.waitingSince {
            if more > 0 { Text("+\(more) more · Waiting \(Text(since, style: .relative))") }
            else { Text("Waiting \(Text(since, style: .relative))") }
        } else if more > 0 {
            Text("+\(more) more")
        }
    }
}

struct IterateAttentionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IterateAttentionAttributes.self) { context in
            AttentionLockScreenView(state: context.state, isStale: context.isStale)
                .widgetURL(NativeDestination.yourMove.url)
        } dynamicIsland: { context in
            let state = context.state
            let tint = attentionTint(.dark)
            // The island has room for two things in words.
            let items = AttentionItems(state: state, limit: 2, tint: tint)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.leading?.symbol ?? "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.total.formatted())
                        .font(.system(.title, design: .rounded, weight: .medium).monospacedDigit())
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Your move").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.total == 0 {
                        Text("You’re all caught up").font(.footnote).foregroundStyle(.secondary)
                    } else if context.isStale {
                        Text("Open Iterate to check").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            items.font(.footnote.weight(.medium))
                            if !state.items.isEmpty, items.more > 0 {
                                Text("+\(items.more) more").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: state.items.isEmpty ? .center : .leading)
                        .padding(.horizontal, 6)
                    }
                }
            } compactLeading: {
                Image(systemName: state.leading?.symbol ?? "checkmark.circle").foregroundStyle(tint)
            } compactTrailing: {
                Text(state.total.formatted())
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            } minimal: {
                Text(state.total.formatted())
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            .widgetURL(NativeDestination.yourMove.url)
            .keylineTint(tint)
        }
    }
}
