import Foundation
import Testing
@testable import TrainTracker

/// Trips (Sprint 2): decoding the server's trips and connections, grouping a
/// trip's legs into one card, and how a change is shown.
@MainActor
struct TripTests {
    /// Monday 2 November 2026, 12:00 UK time.
    let now = RailTime.date("2026-11-02", at: "12:00")!

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try TracksClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static let connectionJSON = """
    {"leg":1,"station":{"crs":"PBO","name":"Peterborough","lat":52.5748,"lon":-0.2501},"status":"at_risk",
     "message":"Only 3 min to change (5 needed)","arrival":"2026-11-03T17:52:00+00:00",
     "arrivalPlatform":{"number":"4","source":"live","confirmed":true,"hidden":false},
     "departure":"2026-11-03T17:55:00+00:00","departurePlatform":null,"minimumChangeMinutes":5,
     "marginMinutes":-2,"scheduledMarginMinutes":3,"cancelled":false}
    """

    /// A leg as the server returns it, without the parts these tests don't look at changing.
    private static func leg(id: String, from: (String, String), to: (String, String), departs: String, arrives: String, leg: Int, connection: String) -> String {
        """
        {"id":"\(id)","trainUid":"A00001","runDate":"2026-11-03","date":"2026-11-03","headcode":"1S25",
         "operator":{"code":"GR","name":"LNER"},
         "from":{"crs":"\(from.0)","name":"\(from.1)","lat":null,"lon":null},"to":{"crs":"\(to.0)","name":"\(to.1)","lat":null,"lon":null},
         "scheduledDeparture":"2026-11-03T\(departs):00+00:00","scheduledArrival":"2026-11-03T\(arrives):00+00:00",
         "bookedPlatform":"7","prefs":{"connections":false},"templateId":null,"travelMinutes":null,
         "trip":{"id":"6f1c3a52-6a51-4c4e-9a7e-0d1c2b3a4f50","leg":\(leg),"legs":2},"connection":\(connection),
         "createdAt":"2026-11-02T10:00:00+00:00","archivedAt":null,
         "callingPoints":[
           {"crs":"\(from.0)","name":"\(from.1)","lat":null,"lon":null,"scheduledArrival":null,"scheduledDeparture":"2026-11-03T\(departs):00+00:00","bookedPlatform":"7","live":null},
           {"crs":"\(to.0)","name":"\(to.1)","lat":null,"lon":null,"scheduledArrival":"2026-11-03T\(arrives):00+00:00","scheduledDeparture":null,"bookedPlatform":null,"live":null}],
         "fromIndex":0,"toIndex":1,"route":[],
         "live":{"state":"scheduled","checkedAt":"2026-11-02T12:00:00+00:00","nextPollSeconds":3600,"stale":false,"message":null,"service":null,"progress":null,"position":null}}
        """
    }

    @Test func decodesATripWithAlternatives() throws {
        let alternative = """
        {"trainUid":"A00002","runDate":"2026-11-03","headcode":"1N99","operator":{"code":"GR","name":"LNER"},
         "scheduledDeparture":"2026-11-03T18:12:00+00:00","bookedPlatform":"2",
         "destination":{"crs":"EDB","name":"Edinburgh","lat":null,"lon":null},
         "arrival":{"station":{"crs":"YRK","name":"York","lat":null,"lon":null},"scheduledArrival":"2026-11-03T19:20:00+00:00"},
         "live":{"expectedDeparture":"2026-11-03T18:14:00+00:00","actualDeparture":null,"delayMinutes":2,"platform":null,"isCancelled":false}}
        """
        let first = Self.leg(id: "11111111-1111-4111-8111-111111111111", from: ("KGX", "London Kings Cross"), to: ("PBO", "Peterborough"),
                             departs: "17:00", arrives: "17:45", leg: 1, connection: Self.connectionJSON)
        let second = Self.leg(id: "22222222-2222-4222-8222-222222222222", from: ("PBO", "Peterborough"), to: ("YRK", "York"),
                              departs: "17:55", arrives: "19:00", leg: 2, connection: "null")
        let connectionWithAlternatives = Self.connectionJSON.dropLast() + #","alternatives":["# + alternative + "]}"
        let trip = try decode(Trip.self, """
        {"id":"6f1c3a52-6a51-4c4e-9a7e-0d1c2b3a4f50","legs":[\(first),\(second)],
         "connections":[\(connectionWithAlternatives)],"createdAt":"2026-11-02T10:00:00+00:00"}
        """)
        #expect(trip.legs.map(\.from.crs) == ["KGX", "PBO"])
        #expect(trip.legs[0].trip == TripLink(id: trip.id, leg: 1, legs: 2))
        #expect(trip.legs[0].connection?.status == .atRisk)
        #expect(trip.legs[0].prefs.connections == false)
        #expect(trip.legs[1].connection == nil) // the last leg has no change after it
        let change = try #require(trip.connections.first)
        #expect(change.connection.station.crs == "PBO")
        #expect(change.connection.marginMinutes == -2)
        #expect(change.connection.arrivalPlatform?.confirmed == true)
        #expect(change.connection.departurePlatform == nil)
        #expect(change.alternatives.map(\.headcode) == ["1N99"])
        #expect(change.alternatives.first?.arrival?.station.crs == "YRK")

        // The cache keeps the trip and connection.
        let cached = Journey(trip.legs[0])
        #expect(cached.trip?.leg == 1 && !cached.isLastLeg)
        #expect(cached.connection?.message == "Only 3 min to change (5 needed)")
        #expect(Journey(trip.legs[1]).isLastLeg)
    }

    @Test func journeysFromBeforeTripsDecode() throws {
        // Older servers send neither `trip` nor `connection`, nor the `connections` pref.
        let item = try decode(LiveSummary.self, #"{"state":"scheduled","isCancelled":false,"stale":false}"#)
        #expect(item.state == .scheduled)
        let prefs = try decode(NotificationPrefs.self, """
        {"delays":true,"platforms":true,"cancellations":true,"departure":true,"arrival":true,"delayThresholdMinutes":5,"liveActivity":true}
        """)
        #expect(prefs.connections)
        var journeyPrefs = JourneyPrefs()
        journeyPrefs.connections = false
        #expect(!journeyPrefs.applied(over: prefs).connections)
        #expect(JourneyPrefs().applied(over: prefs).connections)
    }

    @Test func newErrorCodes() throws {
        #expect(try decode(TracksErrorBody.self, #"{"error":{"code":"not_connected","message":"x"}}"#).error.code == .notConnected)
        #expect(try decode(TracksErrorBody.self, #"{"error":{"code":"trip_not_found","message":"x"}}"#).error.code == .tripNotFound)
    }

    @Test func tripRequestsSendLowercaseIDs() throws {
        let id = UUID(uuidString: "6F1C3A52-6A51-4C4E-9A7E-0D1C2B3A4F50")!
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CreateTripRequest(journeyIds: [id]))) as? [String: Any]
        #expect(body?["journeyIds"] as? [String] == ["6f1c3a52-6a51-4c4e-9a7e-0d1c2b3a4f50"])
        let prefs = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JourneyPrefs(connections: false).replacingAll)) as? [String: Any]
        #expect(prefs?["connections"] as? Bool == false)
    }

    // MARK: - The list

    private func leg(_ from: (String, String), _ to: (String, String), departs: String, arrives: String, date: String = "2026-11-02", trip: UUID? = nil, number: Int = 1, of total: Int = 2) -> Journey {
        let j = Journey.preview(from: from, to: to, date: date, departs: departs, arrives: arrives)
        j.trip = trip.map { TripLink(id: $0, leg: number, legs: total) }
        return j
    }

    @Test func aTripsLegsShareOneCard() {
        let trip = UUID()
        let second = leg(("PBO", "Peterborough"), ("YRK", "York"), departs: "17:55", arrives: "19:00", trip: trip, number: 2)
        let first = leg(("KGX", "London Kings Cross"), ("PBO", "Peterborough"), departs: "17:00", arrives: "17:45", trip: trip, number: 1)
        let alone = leg(("YRK", "York"), ("LDS", "Leeds"), departs: "17:30", arrives: "18:00")
        let entries = JourneyEntry.entries([first, alone, second])
        #expect(entries.count == 2)
        #expect(entries[0].isTrip && entries[0].tripID == trip)
        #expect(entries[0].legs.map(\.from.crs) == ["KGX", "PBO"])
        #expect(entries[0].last.to.crs == "YRK")
        #expect(!entries[1].isTrip && entries[1].tripID == nil)

        // A leg on its own (the other filtered out by a search) is an ordinary card.
        let single = JourneyEntry.entries([second])
        #expect(single.count == 1 && !single[0].isTrip)
    }

    @Test func aTripIsLiveWhileAnyTrainIsAndPastOnceAllAre() {
        let trip = UUID()
        // First train arrived at 11:45; the second leaves at 12:30, within the hour.
        let first = leg(("KGX", "London Kings Cross"), ("PBO", "Peterborough"), departs: "11:00", arrives: "11:45", trip: trip, number: 1)
        let second = leg(("PBO", "Peterborough"), ("YRK", "York"), departs: "12:30", arrives: "13:30", trip: trip, number: 2)
        var sections = JourneySections(journeys: [first, second], now: now)
        #expect(sections.live.flatMap(\.entries).map(\.legs.count) == [2])
        #expect(sections.past.isEmpty && sections.upcoming.isEmpty)

        // Later in the day: the second train is still hours away, so the trip is upcoming, not split.
        sections = JourneySections(journeys: [first, second], now: RailTime.date("2026-11-02", at: "08:00")!)
        #expect(sections.upcoming.flatMap(\.entries).map(\.legs.count) == [2])
        #expect(sections.live.isEmpty)

        // Both over.
        sections = JourneySections(journeys: [first, second], now: RailTime.date("2026-11-02", at: "18:00")!)
        #expect(sections.past.flatMap(\.entries).map(\.legs.count) == [2])
        #expect(sections.past.first?.journeys.map(\.from.crs) == ["KGX", "PBO"])
    }

    @Test func aTripIsUnderTheDayItsFirstTrainLeaves() {
        let trip = UUID()
        let first = leg(("KGX", "London Kings Cross"), ("PBO", "Peterborough"), departs: "23:00", arrives: "23:45", date: "2026-11-03", trip: trip, number: 1)
        let second = leg(("PBO", "Peterborough"), ("YRK", "York"), departs: "00:20", arrives: "01:30", date: "2026-11-04", trip: trip, number: 2)
        let sections = JourneySections(journeys: [second, first], now: now)
        #expect(sections.upcoming.map(\.label) == ["Tomorrow"])
    }

    // MARK: - How a change is shown

    private func connection(_ status: ConnectionStatus, message: String = "8 min to change") -> Connection {
        Connection(
            leg: 1, station: Station(crs: "PBO", name: "Peterborough"), status: status, message: message,
            arrival: RailTime.date("2026-11-02", at: "17:45")!,
            arrivalPlatform: Platform(number: "4", source: .live, confirmed: true),
            departure: RailTime.date("2026-11-02", at: "17:58")!,
            minimumChangeMinutes: 5, marginMinutes: 8, scheduledMarginMinutes: 8, cancelled: false
        )
    }

    @Test func connectionDisplay() {
        let ok = ConnectionDisplay(connection(.ok))
        #expect(ok.tone == .ok && !ok.offersAlternatives)
        #expect(ok.title == "Change at Peterborough")
        #expect(ok.detail == "8 min to change")
        #expect(ok.accessibilityLabel == "Change at Peterborough, 8 min to change")
        #expect(ConnectionDisplay(connection(.tight)).tone == .warning)
        #expect(!ConnectionDisplay(connection(.tight)).offersAlternatives)
        #expect(ConnectionDisplay(connection(.atRisk)).tone == .warning)
        #expect(ConnectionDisplay(connection(.atRisk)).offersAlternatives)
        #expect(ConnectionDisplay(connection(.missed)).tone == .bad)
        #expect(ConnectionDisplay(connection(.missed)).offersAlternatives)
        #expect(ConnectionDisplay.times(connection(.ok)) == "Arrive 17:45 · platform 4 → leave 17:58")
    }

    @Test func connectionAlertOpensTheArrivingLeg() {
        let leg = "11111111-1111-4111-8111-111111111111"
        let payload: [AnyHashable: Any] = ["kind": "connection", "journeyId": leg, "tripId": "6f1c3a52-6a51-4c4e-9a7e-0d1c2b3a4f50"]
        #expect(PushNotifications.destination(in: payload, threadIdentifier: leg) == .journey(UUID(uuidString: leg)!))
    }
}
