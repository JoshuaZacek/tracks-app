import Foundation
import SwiftData
import Testing
@testable import TrainTracker

/// Journeys on the tracks server (`npm run dev` in ~/Desktop/tracks-server):
/// the /v1/journeys endpoints, and JourneySync keeping a local cache in step.
/// Each test registers its own device (loopback isn't rate-limited in
/// development) and deletes it afterwards, which deletes its journeys too.
@MainActor
@Suite(.enabled("tracks server not running on localhost:3000") { await tracksServerIsUp() })
struct JourneySyncTests {
    private func makeClient() -> TracksClient {
        TracksClient(session: DeviceSession(service: "com.joshuazacek.TrainTracker.tracks.test.\(UUID().uuidString)"))
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Journey.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// Tomorrow's first King's Cross → York train after 09:00, so it's always upcoming.
    private func tomorrowsTrain(_ client: TracksClient) async throws -> Departure {
        let tomorrow = RailTime.ymd(RailTime.calendar.date(byAdding: .day, value: 1, to: .now)!)
        let d = try await client.departures(from: "KGX", date: tomorrow, to: "YRK", after: "09:00", limit: 1).departures.first
        return try #require(d)
    }

    // MARK: - Endpoints

    @Test func createListArchiveAndDelete() async throws {
        let client = makeClient()
        let d = try await tomorrowsTrain(client)
        let request = CreateJourneyRequest(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: "YRK")
        let saved = try await client.createJourney(request)
        #expect(saved.from.crs == "KGX")
        #expect(saved.to.crs == "YRK")
        #expect(saved.scheduledDeparture == d.scheduledDeparture)
        #expect(saved.callingPoints[saved.fromIndex].crs == "KGX")
        #expect(saved.callingPoints[saved.toIndex].crs == "YRK")
        #expect(saved.live.state == .scheduled)

        // Saving the same trip again returns the same journey.
        #expect(try await client.createJourney(request).id == saved.id)

        let upcoming = try await client.journeys(.upcoming)
        #expect(upcoming.journeys.map(\.id) == [saved.id])
        #expect(upcoming.nextPollSeconds != nil)
        #expect(try await client.journeys(.past).journeys.isEmpty)

        let archived = try await client.updateJourney(id: saved.id, UpdateJourneyRequest(archived: true))
        #expect(archived.archivedAt != nil)
        #expect(try await client.journeys(.past).journeys.map(\.id) == [saved.id])
        _ = try await client.updateJourney(id: saved.id, UpdateJourneyRequest(archived: false))
        #expect(try await client.journeys(.upcoming).journeys.map(\.id) == [saved.id])

        #expect(try await client.journey(id: saved.id).id == saved.id)
        #expect(try await client.liveStatus(journeyID: saved.id).state == .scheduled)

        try await client.deleteJourney(id: saved.id)
        do {
            _ = try await client.journey(id: saved.id)
            Issue.record("expected journey_not_found")
        } catch let error as TracksError {
            #expect(error.code == .journeyNotFound)
        }
        try await client.deleteDevice()
    }

    @Test func rejectsStationsOffTheRouteAndUnknownRuns() async throws {
        let client = makeClient()
        let d = try await tomorrowsTrain(client)
        do {
            _ = try await client.createJourney(CreateJourneyRequest(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: "MAN"))
            Issue.record("expected station_not_on_route")
        } catch let error as TracksError {
            #expect(error.code == .stationNotOnRoute)
            #expect(error.httpStatus == 422)
        }
        do {
            _ = try await client.createJourney(CreateJourneyRequest(trainUid: d.trainUid, runDate: "2025-01-01", fromCrs: "KGX", toCrs: "YRK"))
            Issue.record("expected train_not_running")
        } catch let error as TracksError {
            #expect(error.code == .trainNotRunning)
        }
        try await client.deleteDevice()
    }

    // MARK: - Sync

    @Test func uploadsJourneysSavedOnlyOnThePhone() async throws {
        let client = makeClient()
        let sync = JourneySync(client: client)
        let context = try makeContext()
        let d = try await tomorrowsTrain(client)
        let train = try await client.train(uid: d.trainUid, runDate: d.runDate)
        let from = try #require(train.callingPoints.firstIndex { $0.crs == "KGX" })
        let to = try #require(train.callingPoints.firstIndex { $0.crs == "YRK" })
        let local = Journey(date: d.runDate, train: train, fromIndex: from, toIndex: to)
        context.insert(local)

        // One that the timetable no longer has: dropped rather than kept forever.
        var gone = train
        gone.runDate = "2025-01-01"
        context.insert(Journey(date: "2025-01-01", train: gone, fromIndex: from, toIndex: to))

        await sync.refresh(in: context)
        #expect(sync.lastError == nil)
        let cached = try context.fetch(FetchDescriptor<Journey>())
        #expect(cached.count == 1)
        let uploaded = try #require(cached.first)
        #expect(uploaded.syncedAt != nil)
        #expect(uploaded.trainUid == d.trainUid && uploaded.runDate == d.runDate)
        #expect(uploaded.live?.state == .scheduled)
        #expect(try await client.journeys(.upcoming).journeys.map(\.id) == [uploaded.id])
        try await client.deleteDevice()
    }

    @Test func saveDeleteAndServerSideChanges() async throws {
        let client = makeClient()
        let sync = JourneySync(client: client)
        let context = try makeContext()
        let d = try await tomorrowsTrain(client)

        let saved = try await sync.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: "YRK", in: context)
        #expect(try context.fetch(FetchDescriptor<Journey>()).map(\.id) == [saved.id])

        // Deleted on the server (e.g. by another refresh): the cache follows.
        try await client.deleteJourney(id: saved.id)
        await sync.refresh(in: context)
        #expect(try context.fetch(FetchDescriptor<Journey>()).isEmpty)

        // No destination given: the train's final stop. Deleted in the app: gone from the server too.
        let again = try await sync.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: nil, in: context)
        #expect(again.toIndex == again.callingPoints.count - 1)
        await sync.delete(again, in: context)
        #expect(try await client.journeys(.upcoming).journeys.isEmpty)
        try await client.deleteDevice()
    }
}
