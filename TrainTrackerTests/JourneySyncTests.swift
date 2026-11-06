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
        TracksClient(session: DeviceSession(service: "com.joshuazacek.TrainTracker.tracks.test.\(UUID().uuidString)"), baseURL: localTracksServer)
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

    /// The server no longer knows the device (its data was reset, or it's a new
    /// server): the app registers again and saves its journeys there.
    @Test func journeysMoveToANewRegistration() async throws {
        let session = DeviceSession(service: "com.joshuazacek.TrainTracker.tracks.test.\(UUID().uuidString)")
        let client = TracksClient(session: session, baseURL: localTracksServer)
        let context = try makeContext()
        let sync = JourneySync(client: client, context: { context })
        let d = try await tomorrowsTrain(client)
        let saved = try await sync.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: "YRK", in: context)

        // Wipe the device on the server but keep its now-meaningless token here.
        let old = try #require(session.credentials)
        try await client.deleteDevice()
        session.credentials = old

        await sync.refresh(in: context)
        #expect(sync.lastError == nil)
        #expect(session.credentials?.deviceId != old.deviceId)
        let cached = try context.fetch(FetchDescriptor<Journey>())
        #expect(cached.count == 1)
        let moved = try #require(cached.first)
        #expect(moved.syncedAt != nil)
        #expect(moved.trainUid == saved.trainUid && moved.runDate == saved.runDate && moved.from.crs == "KGX" && moved.to.crs == "YRK")
        #expect(try await client.journeys(.upcoming).journeys.map(\.id) == [moved.id])
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

    // MARK: - Regular journeys (Sprint 1)

    @Test func repeatEditAndStopRepeating() async throws {
        let client = makeClient()
        let sync = JourneySync(client: client)
        let context = try makeContext()
        let d = try await tomorrowsTrain(client)
        let saved = try await sync.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: "KGX", toCrs: "YRK", in: context)
        // Only tomorrow's weekday, which the journey saved already covers: nothing else is added.
        let weekday = Weekdays.isoWeekday(of: d.scheduledDeparture)

        let template = try await sync.repeatJourney(saved, days: [weekday], travelMinutes: 10, summaryTime: nil, in: context)
        #expect(template.from.crs == "KGX" && template.to.crs == "YRK")
        #expect(template.departTime == RailTime.hhmm(d.scheduledDeparture))
        #expect(template.days == [weekday])
        #expect(template.travelMinutes == 10)
        #expect(template.summaryTime == nil)
        #expect(template.nextJourney?.id == saved.id)
        #expect(saved.templateId == template.id)
        #expect(try await client.journeyTemplates().map(\.id) == [template.id])
        #expect(try await client.journeys(.upcoming).journeys.map(\.id) == [saved.id])

        let edited = try await client.updateJourneyTemplate(id: template.id, UpdateJourneyTemplateRequest(travelMinutes: .null, summaryTime: .value("06:00")))
        #expect(edited.travelMinutes == nil)
        #expect(edited.summaryTime == "06:00")
        #expect(edited.days == [weekday])

        try await sync.setTravelMinutes(25, for: saved, in: context)
        #expect(saved.travelMinutes == 25)
        try await sync.setTravelMinutes(nil, for: saved, in: context)
        #expect(saved.travelMinutes == nil)

        try await sync.stopRepeating(saved, in: context)
        #expect(try await client.journeyTemplates().isEmpty)
        #expect(try await client.journeys(.upcoming).journeys.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Journey>()).isEmpty)
        try await client.deleteDevice()
    }

    // MARK: - Trips (Sprint 2)

    @Test func linkFollowAndSwitchAConnection() async throws {
        let client = makeClient()
        let sync = JourneySync(client: client)
        let context = try makeContext()
        let tomorrow = RailTime.ymd(RailTime.calendar.date(byAdding: .day, value: 1, to: .now)!)
        // King's Cross → Peterborough, then two later trains on to York to choose from.
        let first = try #require(try await client.departures(from: "KGX", date: tomorrow, to: "PBO", after: "09:00", limit: 1).departures.first)
        let arrives = try #require(first.arrival?.scheduledArrival)
        let onward = try await client.departures(from: "PBO", date: tomorrow, to: "YRK", after: RailTime.hhmm(arrives.addingTimeInterval(10 * 60)), limit: 2).departures
        try #require(onward.count == 2)

        let leg1 = try await sync.save(trainUid: first.trainUid, runDate: first.runDate, fromCrs: "KGX", toCrs: "PBO", in: context)
        let leg2 = try await sync.save(trainUid: onward[0].trainUid, runDate: onward[0].runDate, fromCrs: "PBO", toCrs: "YRK", in: context)
        let trip: Trip
        do {
            trip = try await sync.addConnection(after: leg1, next: leg2, in: context)
        } catch let error as TracksError where error.code == .notFound {
            try await client.deleteDevice()
            return // a server from before trips
        }
        #expect(trip.legs.map(\.id) == [leg1.id, leg2.id])
        #expect(leg1.trip == TripLink(id: trip.id, leg: 1, legs: 2))
        #expect(leg2.trip?.leg == 2 && leg2.isLastLeg)
        #expect(leg1.connection?.station.crs == "PBO")
        #expect(leg1.connection?.status == .ok)
        #expect(leg2.connection == nil)
        #expect(trip.connections.count == 1 && trip.connections[0].alternatives.isEmpty)

        // The list carries the trip, so the cache keeps it after a refresh.
        await sync.refresh(in: context)
        #expect(leg1.trip?.id == trip.id && leg1.connection != nil)

        // A train that leaves before the first gets in can't be linked after it.
        let early = try #require(try await client.departures(from: "PBO", date: tomorrow, to: "YRK", after: "08:00", limit: 1).departures.first)
        if early.scheduledDeparture < arrives {
            do {
                _ = try await client.replaceTripLeg(tripID: trip.id, leg: 2, ReplaceLegRequest(trainUid: early.trainUid, runDate: early.runDate))
                Issue.record("expected not_connected")
            } catch let error as TracksError {
                #expect(error.code == .notConnected)
            }
        }

        // "Switch to this train": the second leg becomes the later train; the old journey goes.
        let switched = try await sync.switchLeg(tripID: trip.id, leg: 2, to: onward[1], in: context)
        #expect(switched.legs.count == 2)
        #expect(switched.legs[1].trainUid == onward[1].trainUid)
        let cached = try context.fetch(FetchDescriptor<Journey>())
        #expect(!cached.contains { $0.id == leg2.id })
        #expect(cached.filter { $0.trip?.id == trip.id }.count == 2)

        // Unlinking keeps the trains, each on its own.
        try await sync.unlink(tripID: trip.id, in: context)
        #expect(try context.fetch(FetchDescriptor<Journey>()).allSatisfy { $0.trip == nil && $0.connection == nil })
        await sync.refresh(in: context)
        #expect(try context.fetch(FetchDescriptor<Journey>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<Journey>()).allSatisfy { $0.trip == nil })
        try await client.deleteDevice()
    }

    @Test func devicePrefsHaveTheCommuterAlerts() async throws {
        let client = makeClient()
        var device = try await client.device()
        #expect(device.prefs.morningSummary && device.prefs.leaveNow) // on by default
        var prefs = device.prefs
        prefs.leaveNow = false
        device = try await client.updateDevice(UpdateDeviceRequest(prefs: prefs))
        #expect(!device.prefs.leaveNow)
        #expect(device.prefs.morningSummary)
        try await client.deleteDevice()
    }
}
