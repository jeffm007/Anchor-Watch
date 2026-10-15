import ActivityKit
import SwiftUI
import WidgetKit

@main
struct AnchorWatchWidgetBundle: WidgetBundle {
    var body: some Widget { AnchorLiveActivity() }
}

private extension AnchorWatchAttributes.Status {
    var color: Color {
        switch self {
        case .holding: return .green
        case .caution: return .orange
        case .alarm: return .red
        }
    }
}

struct AnchorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AnchorWatchAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.isStale ? "⚠️" : "⚓").font(.title) }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.isStale ? "Stale" : context.state.distanceText)
                        .font(.system(.title2, design: .rounded).bold())
                        .foregroundStyle(context.isStale ? Color.orange : context.state.status.color)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.isStale ? "Monitoring status stale — open Anchor Watch" : context.state.headline).font(.caption).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        ProgressView(value: min(context.state.fraction, 1)).tint(context.state.status.color)
                        Text("Alarm circle \(context.state.radiusText)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text(context.isStale ? "⚠️" : "⚓")
            } compactTrailing: {
                Text(context.isStale ? "Stale" : context.state.distanceText)
                    .font(.caption.bold())
                    .foregroundStyle(context.isStale ? Color.orange : context.state.status.color)
            } minimal: {
                Text(context.isStale ? "⚠️" : "⚓")
            }
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<AnchorWatchAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(context.isStale ? "⚠️" : "⚓").font(.title3)
                Text(context.attributes.boatName).font(.headline)
                Spacer()
                Circle().fill(context.isStale ? Color.orange : state.status.color).frame(width: 12, height: 12)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(context.isStale ? "--" : state.distanceText).font(.system(size: 34, weight: .bold, design: .rounded))
                Text("from anchor").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("circle \(state.radiusText)").font(.caption)
            }
            ProgressView(value: min(state.fraction, 1)).tint(state.status.color)
            Text(context.isStale ? "Monitoring status stale" : state.headline).font(.footnote.bold())
            if context.isStale {
                Text("Not updating. Open Anchor Watch.").font(.footnote.bold()).foregroundStyle(.red)
            } else {
                Text("Updated \(Text(state.updated, style: .relative)) ago").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding()
        .activityBackgroundTint(state.status == .alarm ? Color.red.opacity(0.35) : nil)
    }
}
