import Foundation
import Testing
@testable import TrainTracker

/// Phase 5: the server's push payloads (captured from its push log) and the
/// PATCH bodies the app sends.
struct PushPayloadTests {
    private func json(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle(for: PushBundleToken.self).url(forResource: name, withExtension: "json"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Decodes a payload's content-state the way ActivityKit does: a plain JSONDecoder.
    private func contentState(_ name: String) throws -> TrainActivityAttributes.ContentState {
        let aps = try #require(try json(name)["aps"] as? [String: Any])
        let state = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
        return try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: state)
    }

    private func date(_ iso: String) throws -> Date { try Date(iso, strategy: .iso8601) }

    @Test func pushToStartPayload() throws {
        let payload = try json("activity-start")
        let aps = try #require(payload["aps"] as? [String: Any])
        #expect(aps["attributes-type"] as? String == "TrainActivityAttributes")
        let attributesData = try JSONSerialization.data(withJSONObject: try #require(aps["attributes"]))
        let attributes = try JSONDecoder().decode(TrainActivityAttributes.self, from: attributesData)
        #expect(attributes.headcode == "1D12")
        #expect(attributes.fromCrs == "KGX")
        #expect(attributes.toName == "Peterborough")

        let state = try contentState("activity-start")
        #expect(state.state == .live)
        #expect(state.scheduledDeparture == (try date("2026-11-03T11:10:00+00:00")))
        #expect(state.expectedArrival == (try date("2026-11-03T11:55:00+00:00")))
        #expect(state.actualDeparture == nil)
        #expect(state.platform == .init(number: "7", confirmed: false))
        #expect(state.statusText == "On time")
        #expect(!state.departed)
    }

    @Test func departedUpdate() throws {
        let state = try contentState("activity-departed")
        #expect(state.state == .departed)
        #expect(state.departed)
        #expect(state.nextStopName == "Grantham")
        #expect(state.legDepartedAt == (try date("2026-11-03T10:43:00+00:00")))
        #expect(state.nextExpectedAt == (try date("2026-11-03T11:46:00+00:00")))
        #expect(state.departureTime == (try date("2026-11-03T10:43:00+00:00")))
        // Half way through, by time.
        let halfway = state.departureTime.addingTimeInterval(state.arrivalTime.timeIntervalSince(state.departureTime) / 2)
        #expect(abs(state.journeyProgress(at: halfway) - 0.5) < 0.001)
    }

    /// What the app encodes (starting an activity itself) decodes back the same.
    @Test func contentStateRoundTrips() throws {
        let state = try contentState("activity-departed")
        let again = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        #expect(again == state)
        let text = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(text.contains("\"legDepartedAt\":\"2026-11-03T10:43:00Z\""))
    }

    @Test func unknownStatesAndLateness() throws {
        let data = Data(#"{"state":"something_new","scheduledDeparture":"2026-11-03T10:00:00+00:00","scheduledArrival":"2026-11-03T11:00:00+00:00","delayMinutes":7,"isCancelled":false}"#.utf8)
        let state = try JSONDecoder().decode(TrainActivityAttributes.ContentState.self, from: data)
        #expect(state.state == .unknown)
        #expect(state.statusText == "7 min late")
        var cancelled = state
        cancelled.isCancelled = true
        #expect(cancelled.statusText == "Cancelled")
    }

    @Test func alertOpensItsJourney() throws {
        let payload = try json("alert-platform")
        let aps = try #require(payload["aps"] as? [String: Any])
        let id = PushNotifications.journeyID(in: payload, threadIdentifier: aps["thread-id"] as? String ?? "")
        #expect(id == UUID(uuidString: "af28be9d-180a-42b3-92ca-5825a3cb6428"))
        // The thread is the journey too, should the custom key ever be missing.
        #expect(PushNotifications.journeyID(in: [:], threadIdentifier: "af28be9d-180a-42b3-92ca-5825a3cb6428") == id)
        #expect(PushNotifications.journeyID(in: [:], threadIdentifier: "") == nil)
    }

    @Test func tokensAsHex() {
        #expect(Data([0x00, 0xab, 0x10, 0xff]).hexString == "00ab10ff")
    }

    // MARK: PATCH bodies

    private func encode(_ value: some Encodable) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: TracksClient.encoder.encode(value)) as? [String: Any])
    }

    @Test func deviceUpdateSendsOnlyWhatIsSetAndNullToClear() throws {
        let body = try encode(UpdateDeviceRequest(apnsEnvironment: .sandbox, apnsToken: .value("ab12"), pushToStartToken: .null))
        #expect(body["apnsToken"] as? String == "ab12")
        #expect(body["pushToStartToken"] is NSNull)
        #expect(body["apnsEnvironment"] as? String == "sandbox")
        #expect(body["appVersion"] == nil)
        #expect(body["prefs"] == nil)
    }

    @Test func journeyPrefsReplaceEveryOverride() throws {
        let prefs = JourneyPrefs(delays: false, delayThresholdMinutes: 10)
        let body = try encode(UpdateJourneyRequest(prefs: prefs.replacingAll))
        let sent = try #require(body["prefs"] as? [String: Any])
        #expect(sent["delays"] as? Bool == false)
        #expect(sent["delayThresholdMinutes"] as? Int == 10)
        // Everything else goes back to the device's.
        for key in ["platforms", "cancellations", "departure", "arrival", "liveActivity"] {
            #expect(sent[key] is NSNull, "\(key)")
        }
        #expect(body["archived"] == nil)
    }

    @Test func journeyPrefsApplyOverTheDevice() {
        let device = NotificationPrefs(delays: true, platforms: true, cancellations: true, departure: false, arrival: true, delayThresholdMinutes: 5, liveActivity: true)
        let applied = JourneyPrefs(delays: false, departure: true, delayThresholdMinutes: 15).applied(over: device)
        #expect(!applied.delays)
        #expect(applied.departure)
        #expect(applied.platforms)
        #expect(applied.delayThresholdMinutes == 15)
        #expect(applied.liveActivity)
    }
}

/// The Phase 5 endpoints on the server running on this Mac.
@MainActor
@Suite(.enabled("tracks server not running on localhost:3000") { await tracksServerIsUp() })
struct PushEndpointTests {
    private func makeClient() -> TracksClient {
        TracksClient(session: DeviceSession(service: "com.joshuazacek.TrainTracker.tracks.test.\(UUID().uuidString)"))
    }

    /// A made-up but well-formed APNs token (32 bytes).
    private func fakeToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: 0...255) }).hexString
    }

    @Test func deviceTokensAndPrefs() async throws {
        let client = makeClient()
        defer { Task { try? await client.deleteDevice() } }
        var device = try await client.device()
        #expect(!device.apnsTokenRegistered)
        #expect(device.prefs.liveActivity)

        device = try await client.updateDevice(UpdateDeviceRequest(apnsEnvironment: .sandbox, apnsToken: .value(fakeToken()), pushToStartToken: .value(fakeToken())))
        #expect(device.apnsTokenRegistered)
        #expect(device.pushToStartTokenRegistered)
        #expect(device.apnsEnvironment == .sandbox)

        var prefs = device.prefs
        prefs.delays = false
        prefs.delayThresholdMinutes = 12
        prefs.liveActivity = false
        device = try await client.updateDevice(UpdateDeviceRequest(prefs: prefs))
        #expect(device.prefs == prefs)
        #expect(device.apnsTokenRegistered) // untouched

        device = try await client.updateDevice(UpdateDeviceRequest(apnsToken: .null))
        #expect(!device.apnsTokenRegistered)
        #expect(device.pushToStartTokenRegistered)
        try await client.deleteDevice()
    }

    @Test func journeyPrefsAndLiveActivityToken() async throws {
        let client = makeClient()
        defer { Task { try? await client.deleteDevice() } }
        let tomorrow = RailTime.ymd(RailTime.calendar.date(byAdding: .day, value: 1, to: .now)!)
        let d = try #require(try await client.departures(from: "KGX", date: tomorrow, to: "YRK", after: "09:00", limit: 1).departures.first)
        let journey = try await client.createJourney(CreateJourneyRequest(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: "YRK"))
        #expect(journey.prefs == JourneyPrefs())

        var updated = try await client.updateJourney(id: journey.id, UpdateJourneyRequest(prefs: JourneyPrefs(delays: false, liveActivity: false).replacingAll))
        #expect(updated.prefs == JourneyPrefs(delays: false, liveActivity: false))
        updated = try await client.updateJourney(id: journey.id, UpdateJourneyRequest(prefs: JourneyPrefs(delayThresholdMinutes: 20).replacingAll))
        #expect(updated.prefs == JourneyPrefs(delayThresholdMinutes: 20))

        try await client.registerLiveActivity(journeyID: journey.id, pushToken: fakeToken())
        try await client.registerLiveActivity(journeyID: journey.id, pushToken: fakeToken()) // rotation
        try await client.endLiveActivity(journeyID: journey.id)
        do {
            try await client.registerLiveActivity(journeyID: UUID(), pushToken: fakeToken())
            Issue.record("Expected journey_not_found")
        } catch let error as TracksError {
            #expect(error.code == .journeyNotFound)
        }
        try await client.deleteDevice()
    }

    @Test func statusReportsPush() async throws {
        let push = try #require(try await makeClient().status().push)
        #expect(push.sentLastHour >= 0)
    }
}

private final class PushBundleToken {}
