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
        #expect(!JourneyFilter.matches(j, query: "1a23")) // headcodes aren't searchable
        #expect(JourneyFilter.matches(j, query: "lner"))
        #expect(!JourneyFilter.matches(j, query: "leeds"))
        #expect(!JourneyFilter.matches(j, query: "york leeds"))

        // Operators by the short name passengers use, as well as in full.
        let tpe = journey("18:00")
        tpe.operatorCode = "TP"
        tpe.operatorName = "TransPennine Express"
        #expect(JourneyFilter.matches(tpe, query: "tpe"))
        #expect(JourneyFilter.matches(tpe, query: "transpennine"))
        #expect(!JourneyFilter.matches(tpe, query: "lner"))
    }

    @Test func filterByDateAndTime() {
        // Monday 2 November, 18:00; now is Monday 12:00.
        let j = journey("18:00")
        let tomorrowMorning = journey("07:15", date: "2026-11-03")
        func m(_ j: Journey, _ q: String) -> Bool { JourneyFilter.matches(j, query: q, now: now) }

        #expect(m(j, "today") && !m(j, "tomorrow") && !m(j, "yesterday"))
        #expect(m(tomorrowMorning, "tomorrow") && !m(tomorrowMorning, "today"))
        #expect(m(j, "tonight") && !m(tomorrowMorning, "tonight"))
        #expect(m(j, "evening") && !m(j, "morning") && !m(j, "afternoon"))
        #expect(m(tomorrowMorning, "morning"))
        #expect(m(j, "mon") && m(j, "Monday") && !m(j, "fri"))
        #expect(m(tomorrowMorning, "tue") && m(tomorrowMorning, "tuesday"))
        #expect(m(j, "nov") && m(j, "november") && !m(j, "dec"))
        #expect(m(j, "2 nov") && !m(j, "3 nov") && m(tomorrowMorning, "3 november"))
        #expect(m(j, "18:00") && m(j, "18:") && !m(j, "19:00"))
        #expect(m(tomorrowMorning, "7:15") && m(tomorrowMorning, "07:1"))
        // Mixed with stations.
        #expect(m(j, "york today") && !m(j, "york tomorrow"))
        #expect(!m(j, "leeds today"))
    }
}
