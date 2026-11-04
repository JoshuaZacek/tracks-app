import SwiftUI
import Testing
@testable import TrainTracker

/// Renders the journey screen's stop list for a real train under way (1N04,
/// from the fixtures) in light and dark mode, for a look.
@MainActor
struct StopListRenderTests {
    private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle(for: StopListBundleToken.self).url(forResource: name, withExtension: "json"))
        return try TracksClient.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    @Test func rendersTheTrackUpToTheTrain() throws {
        let journey = Journey(try fixture("journey", as: ServerJourney.self))
        let train = try fixture("train-live", as: TrainDetails.self)
        let status = try fixture("live-departed", as: LiveStatus.self)
        let now = status.checkedAt
        let rows = StopRow.rows(for: journey, liveCallingPoints: train.callingPoints, now: now)
        let reached = rows.lastIndex { row in row.passed }
        let last = try #require(reached)
        let fraction = RouteGeometry.legFraction(leg: rows[last].id, liveCallingPoints: train.callingPoints, now: now)
        #expect(fraction != nil)
        let indicator = StopList.Indicator(place: "Owl End, near Huntingdon", report: "Passed Huntingdon 10:16", next: "Peterborough in 4 min")
        let view = HStack(alignment: .top, spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                StopList(rows: rows, indicator: indicator, trainFraction: fraction)
                    .padding(16)
                    .background(Color(.systemGroupedBackground))
                    .environment(\.colorScheme, scheme)
                    .frame(width: 402)
            }
        }
        .tint(Color.trainTeal)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        let url = URL.temporaryDirectory.appending(path: "stops.png")
        try #require(image.pngData()).write(to: url)
        print("Stops render: \(url.path)")
    }
}

private final class StopListBundleToken {}
