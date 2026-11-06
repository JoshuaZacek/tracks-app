import Foundation
import Testing
@testable import TrainTracker

/// When the stop alarm goes off (StopAlarmPlan), and the server's
/// `stop_alarm` background push and journey prefs.
struct StopAlarmTests {
    private let now = try! Date("2026-11-05T10:00:00+00:00", strategy: .iso8601)
    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func input(expected: Double? = nil, scheduled: Double = 60, enabled: Bool = true, arrived: Bool = false, cancelled: Bool = false) -> StopAlarmPlan.Input {
        StopAlarmPlan.Input(enabled: enabled, scheduledArrival: at(scheduled), expectedArrival: expected.map(at), arrived: arrived, cancelled: cancelled)
    }

    private func action(_ input: StopAlarmPlan.Input, lead: Int = 5, current: Double? = nil) -> StopAlarmPlan.Action {
        StopAlarmPlan.action(input, leadMinutes: lead, current: current.map(at), now: now)
    }

    @Test func goesOffLeadMinutesBeforeTheExpectedArrival() {
        #expect(action(input(expected: 72)) == .schedule(at(67)))
        #expect(action(input(expected: 72), lead: 15) == .schedule(at(57)))
        // No live time yet: the timetable's.
        #expect(action(input()) == .schedule(at(55)))
    }

    @Test func movesWhenTheArrivalMovesAndOnlyThen() {
        #expect(action(input(expected: 72), current: 55) == .schedule(at(67)))
        #expect(action(input(expected: 50), current: 55) == .schedule(at(45)))
        #expect(action(input(expected: 60), current: 55) == .leave)
        #expect(action(input(expected: 60.25), current: 55) == .leave) // under the tolerance
    }

    @Test func cancelledWhenOffArrivedOrCancelled() {
        #expect(action(input(enabled: false), current: 55) == .cancel)
        #expect(action(input(arrived: true), current: 55) == .cancel)
        #expect(action(input(cancelled: true), current: 55) == .cancel)
        // Due already (the train is at or past my stop).
        #expect(action(input(expected: -1), current: -6) == .cancel)
    }

    @Test func notSetWhenThereIsNoTimeLeft() {
        #expect(action(input(expected: 4)) == .cancel) // would have gone off a minute ago
        #expect(action(input(expected: 5.5)) == .cancel) // 30 s away
        #expect(action(input(expected: 6.5)) == .schedule(at(1.5)))
        // An alarm for later than now possible: dropped rather than going off after the stop.
        #expect(action(input(expected: 5.5), current: 10) == .cancel)
    }

    @Test func doesNotGoOffTwice() {
        // It went off two minutes ago; the train then slipped.
        #expect(action(input(expected: 10), current: -2) == .leave)
    }

    // MARK: Push and prefs

    @Test func parsesTheStopAlarmPush() throws {
        let id = UUID(uuidString: "af28be9d-180a-42b3-92ca-5825a3cb6428")!
        let json = #"{"aps":{"content-available":1},"journeyId":"af28be9d-180a-42b3-92ca-5825a3cb6428","kind":"stop_alarm","expectedArrival":"2026-11-05T11:07:00+00:00","cancelled":false}"#
        let payload = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let push = try #require(StopAlarmPush(userInfo: payload))
        #expect(push == StopAlarmPush(journeyID: id, expectedArrival: at(67), cancelled: false))

        let cancelled = #"{"aps":{"content-available":1},"journeyId":"af28be9d-180a-42b3-92ca-5825a3cb6428","kind":"stop_alarm","expectedArrival":null,"cancelled":true}"#
        let other = try #require(try JSONSerialization.jsonObject(with: Data(cancelled.utf8)) as? [AnyHashable: Any])
        #expect(StopAlarmPush(userInfo: other) == StopAlarmPush(journeyID: id, expectedArrival: nil, cancelled: true))

        // Summer time offsets parse too.
        let bst = #"{"journeyId":"af28be9d-180a-42b3-92ca-5825a3cb6428","kind":"stop_alarm","expectedArrival":"2026-07-01T09:05:00+01:00","cancelled":false}"#
        let summer = try #require(try JSONSerialization.jsonObject(with: Data(bst.utf8)) as? [AnyHashable: Any])
        #expect(StopAlarmPush(userInfo: summer)?.expectedArrival == (try Date("2026-07-01T08:05:00Z", strategy: .iso8601)))

        // Alerts aren't stop alarm pushes.
        #expect(StopAlarmPush(userInfo: ["journeyId": id.uuidString, "kind": "platform"]) == nil)
        #expect(StopAlarmPush(userInfo: ["kind": "stop_alarm"]) == nil)
    }

    @Test func pushUpdatesTheArrival() {
        let id = UUID()
        let base = input(expected: 60)
        #expect(base.updated(by: StopAlarmPush(journeyID: id, expectedArrival: at(80), cancelled: false)).expectedArrival == at(80))
        // Null: back to the timetable.
        let none = base.updated(by: StopAlarmPush(journeyID: id, expectedArrival: nil, cancelled: false))
        #expect(action(none) == .schedule(at(55)))
        #expect(action(base.updated(by: StopAlarmPush(journeyID: id, expectedArrival: nil, cancelled: true)), current: 55) == .cancel)
    }

    @Test func decodesStopAlarmInJourneyPrefs() throws {
        let on = try TracksClient.decoder.decode(JourneyPrefs.self, from: Data(#"{"delays":false,"stopAlarm":true}"#.utf8))
        #expect(on.stopAlarm == true)
        #expect(on.delays == false)
        // Absent (older servers, or never turned on) is off.
        #expect(try TracksClient.decoder.decode(JourneyPrefs.self, from: Data("{}".utf8)).stopAlarm == nil)
    }

    @Test func stopAlarmIsSentWithNullForOff() throws {
        func sent(_ prefs: JourneyPrefs) throws -> [String: Any] {
            let body = try JSONSerialization.jsonObject(with: TracksClient.encoder.encode(UpdateJourneyRequest(prefs: prefs.replacingAll))) as? [String: Any]
            return try #require(body?["prefs"] as? [String: Any])
        }
        #expect(try sent(JourneyPrefs(stopAlarm: true))["stopAlarm"] as? Bool == true)
        #expect(try sent(JourneyPrefs())["stopAlarm"] is NSNull)
        // Only set fields are sent in a hand-built update.
        let partial = try JSONSerialization.jsonObject(with: TracksClient.encoder.encode(JourneyPrefsUpdate(stopAlarm: .null))) as? [String: Any]
        #expect(partial?.keys.sorted() == ["stopAlarm"])
        #expect(partial?["stopAlarm"] is NSNull)
    }
}
