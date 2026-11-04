import Foundation
import Testing
@testable import TrainTracker

struct RailTimeTests {
    /// Monday 2 November 2026, 10:00 UK time (GMT).
    let now = RailTime.date("2026-11-02", at: "10:00")!

    @Test func ukWallClockEitherSideOfTheClocksGoingBack() {
        // British Summer Time ended on Sunday 25 October 2026.
        #expect(RailTime.date("2026-10-24", at: "12:00")! == ISO8601DateFormatter().date(from: "2026-10-24T11:00:00Z")!)
        #expect(RailTime.date("2026-10-26", at: "12:00")! == ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!)
        // Adding a day across the change keeps the wall-clock time.
        #expect(RailTime.hhmm(RailTime.date("2026-10-24", plusDays: 2, at: "12:00")!) == "12:00")
    }

    @Test func roundTrips() {
        let d = RailTime.date("2026-11-02", plusDays: 1, at: "00:15")!
        #expect(RailTime.ymd(d) == "2026-11-03")
        #expect(RailTime.hhmm(d) == "00:15")
    }

    @Test(arguments: [
        ("2026-11-02", "23:59", "Today"),
        ("2026-11-03", "00:15", "Tomorrow"),
        ("2026-11-05", "13:31", "Thu Nov 5"),
        ("2026-11-08", "09:30", "Sun Nov 8"),
        ("2026-11-09", "09:30", "Mon Nov 9"),
        ("2026-11-01", "18:00", "Yesterday"),
        ("2026-10-30", "18:00", "Fri Oct 30"),
    ])
    func dayLabels(ymd: String, hhmm: String, expected: String) {
        #expect(RailTime.dayLabel(for: RailTime.date(ymd, at: hhmm)!, now: now) == expected)
    }

    @Test func dayLabelsUseUKDatesLateInTheEvening() {
        // 23:30 on Monday: a 00:15 departure is tomorrow, not today.
        let lateEvening = RailTime.date("2026-11-02", at: "23:30")!
        #expect(RailTime.dayLabel(for: RailTime.date("2026-11-03", at: "00:15")!, now: lateEvening) == "Tomorrow")
    }
}

struct DistanceTextTests {
    @Test(arguments: [(126, "140 yd"), (805, "0.5 mi"), (1450, "0.9 mi"), (19_312, "12 mi")])
    func ukRoadUnits(meters: Int, expected: String) {
        #expect(StationPicker.distanceText(meters) == expected)
    }
}
