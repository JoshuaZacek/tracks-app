import SwiftUI
import WidgetKit

/// The widget extension: the journey Live Activity (Lock Screen and Dynamic
/// Island). Its views and attributes live in Shared/, compiled into the app too.
@main
struct TrainTrackerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TrainActivityWidget()
    }
}
