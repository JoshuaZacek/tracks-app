import Foundation
import Testing
@testable import TrainTracker

/// Integration tests against the tracks server running on this Mac
/// (`npm run dev` in ~/Desktop/tracks-server). Skipped when it isn't running.
///
/// The server allows 20 registrations an hour per IP, so tests that aren't
/// about registration share one test device, kept in its own Keychain entry
/// between runs. Only the two registration tests create (and delete) devices.
/// The development server on this Mac. Tests never touch the deployed one.
let localTracksServer = URL(string: "http://localhost:3000")!

func tracksServerIsUp() async -> Bool {
    let url = localTracksServer.appending(path: "health")
    return (try? await URLSession.shared.data(from: url)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
}

@MainActor
@Suite(.enabled("tracks server not running on localhost:3000") { await tracksServerIsUp() })
struct TracksAPITests {
    /// The shared test device's client (registered once, then reused across runs).
    private static let shared = TracksClient(session: DeviceSession(service: "com.joshuazacek.TrainTracker.tracks.integration"), baseURL: localTracksServer)

    /// A client with a fresh, unregistered identity: for the registration tests only.
    private func makeClient() -> (TracksClient, DeviceSession) {
        let session = DeviceSession(service: "com.joshuazacek.TrainTracker.tracks.test.\(UUID().uuidString)")
        return (TracksClient(session: session, baseURL: localTracksServer), session)
    }

    @Test func registersOnFirstUseAndKeepsTheToken() async throws {
        let (client, session) = makeClient()
        #expect(session.credentials == nil)
        let device = try await client.device()
        let credentials = try #require(session.credentials)
        #expect(device.deviceId == credentials.deviceId)
        #expect(credentials.token.hasPrefix("trk_"))
        // The same token is reused, not a new registration.
        #expect(try await client.device().deviceId == device.deviceId)
        try await client.deleteDevice()
        #expect(session.credentials == nil)
    }

    @Test func updatesOnlyTheFieldsSent() async throws {
        let client = Self.shared
        let before = try await client.device()
        let version = "test \(Int.random(in: 1...9999))"
        let after = try await client.updateDevice(UpdateDeviceRequest(appVersion: version, apnsEnvironment: .sandbox))
        #expect(after.appVersion == version)
        #expect(after.apnsEnvironment == .sandbox)
        #expect(after.prefs == before.prefs)
        #expect(after.locale == before.locale)
    }

    @Test func registersAgainWhenTheTokenIsRejected() async throws {
        let (client, session) = makeClient()
        let first = try await client.device()
        try await client.deleteDevice()
        // A stale token, as if the device was deleted on the server while this install kept it.
        session.credentials = DeviceSession.Credentials(deviceId: first.deviceId, token: "trk_notavalidtokenanymore0000000000000000000")
        let second = try await client.device()
        #expect(second.deviceId != first.deviceId)
        #expect(session.credentials?.deviceId == second.deviceId)
        try await client.deleteDevice()
    }

    @Test func decodesTheServersErrors() async throws {
        let client = Self.shared
        do {
            let _: ServerStatus = try await client.request("GET", "/v1/stations/KGX/departures", query: ["date": "03-11-2026"])
            Issue.record("expected a validation error")
        } catch let error as TracksError {
            #expect(error.code == .validationFailed)
            #expect(error.httpStatus == 400)
        }
    }

    @Test func status() async throws {
        let status = try await Self.shared.status()
        #expect(!status.version.isEmpty)
        #expect(abs(status.serverTime.timeIntervalSinceNow) < 120)
    }

    // MARK: - Phase 2: reference data

    @Test func stationSearchRanksExactCodeAndNamePrefixFirst() async throws {
        let client = Self.shared
        #expect(try await client.stations(matching: "york").first?.crs == "YRK")
        #expect(try await client.stations(matching: "kgx").first?.crs == "KGX")
        #expect(try await client.stations(matching: "clapham", limit: 3).count == 3)
    }

    @Test func nearbyStations() async throws {
        let client = Self.shared
        let near = try await client.nearbyStations(latitude: 51.532, longitude: -0.1233, limit: 3)
        #expect(near.first?.crs == "KGX")
        #expect(near.map(\.distanceMeters) == near.map(\.distanceMeters).sorted())
    }

    @Test func departuresPageWithoutGapsOrRepeats() async throws {
        let client = Self.shared
        let date = RailTime.ymd(.now)
        var paged: [Departure] = []
        var cursor: String?
        repeat {
            let page = try await client.departures(from: "YRK", date: date, after: "12:00", cursor: cursor, limit: 25)
            paged += page.departures
            cursor = page.nextCursor
        } while cursor != nil && paged.count < 1000
        let single = try await client.departures(from: "YRK", date: date, after: "12:00", limit: 100)
        #expect(Set(paged.map(\.id)).count == paged.count)
        #expect(paged.map(\.scheduledDeparture) == paged.map(\.scheduledDeparture).sorted())
        #expect(Array(paged.prefix(single.departures.count)).map(\.id) == single.departures.map(\.id))
    }

    @Test func trainDetailsAndNotRunning() async throws {
        let client = Self.shared
        let date = RailTime.ymd(.now)
        let d = try #require(try await client.departures(from: "KGX", date: date, to: "YRK", after: "09:00", limit: 1).departures.first)
        let train = try await client.train(uid: d.trainUid, runDate: d.runDate)
        #expect(train.callingPoints.contains { $0.crs == "YRK" })
        #expect(train.callingPoints.first { $0.crs == "KGX" }?.scheduledDeparture == d.scheduledDeparture)
        do {
            _ = try await client.train(uid: d.trainUid, runDate: "2030-01-01")
            Issue.record("expected train_not_running")
        } catch let error as TracksError {
            #expect(error.code == .trainNotRunning)
        }
    }

    @Test func placesRevalidateAndMatchTheWebLabels() async throws {
        let client = Self.shared
        let first = try await client.places(ifNoneMatch: nil)
        let data = try #require(first.data)
        let etag = try #require(first.etag)
        #expect(try await client.places(ifNoneMatch: etag).data == nil) // 304
        let index = PlaceIndex(try JSONDecoder().decode(PlacesDataset.self, from: data))
        #expect(index.attribution.contains("OS data"))
        // The same positions and labels as the web app's checks.
        let expected: [(Double, Double, String?)] = [
            (52.9064, -0.6424, "Spittlegate, Grantham"),
            (53.205, -0.858, "Near Weston"),
            (52.68, -0.43, "Belmesthorpe, near Stamford"),
            (51.4214, -0.2064, "South Wimbledon, London"),
            (53.7949, -1.5474, "Camp Field, Leeds"),
            (54.2105, -2.3605, "Near Cowgill"),
            (56.0006, -3.3887, "North Queensferry, near Queensferry"),
            (53.5, 2.5, nil), // North Sea
        ]
        for (lat, lon, label) in expected {
            #expect(index.describe(latitude: lat, longitude: lon) == label, "\(lat), \(lon)")
        }
    }
}
