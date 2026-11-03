import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity: Lock Screen banner and Dynamic Island. Lives in Shared
/// so it's compiled (and checked) with the app too; the widget extension's
/// bundle is what shows it.
struct TrainActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainActivityAttributes.self) { context in
            TrainActivityLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
                .activitySystemActionForegroundColor(.trainTeal)
                .widgetURL(Self.url(for: context.attributes))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityEnd(crs: context.attributes.fromCrs, time: state.departureTime, late: state.isLate && !state.departed, cancelled: state.cancelled, alignment: .leading)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityEnd(crs: context.attributes.toCrs, time: state.arrivalTime, late: state.isLate && state.departed, cancelled: state.cancelled, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityStatusPill(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ActivityMiddle(state: state)
                        ActivityFooter(attributes: context.attributes, state: state, isStale: context.isStale)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                ActivityTrainIcon(state: state)
            } compactTrailing: {
                ActivityCompactTime(state: state)
            } minimal: {
                ActivityTrainIcon(state: state)
            }
            .keylineTint(.trainTeal)
            .widgetURL(Self.url(for: context.attributes))
        }
    }

    /// Tapping the activity opens its journey in the app.
    static func url(for attributes: TrainActivityAttributes) -> URL? {
        URL(string: "traintracker://journey/\(attributes.journeyId.uuidString.lowercased())")
    }
}
