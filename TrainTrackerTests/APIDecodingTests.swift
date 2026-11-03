import Foundation
import Testing
@testable import TrainTracker

/// Decodes real tracks server responses captured into Fixtures/.
struct APIDecodingTests {
    private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"))
        return try TracksClient.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    @Test func departures() throws {
        let r = try fixture("departures", as: DeparturesResponse.self)
        #expect(r.from.crs == "KGX")
        #expect(r.to?.crs == "YRK")
        #expect(r.nextCursor != nil)
        let first = try #require(r.departures.first)
        #expect(RailTime.hhmm(first.scheduledDeparture) == "17:00")
        #expect(first.arrival?.station.crs == "YRK")
        #expect(first.operator.name == "Grand Central")
        #expect(first.live == nil)
    }

    @Test func trainWithRoute() throws {
        let t = try fixture("train", as: TrainDetails.self)
        #expect(t.callingPoints.first?.crs == "KGX")
        #expect(t.callingPoints.first?.scheduledArrival == nil)
        #expect(t.callingPoints.last?.scheduledDeparture == nil)
        #expect(t.route.count == 19)
        #expect(t.route.allSatisfy { $0.f > 0 && $0.f < 1 && $0.leg < t.callingPoints.count - 1 })
    }

    @Test func journeyFromTrainDetails() throws {
        let t = try fixture("train", as: TrainDetails.self)
        let j = Journey(date: t.runDate, train: t, fromIndex: 0, toIndex: 4)
        #expect(j.from.crs == "KGX")
        #expect(j.to.crs == "YRK")
        #expect(RailTime.hhmm(j.departsAt) == "17:03")
        #expect(RailTime.hhmm(j.arrivesAt) == "19:03")
        #expect(j.intermediateStops == 3)
    }

    @Test func liveSummaryAndErrors() throws {
        let summary = try TracksClient.decoder.decode(LiveSummary.self, from: Data("""
        {"state":"not_found","expectedDeparture":null,"actualDeparture":null,"expectedArrival":"2026-11-03T19:05:00+00:00",
         "actualArrival":null,"delayMinutes":2,"platform":{"number":"5A","source":"live","confirmed":true},
         "isCancelled":false,"stale":false,"checkedAt":"2026-11-03T18:00:00+00:00"}
        """.utf8))
        #expect(summary.state == .notFound)
        #expect(summary.platform?.confirmed == true)
        let error = try TracksClient.decoder.decode(TracksErrorBody.self, from: Data(#"{"error":{"code":"something_new","message":"x"}}"#.utf8))
        #expect(error.error.code == .unknown)
    }
}

private final class BundleToken {}
