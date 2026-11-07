import SwiftUI
import Testing
@testable import TrainTracker

/// Renders the Live Activity's Lock Screen view for a look before it's on a
/// device (written to the temporary directory; the path is printed).
@MainActor
struct ActivityRenderTests {
    @Test func rendersTheLockScreenStates() throws {
        let attributes = TrainActivityAttributes(journeyId: UUID(), headcode: "1H03", operatorName: "London North Eastern Railway", fromCrs: "KGX", fromName: "London Kings Cross", toCrs: "GRA", toName: "Grantham")
        let now = Date.now
        let states: [(String, TrainActivityAttributes.ContentState)] = [
            ("before", .init(state: .live, scheduledDeparture: now.addingTimeInterval(20 * 60), expectedDeparture: now.addingTimeInterval(25 * 60), scheduledArrival: now.addingTimeInterval(80 * 60), delayMinutes: 5, platform: .init(number: "7", confirmed: true))),
            ("departed", .init(state: .departed, scheduledDeparture: now.addingTimeInterval(-20 * 60), actualDeparture: now.addingTimeInterval(-20 * 60), scheduledArrival: now.addingTimeInterval(40 * 60), platform: .init(number: "1", confirmed: false), nextStopName: "Peterborough", legDepartedAt: now.addingTimeInterval(-20 * 60), nextExpectedAt: now.addingTimeInterval(15 * 60))),
            ("cancelled", .init(state: .cancelled, scheduledDeparture: now.addingTimeInterval(20 * 60), scheduledArrival: now.addingTimeInterval(80 * 60), isCancelled: true)),
            ("divides", .init(state: .departed, scheduledDeparture: now.addingTimeInterval(-20 * 60), actualDeparture: now.addingTimeInterval(-20 * 60), scheduledArrival: now.addingTimeInterval(40 * 60), platform: .init(number: "1", confirmed: false), nextStopName: "Peterborough", legDepartedAt: now.addingTimeInterval(-20 * 60), nextExpectedAt: now.addingTimeInterval(15 * 60), divides: "Divides at Peterborough · front 4 coaches")),
            ("arrived", .init(state: .arrived, scheduledDeparture: now.addingTimeInterval(-80 * 60), actualDeparture: now.addingTimeInterval(-80 * 60), scheduledArrival: now.addingTimeInterval(-5 * 60), actualArrival: now.addingTimeInterval(-2 * 60), delayMinutes: 3, platform: .init(number: "2", confirmed: true))),
        ]
        let view = VStack(spacing: 12) {
            ForEach(states, id: \.0) { _, state in
                TrainActivityLockScreenView(attributes: attributes, state: state)
                    .background(Color(.systemBackground).opacity(0.85), in: .rect(cornerRadius: 22))
            }
        }
        .padding(12)
        .frame(width: 370)
        .background(Color.gray)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let url = URL.temporaryDirectory.appending(path: "live-activity.png")
        try #require(image.pngData()).write(to: url)
        print("Live Activity render: \(url.path)")
    }
}
