import Foundation
import Testing
@testable import TrainTracker

@MainActor
struct JourneySectionsTests {
    /// Monday 2 November 2026, 12:00 UK time.
    let now = RailTime.date("2026-11-02", at: "12:00")!
    let today = "2026-11-02"

    private func journey(_ departs: String, arrives: String? = nil, date: String = "2026-11-02", from: (String, String) = ("YRK", "York"), to: (String, String) = ("KGX", "London Kings Cross")) -> Journey {
        Journey.preview(from: from, to: to, date: date, departs: departs, arrives: arrives)
    }

    private func status(_ state: LiveState, cancelled: Bool = false) -> LiveSummary {
        LiveSummary(state: state, isCancelled: cancelled, stale: false)
    }

    @Test func byTimetableAlone() {
        #expect(JourneySections.section(of: journey("11:00", arrives: "13:00"), status: nil, now: now) == .live) // under way
        #expect(JourneySections.section(of: journey("12:45"), status: nil, now: now) == .live) // leaving within the hour
        #expect(JourneySections.section(of: journey("13:30"), status: nil, now: now) == .upcoming)
        #expect(JourneySections.section(of: journey("08:00", arrives: "10:00"), status: nil, now: now) == .past)
    }

    @Test func liveDataKeepsALateTrainOutOfPast() {
        let late = journey("08:00", arrives: "10:00")
        #expect(JourneySections.section(of: late, status: status(.departed), now: now) == .live)
        #expect(JourneySections.section(of: late, status: status(.live), now: now) == .live) // not even left yet
        #expect(JourneySections.section(of: late, status: status(.arrived), now: now) == .past)
        #expect(JourneySections.section(of: late, status: status(.cancelled, cancelled: true), now: now) == .past)
    }

    @Test func archivedIsPast() {
        let j = journey("13:30")
        j.archivedAt = now
        #expect(JourneySections.section(of: j, status: nil, now: now) == .past)
    }

    @Test func arrivedEarlyIsPast() {
        #expect(JourneySections.section(of: journey("11:00", arrives: "13:00"), status: status(.arrived), now: now) == .past)
    }

    @Test func liveDayHeadingsOnlyWhenATripCrossesMidnight() {
        // Two trips under way, both today: no headings.
        #expect(!JourneySections(journeys: [journey("11:00", arrives: "13:00"), journey("12:30")], now: now).liveShowsDays)
        // Departed yesterday at 23:00, still running after midnight.
        let lateNight = RailTime.date("2026-11-02", at: "00:20")!
        #expect(JourneySections(journeys: [journey("23:00", arrives: "01:00", date: "2026-11-01")], now: lateNight).liveShowsDays)
        // Leaves today, arrives tomorrow.
        let evening = RailTime.date("2026-11-02", at: "22:30")!
        #expect(JourneySections(journeys: [journey("22:00", arrives: "06:00")], now: evening).liveShowsDays)
        // Leaving soon, but after midnight.
        let nearMidnight = RailTime.date("2026-11-02", at: "23:40")!
        #expect(JourneySections(journeys: [journey("00:10", date: "2026-11-03")], now: nearMidnight).liveShowsDays)
    }

    @Test func groupsByDayInOrder() {
        let sections = JourneySections(
            journeys: [
                journey("18:00"),
                journey("07:15", date: "2026-11-03"),
                journey("13:31", date: "2026-11-06"),
                journey("19:02", date: "2026-11-06"),
                journey("06:00", arrives: "07:00"),
                journey("09:00", arrives: "10:00"),
            ],
            now: now
        )
        #expect(sections.upcoming.map(\.label) == ["Today", "Tomorrow", "Fri Nov 6"])
        #expect(sections.upcoming.last?.journeys.map { RailTime.hhmm($0.departsAt) } == ["13:31", "19:02"])
        // Past: most recent first.
        #expect(sections.past.first?.journeys.map { RailTime.hhmm($0.departsAt) } == ["09:00", "06:00"])
        #expect(sections.live.isEmpty)
    }

    @Test func filter() {
        let j = journey("18:00")
        #expect(JourneyFilter.matches(j, query: ""))
        #expect(JourneyFilter.matches(j, query: "york"))
        #expect(JourneyFilter.matches(j, query: "KGX"))
        #expect(JourneyFilter.matches(j, query: "york kings"))
        #expect(JourneyFilter.matches(j, query: "1a23"))
        #expect(JourneyFilter.matches(j, query: "lner"))
        #expect(!JourneyFilter.matches(j, query: "leeds"))
        #expect(!JourneyFilter.matches(j, query: "york leeds"))
    }
}
