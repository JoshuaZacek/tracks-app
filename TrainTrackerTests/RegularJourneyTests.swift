import Foundation
import Testing
@testable import TrainTracker

/// Sprint 1 (regular journeys, morning summary, leave now): the server's new
/// JSON (and old servers' JSON without it), the bodies the app sends, and the
/// days, times and travel-time logic behind the screens.
struct RegularJourneyTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TracksClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encode(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: TracksClient.encoder.encode(value)) as? [String: Any])
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle(for: RegularBundleToken.self).url(forResource: name, withExtension: "json"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: Decoding

    @Test func decodesATemplate() throws {
        let t = try decode(JourneyTemplate.self, """
        {"id":"0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10",
         "from":{"crs":"LBG","name":"London Bridge","lat":51.505,"lon":-0.086},
         "to":{"crs":"BTN","name":"Brighton","lat":50.829,"lon":-0.141},
         "departTime":"07:42","days":[1,2,3,4,5],"trainUid":"W12345","travelMinutes":15,"summaryTime":"06:40",
         "prefs":{"delays":false,"stopAlarm":true,"leaveNow":false},
         "problem":{"date":"2026-11-10","message":"Couldn't find your 07:42 London Bridge → Brighton on Tuesday."},
         "nextJourney":{"id":"af28be9d-180a-42b3-92ca-5825a3cb6428","date":"2026-11-09","scheduledDeparture":"2026-11-09T07:42:00+00:00"},
         "createdAt":"2026-11-06T12:00:00+00:00"}
        """)
        #expect(t.from.crs == "LBG")
        #expect(t.days == [1, 2, 3, 4, 5])
        #expect(t.travelMinutes == 15)
        #expect(t.summaryTime == "06:40")
        #expect(t.prefs == JourneyPrefs(delays: false, stopAlarm: true, leaveNow: false))
        #expect(t.problem?.date == "2026-11-10")
        #expect(t.nextJourney?.id == UUID(uuidString: "af28be9d-180a-42b3-92ca-5825a3cb6428"))
        #expect(RailTime.hhmm(try #require(t.nextJourney?.scheduledDeparture)) == "07:42")
        #expect(t.title == "07:42 London Bridge → Brighton")
        #expect(t.summaryLine == "Weekdays · 15 min to the station · Summary at 06:40")
    }

    @Test func decodesATemplateWithNulls() throws {
        let list = try decode(JourneyTemplateList.self, """
        {"templates":[{"id":"0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10",
         "from":{"crs":"YRK","name":"York","lat":null,"lon":null},"to":{"crs":"KGX","name":"London Kings Cross"},
         "departTime":"18:00","days":[6],"trainUid":null,"travelMinutes":null,"summaryTime":null,
         "prefs":{},"problem":null,"nextJourney":null,"createdAt":"2026-11-06T12:00:00Z"}]}
        """)
        let t = try #require(list.templates.first)
        #expect(t.trainUid == nil)
        #expect(t.travelMinutes == nil)
        #expect(t.summaryTime == nil)
        #expect(t.problem == nil)
        #expect(t.nextJourney == nil)
        #expect(t.prefs == JourneyPrefs())
        #expect(t.summaryLine == "Saturdays")
    }

    @Test func journeysWithAndWithoutATemplate() throws {
        // An old server's journey: no templateId or travelMinutes.
        var json = try fixture("journey")
        let old = try TracksClient.decoder.decode(ServerJourney.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.templateId == nil)
        #expect(old.travelMinutes == nil)
        #expect(Journey(old).templateId == nil)

        json["templateId"] = "0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10"
        json["travelMinutes"] = 12
        let new = try TracksClient.decoder.decode(ServerJourney.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(new.templateId == UUID(uuidString: "0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10"))
        #expect(new.travelMinutes == 12)
        let journey = Journey(new)
        #expect(journey.templateId == new.templateId)
        #expect(journey.travelMinutes == 12)

        // Nulls, as the server sends for a one-off journey.
        json["templateId"] = NSNull()
        json["travelMinutes"] = NSNull()
        let none = try TracksClient.decoder.decode(ServerJourney.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(none.templateId == nil)
        #expect(none.travelMinutes == nil)
    }

    @Test func listItemsCarryTheTemplate() throws {
        let item = try decode(JourneyListItem.self, """
        {"id":"af28be9d-180a-42b3-92ca-5825a3cb6428","trainUid":"W12345","runDate":"2026-11-09","date":"2026-11-09",
         "headcode":"1A23","operator":{"code":"SN","name":"Southern"},
         "from":{"crs":"LBG","name":"London Bridge"},"to":{"crs":"BTN","name":"Brighton"},
         "scheduledDeparture":"2026-11-09T07:42:00+00:00","scheduledArrival":"2026-11-09T08:45:00+00:00",
         "bookedPlatform":"4","prefs":{"morningSummary":false},"templateId":"0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10","travelMinutes":15,
         "createdAt":"2026-11-08T03:00:00+00:00","archivedAt":null,
         "live":{"state":"scheduled","isCancelled":false,"stale":false}}
        """)
        #expect(item.templateId != nil)
        #expect(item.travelMinutes == 15)
        #expect(item.prefs.morningSummary == false)
        #expect(item.prefs.leaveNow == nil)
    }

    @Test func devicePrefsFromOldAndNewServers() throws {
        let old = try decode(NotificationPrefs.self, #"{"delays":true,"platforms":false,"cancellations":true,"departure":true,"arrival":false,"delayThresholdMinutes":7,"liveActivity":true}"#)
        #expect(old.morningSummary)
        #expect(old.leaveNow)
        #expect(!old.platforms)
        #expect(old.delayThresholdMinutes == 7)

        let new = try decode(NotificationPrefs.self, #"{"delays":true,"platforms":true,"cancellations":true,"departure":true,"arrival":true,"delayThresholdMinutes":5,"liveActivity":true,"morningSummary":false,"leaveNow":false}"#)
        #expect(!new.morningSummary)
        #expect(!new.leaveNow)

        // Sent back whole from Settings, the new keys included.
        let body = try encode(UpdateDeviceRequest(prefs: new))
        let prefs = try #require(body["prefs"] as? [String: Any])
        #expect(prefs["morningSummary"] as? Bool == false)
        #expect(prefs["leaveNow"] as? Bool == false)
        #expect(NotificationPrefs.defaults.morningSummary && NotificationPrefs.defaults.leaveNow)
    }

    @Test func journeyOverridesApplyOverTheDevice() {
        let device = NotificationPrefs(delays: true, platforms: true, cancellations: true, departure: true, arrival: true, delayThresholdMinutes: 5, liveActivity: true, morningSummary: true, leaveNow: false)
        let applied = JourneyPrefs(morningSummary: false).applied(over: device)
        #expect(!applied.morningSummary)
        #expect(!applied.leaveNow)
        #expect(JourneyPrefs(leaveNow: true).applied(over: device).leaveNow)
    }

    // MARK: Request bodies

    @Test func journeyTravelTimeSetAndCleared() throws {
        let set = try encode(UpdateJourneyRequest(travelMinutes: .value(20)))
        #expect(set["travelMinutes"] as? Int == 20)
        #expect(set["prefs"] == nil)
        #expect(set["archived"] == nil)
        let cleared = try encode(UpdateJourneyRequest(travelMinutes: .null))
        #expect(cleared["travelMinutes"] is NSNull)
        // Not sent at all when only prefs change.
        #expect(try encode(UpdateJourneyRequest(prefs: JourneyPrefs().replacingAll))["travelMinutes"] == nil)
    }

    @Test func journeyPrefsReplaceTheNewOverridesToo() throws {
        let body = try encode(UpdateJourneyRequest(prefs: JourneyPrefs(leaveNow: false).replacingAll))
        let sent = try #require(body["prefs"] as? [String: Any])
        #expect(sent["leaveNow"] as? Bool == false)
        #expect(sent["morningSummary"] is NSNull)
    }

    @Test func createTemplateLeavesOutWhatIsntSet() throws {
        let id = UUID()
        let body = try encode(CreateJourneyTemplateRequest(fromCrs: "LBG", toCrs: "BTN", departTime: "07:42", days: [1, 2, 3, 4, 5], trainUid: "W12345", journeyId: id))
        #expect(body["fromCrs"] as? String == "LBG")
        #expect(body["departTime"] as? String == "07:42")
        #expect(body["days"] as? [Int] == [1, 2, 3, 4, 5])
        #expect(body["journeyId"] as? String == id.uuidString.lowercased())
        // Left to the journey's (the server's defaults).
        for key in ["travelMinutes", "summaryTime", "prefs"] {
            #expect(body[key] == nil, "\(key)")
        }
        let full = try encode(CreateJourneyTemplateRequest(fromCrs: "LBG", toCrs: "BTN", departTime: "07:42", days: [1], travelMinutes: 15, summaryTime: "06:40", prefs: JourneyPrefs(stopAlarm: true)))
        #expect(full["travelMinutes"] as? Int == 15)
        #expect(full["summaryTime"] as? String == "06:40")
        #expect((full["prefs"] as? [String: Any])?["stopAlarm"] as? Bool == true)
        #expect((full["prefs"] as? [String: Any])?["delays"] == nil)
        #expect(full["journeyId"] == nil)
        #expect(full["trainUid"] == nil)
    }

    @Test func templateEditsSendOnlyChangesAndNullToClear() throws {
        let saved = RegularJourneyDraft(departTime: "07:42", days: [1, 2, 3, 4, 5], travelMinutes: 15, summaryTime: "06:40")
        #expect(saved.changes(from: saved) == nil)
        // Same days in another order isn't a change.
        var reordered = saved
        reordered.days = [5, 4, 3, 2, 1]
        #expect(reordered.changes(from: saved) == nil)

        var cleared = saved
        cleared.travelMinutes = nil
        cleared.summaryTime = nil
        let body = try encode(try #require(cleared.changes(from: saved)))
        #expect(body["travelMinutes"] is NSNull)
        #expect(body["summaryTime"] is NSNull)
        #expect(body["departTime"] == nil)
        #expect(body["days"] == nil)
        #expect(body["prefs"] == nil)

        var moved = saved
        moved.departTime = "07:52"
        moved.days = [3, 1]
        moved.travelMinutes = 20
        let patch = try encode(try #require(moved.changes(from: saved)))
        #expect(patch["departTime"] as? String == "07:52")
        #expect(patch["days"] as? [Int] == [1, 3])
        #expect(patch["travelMinutes"] as? Int == 20)
        #expect(patch["summaryTime"] == nil)
    }

    // MARK: Days and times

    @Test func dayLabels() {
        #expect(Weekdays.label([1, 2, 3, 4, 5]) == "Weekdays")
        #expect(Weekdays.label([5, 4, 3, 2, 1]) == "Weekdays")
        #expect(Weekdays.label(Array(1...7)) == "Every day")
        #expect(Weekdays.label([6, 7]) == "Weekends")
        #expect(Weekdays.label([2]) == "Tuesdays")
        #expect(Weekdays.label([1, 2, 3, 4]) == "Mon–Thu")
        #expect(Weekdays.label([1, 3, 5]) == "Mon, Wed, Fri")
        #expect(Weekdays.label([1, 2, 4, 5, 6]) == "Mon, Tue, Thu–Sat")
        #expect(Weekdays.label([1, 7]) == "Mon, Sun")
        #expect(Weekdays.label([]) == "Never")
    }

    @Test func daysNormalized() {
        #expect(Weekdays.normalized([3, 1, 3, 0, 8, 7]) == [1, 3, 7])
        #expect(Weekdays.initial(4) == "T")
        #expect(Weekdays.shortName(7) == "Sun")
    }

    @Test func ukWeekdays() throws {
        // Friday 6 Nov 2026; Sunday 23:30 UTC in summer is already Monday in the UK.
        #expect(Weekdays.isoWeekday(of: try Date("2026-11-06T12:00:00Z", strategy: .iso8601)) == 5)
        #expect(Weekdays.isoWeekday(of: try Date("2026-11-08T12:00:00Z", strategy: .iso8601)) == 7)
        #expect(Weekdays.isoWeekday(of: try Date("2026-06-07T23:30:00Z", strategy: .iso8601)) == 1)
    }

    @Test func clockTimes() {
        #expect(ClockTime.minutes("07:42") == 462)
        #expect(ClockTime.minutes("24:00") == nil)
        #expect(ClockTime.minutes("7") == nil)
        #expect(ClockTime.hhmm(462) == "07:42")
        #expect(ClockTime.hhmm(-10) == "23:50")
        #expect(ClockTime.fromPicker(ClockTime.pickerDate("06:05")) == "06:05")
        // The summary's default: an hour before, on the five minutes, not before midnight.
        #expect(ClockTime.defaultSummaryTime(departTime: "07:42") == "06:40")
        #expect(ClockTime.defaultSummaryTime(departTime: "08:00") == "07:00")
        #expect(ClockTime.defaultSummaryTime(departTime: "00:20") == "00:00")
    }

    @Test func travelTimeSuggestionsRoundUpToFiveMinutes() {
        #expect(TravelTime.suggestedMinutes(eta: 0) == 5)
        #expect(TravelTime.suggestedMinutes(eta: 61) == 5)
        #expect(TravelTime.suggestedMinutes(eta: 300) == 5)
        #expect(TravelTime.suggestedMinutes(eta: 301) == 10)
        #expect(TravelTime.suggestedMinutes(eta: 11 * 60) == 15)
        #expect(TravelTime.suggestedMinutes(eta: 20 * 60) == 20)
        #expect(TravelTime.suggestedMinutes(eta: 10 * 3600) == 240) // the server's limit
        #expect(TravelTime.walks(distanceMeters: 800))
        #expect(!TravelTime.walks(distanceMeters: 5000))
    }

    @Test func travelTimeChoicesKeepAnOddValue() {
        #expect(TravelTime.options(including: nil) == TravelTime.options)
        #expect(TravelTime.options(including: 15) == TravelTime.options)
        let odd = TravelTime.options(including: 17)
        #expect(odd.contains(17))
        #expect(odd == odd.sorted())
    }

    // MARK: Alerts

    @Test func alertsOpenTheirJourneyOrRegularJourneys() {
        let journey = UUID(uuidString: "af28be9d-180a-42b3-92ca-5825a3cb6428")!
        for kind in ["morning_summary", "leave_now", "platform"] {
            let payload: [AnyHashable: Any] = ["kind": kind, "journeyId": journey.uuidString.lowercased()]
            #expect(PushNotifications.destination(in: payload, threadIdentifier: "") == .journey(journey), "\(kind)")
        }
        // No journey yet: the list of regular journeys, even if the thread is the template's ID.
        let unmatched: [AnyHashable: Any] = ["kind": "template_unmatched", "templateId": "0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10", "date": "2026-11-10"]
        #expect(PushNotifications.destination(in: unmatched, threadIdentifier: "0b7c2f8e-5d0e-4a8e-9c61-2f0c1e1b9a10") == .regularJourneys)
        #expect(PushNotifications.destination(in: [:], threadIdentifier: "") == nil)
    }
}

private final class RegularBundleToken {}
