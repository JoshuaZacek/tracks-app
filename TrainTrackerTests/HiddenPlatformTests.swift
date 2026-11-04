import Foundation
import Testing
@testable import TrainTracker

/// Platforms Darwin knows but the station hasn't announced (`hidden`), e.g.
/// 9G50 Euston, 3 Nov: platform 2 confirmed but kept off Euston's boards.
struct HiddenPlatformTests {
    private func decode<T: Decodable>(_ json: String, as: T.Type) throws -> T {
        try TracksClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test func decodesHiddenAndOlderCachedPlatforms() throws {
        let hidden = try decode(#"{"number":"2","source":"live","confirmed":true,"hidden":true}"#, as: Platform.self)
        #expect(hidden.hidden && hidden.confirmed)
        // Cached (SwiftData) before the server sent `hidden`.
        let old = try decode(#"{"number":"3","source":"live","confirmed":false}"#, as: Platform.self)
        #expect(!old.hidden)
        let summary = try decode(#"{"state":"live","platform":{"number":"3","source":"live","confirmed":false},"isCancelled":false,"stale":false}"#, as: LiveSummary.self)
        #expect(summary.platform?.hidden == false)
    }

    @Test func cardShowsTheHiddenPlatformNotTheBookedOne() {
        let journey = Journey.preview(from: ("EUS", "London Euston"), to: ("WVH", "Wolverhampton"), departs: "23:30", platform: "3")
        journey.live = LiveSummary(state: .live, platform: Platform(number: "2", source: .live, confirmed: true, hidden: true), isCancelled: false, stale: false)
        let model = JourneyCardModel(journey: journey)
        #expect(model.platform == "2")
        #expect(model.platformKind == .notAnnounced(changedFrom: "3"))
        #expect(model.platformKind.accessibilityNote.contains("not yet announced"))

        journey.live?.platform = Platform(number: "3", source: .live, confirmed: false, hidden: true)
        #expect(JourneyCardModel(journey: journey).platformKind == .notAnnounced(changedFrom: nil))
    }

    @Test func liveActivityPlatformHidden() throws {
        let state = #"{"state":"live","scheduledDeparture":"2026-11-03T23:30:00+00:00","scheduledArrival":"2026-11-04T01:10:00+00:00","isCancelled":false,"platform":{"number":"2","confirmed":true,"hidden":true}}"#
        let decoded = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: Data(state.utf8))
        #expect(decoded.platform == .init(number: "2", confirmed: true, hidden: true))
        // From a server (or app version) without the field.
        let older = #"{"state":"live","scheduledDeparture":"2026-11-03T23:30:00+00:00","scheduledArrival":"2026-11-04T01:10:00+00:00","isCancelled":false,"platform":{"number":"2","confirmed":false}}"#
        #expect(try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: Data(older.utf8)).platform?.hidden == false)
    }
}
