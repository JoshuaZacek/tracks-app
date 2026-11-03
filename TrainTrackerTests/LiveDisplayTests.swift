import CoreLocation
import Foundation
import Testing
@testable import TrainTracker

/// The live parts of the Journeys screen and the detail screen, from real
/// Phase 4 responses (Fixtures/) and constructed live summaries.
@MainActor
struct LiveDisplayTests {
    // MARK: Card

    /// York 08:30 → King's Cross 10:30 on 3 Nov.
    private func journey(_ live: LiveSummary?) -> Journey {
        let j = Journey.preview(from: ("YRK", "York"), to: ("KGX", "London Kings Cross"), date: "2026-11-03", departs: "08:30", arrives: "10:30", platform: "3")
        j.live = live
        return j
    }

    private func at(_ hhmm: String) -> Date { RailTime.date("2026-11-03", at: hhmm)! }

    private func live(_ state: LiveState, dep: String? = nil, actualDep: String? = nil, arr: String? = nil, delay: Int? = nil, platform: Platform? = nil, cancelled: Bool = false, stale: Bool = false) -> LiveSummary {
        LiveSummary(state: state, expectedDeparture: dep.map(at), actualDeparture: actualDep.map(at), expectedArrival: arr.map(at), delayMinutes: delay, platform: platform, isCancelled: cancelled, stale: stale, checkedAt: at("09:00"))
    }

    @Test func underWayFillsTheBarAndCountsDownToArrival() {
        let m = JourneyCardModel(journey: journey(live(.departed, actualDep: "08:32", arr: "10:35", delay: 2)), now: at("09:52"))
        #expect(m.time == "08:32")
        #expect(m.timeTone == .late)
        #expect(m.status == "in 43 min")
        #expect(m.progress.map { abs($0 - 80.0 / 123.0) < 0.001 } == true)
    }

    @Test func longJourneysCountInHours() {
        let m = JourneyCardModel(journey: journey(live(.departed, actualDep: "08:30", arr: "10:30")), now: at("08:45"))
        #expect(m.status == "in 1 h 45 min")
        #expect(m.timeTone == .normal)
    }

    @Test func leavingSoonCountsDownToTheExpectedDeparture() {
        #expect(JourneyCardModel(journey: journey(live(.live, dep: "08:30")), now: at("08:18")).status == "leaves in 12 min")
        let late = JourneyCardModel(journey: journey(live(.live, dep: "08:41", delay: 11)), now: at("08:30"))
        #expect(late.status == "leaves in 11 min")
        #expect(late.statusTone == .late)
        #expect(late.time == "08:41")
        #expect(JourneyCardModel(journey: journey(nil), now: at("06:00")).status == nil) // too far off
    }

    @Test func cancelledArrivedAndStale() {
        let cancelled = JourneyCardModel(journey: journey(live(.cancelled, cancelled: true)), now: at("08:00"))
        #expect(cancelled.status == "Cancelled")
        #expect(cancelled.statusTone == .cancelled)
        #expect(cancelled.progress == nil)

        let arrived = JourneyCardModel(journey: journey(LiveSummary(state: .arrived, actualDeparture: at("08:30"), actualArrival: at("10:28"), isCancelled: false, stale: false)), now: at("10:40"))
        #expect(arrived.status == "Arrived 10:28")
        #expect(arrived.progress == 1)

        let stale = JourneyCardModel(journey: journey(live(.departed, actualDep: "08:30", stale: true)), now: at("09:00"))
        #expect(stale.staleNote == "Last updated 09:00")
    }

    @Test func platformBookedLiveOrChanged() {
        let booked = JourneyCardModel(journey: journey(nil))
        #expect(booked.platform == "3")
        #expect(booked.platformKind == .booked)

        let same = JourneyCardModel(journey: journey(live(.live, platform: Platform(number: "3", source: .live, confirmed: false))))
        #expect(same.platformKind == .live(confirmed: false))

        let changed = JourneyCardModel(journey: journey(live(.live, platform: Platform(number: "5A", source: .live, confirmed: true))))
        #expect(changed.platform == "5A")
        #expect(changed.platformKind == .changed(from: "3", confirmed: true))
    }

    // MARK: Real responses

    private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"))
        return try TracksClient.decoder.decode(T.self, from: Data(contentsOf: url))
    }

    @Test func decodesAJourneyAndItsLiveStatus() throws {
        let journey = try fixture("journey", as: ServerJourney.self)
        #expect(journey.from.crs == "KGX" && journey.to.crs == "YRK")
        let status = try fixture("live-departed", as: LiveStatus.self)
        #expect(status.state == .departed)
        #expect(status.nextPollSeconds == 30)
        #expect(status.position?.source == .darwin)
        #expect(status.position?.last.event == .pass)
        #expect(status.progress?.stops.first?.passed == true)
        let summary = LiveSummary(status)
        #expect(summary.state == .departed)
        #expect(summary.actualDeparture != nil)
        #expect(summary.expectedArrival == status.progress?.stops.last?.expected)
    }

    @Test func placesTheTrainOnItsLegByTime() throws {
        let journey = try fixture("journey", as: ServerJourney.self)
        let status = try fixture("live-departed", as: LiveStatus.self)
        let train = try fixture("train-live", as: TrainDetails.self)
        let position = try #require(status.position)
        let geometry = RouteGeometry(callingPoints: train.callingPoints, route: journey.route)

        let leg = try #require(geometry.leg(from: position.legFrom, to: position.legTo))
        // Left Stevenage 09:55, due at Grantham 10:37: at 10:17:23 it's 22.4 of 42 minutes along.
        let fraction = try #require(RouteGeometry.legFraction(leg: leg, liveCallingPoints: train.callingPoints, now: status.checkedAt))
        #expect(abs(fraction - 22.383 / 42) < 0.001)

        // On the route between Huntingdon and Peterborough (where Holme Junction is).
        let c = try #require(geometry.trainCoordinate(position, liveCallingPoints: train.callingPoints, now: status.checkedAt))
        #expect((52.33...52.58).contains(c.latitude), "\(c.latitude)")
        #expect((-0.26 ... -0.18).contains(c.longitude), "\(c.longitude)")

        // Not shown at Grantham until Darwin reports the arrival.
        let late = try #require(RouteGeometry.legFraction(leg: leg, liveCallingPoints: train.callingPoints, now: status.checkedAt.addingTimeInterval(3600)))
        #expect(late == 0.97)
    }

    @Test func pathRunsThroughPassedStations() throws {
        let journey = try fixture("journey", as: ServerJourney.self)
        let geometry = RouteGeometry(callingPoints: journey.callingPoints, route: journey.route)
        let path = geometry.path(from: journey.fromIndex, to: journey.toIndex)
        let passed = journey.route.filter { $0.leg < journey.toIndex }.count
        #expect(path.count == (journey.toIndex - journey.fromIndex + 1) + passed)
        #expect(path.first?.latitude == journey.callingPoints[journey.fromIndex].lat)
        #expect(path.last?.latitude == journey.callingPoints[journey.toIndex].lat)
    }
}

private final class BundleToken {}
