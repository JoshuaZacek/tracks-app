import SwiftUI
import Testing
@testable import TrainTracker

/// Renders journey cards (not started, under way, arrived) in light and dark
/// mode for a look (written to the temporary directory; the path is printed).
@MainActor
struct CardRenderTests {
    @Test func rendersTheRouteLineStates() throws {
        let now = Date.now
        let today = RailTime.ymd(now)
        func card(_ departsIn: TimeInterval, _ live: LiveSummary?) -> Journey {
            let j = Journey.preview(from: ("KGX", "London Kings Cross"), to: ("YRK", "York"), date: today, departs: RailTime.hhmm(now.addingTimeInterval(departsIn)), platform: "3")
            j.live = live
            return j
        }
        let journeys = [
            card(3 * 3600, nil),
            card(-40 * 60, LiveSummary(state: .departed, actualDeparture: now.addingTimeInterval(-40 * 60), isCancelled: false, stale: false)),
            card(-3 * 3600, LiveSummary(state: .arrived, actualDeparture: now.addingTimeInterval(-3 * 3600), actualArrival: now.addingTimeInterval(-60 * 60), isCancelled: false, stale: false)),
        ]
        let view = HStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(spacing: 12) {
                    ForEach(journeys) { JourneyCard(journey: $0, now: now) }
                    // As in the Past section.
                    JourneyCard(journey: journeys[2], now: now).completeStyle()
                    HStack {
                        PlatformBadge(number: "3")
                        PlatformBadge(number: "3", confirmed: true)
                    }
                }
                .padding(16)
                .background(Color(.systemGroupedBackground))
                .environment(\.colorScheme, scheme)
                .frame(width: 402)
            }
        }
        .tint(Color.trainTeal)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let url = URL.temporaryDirectory.appending(path: "cards.png")
        let image = try #require(renderer.uiImage)
        try #require(image.pngData()).write(to: url)
        print("Card render: \(url.path)")
    }
}
