import Foundation
import Observation
import OSLog
import SwiftData

/// Keeps the app's journey cache (SwiftData) in step with the tracks server,
/// which stores each install's journeys. Changes go to the server first; the
/// cache follows. A refresh also uploads journeys saved on the phone before
/// journeys moved to the server, and retries deletes made while offline.
@Observable
final class JourneySync {
    static let shared = JourneySync(context: { JourneyStore.context }, alarms: .shared)

    private let client: TracksClient
    /// Moved after every refresh; nil in tests, which leave the app's alarms alone.
    private let alarms: StopAlarm?
    /// The cache this sync keeps (for work not started from a view, e.g. registering again).
    private let context: () -> ModelContext?
    private(set) var isRefreshing = false
    /// Set when the last refresh couldn't reach the server (the list shows the cache).
    private(set) var lastError: String?
    /// When the journey list could next change on its own, per the server.
    private(set) var nextRefresh: Date?
    private var refreshing: Task<Void, Never>?

    private let pendingDeletesKey = "pendingJourneyDeletes"

    init(client: TracksClient = .shared, context: @escaping () -> ModelContext? = { nil }, alarms: StopAlarm? = nil) {
        self.client = client
        self.context = context
        self.alarms = alarms
        // A new registration means a server that doesn't know this install's
        // journeys (its data was reset, or it's a different server): save them
        // there again rather than dropping them. Synchronous (no queue), so it
        // happens before the request that hit the 401 is retried.
        NotificationCenter.default.addObserver(forName: TracksClient.didRegister, object: client, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reuploadAfterRegistering() }
        }
    }

    private func reuploadAfterRegistering() {
        guard let context = context() else { return }
        let journeys = (try? context.fetch(FetchDescriptor<Journey>())) ?? []
        guard !journeys.isEmpty else { return }
        for journey in journeys where journey.syncedAt != nil {
            journey.syncedAt = nil
        }
        try? context.save()
        pendingDeletes = [] // those IDs belonged to the old registration
        Logger.tracks.info("Registered again: \(journeys.count) journeys to save on the server")
        Task { await refresh(in: context) }
    }

    // MARK: - Changes

    /// Saves a journey on the server and caches it. Returns the existing journey if this trip is already saved.
    @discardableResult
    func save(trainUid: String, runDate: String, fromCrs: String, toCrs: String?, in context: ModelContext) async throws -> Journey {
        let server = try await client.createJourney(CreateJourneyRequest(trainUid: trainUid, runDate: runDate, fromCrs: fromCrs, toCrs: toCrs))
        return upsert(server, in: context)
    }

    /// Removes the journey here at once; the server delete is retried later if offline.
    func delete(_ journey: Journey, in context: ModelContext) async {
        let id = journey.id
        let wasOnServer = journey.syncedAt != nil
        let inTrip = journey.trip != nil
        context.delete(journey)
        try? context.save()
        await LiveActivities.shared.end(journeyID: id)
        alarms?.forget(journeyID: id)
        guard wasOnServer else { return }
        do {
            try await client.deleteJourney(id: id)
        } catch let error as TracksError where error.code == .journeyNotFound {
            // Already gone.
        } catch {
            pendingDeletes.insert(id)
            Logger.tracks.info("Delete of \(id) queued: \(error.localizedDescription)")
            return
        }
        // The rest of its trip lost a leg (and maybe the trip): show them as the server has them.
        if inTrip { await refresh(in: context) }
    }

    /// Sets the journey's own alert settings (nil fields follow the device's).
    func setPrefs(_ prefs: JourneyPrefs, for journey: Journey, in context: ModelContext) async throws {
        let server = try await client.updateJourney(id: journey.id, UpdateJourneyRequest(prefs: prefs.replacingAll))
        journey.prefs = server.prefs
        journey.live = LiveSummary(server.live)
        journey.syncedAt = .now
        try? context.save()
        await alarms?.update(journey: journey)
    }

    /// Sets the minutes it takes to get to the station (nil clears it, and with it the leave-now alert).
    func setTravelMinutes(_ minutes: Int?, for journey: Journey, in context: ModelContext) async throws {
        let server = try await client.updateJourney(id: journey.id, UpdateJourneyRequest(travelMinutes: minutes.map { .value($0) } ?? .null))
        journey.update(from: server)
        try? context.save()
    }

    // MARK: Regular journeys

    /// Repeats a journey on the days given. The server links this journey to the
    /// new template and adds the next ones; the refresh brings them here.
    @discardableResult
    func repeatJourney(_ journey: Journey, days: [Int], travelMinutes: Int?, summaryTime: String?, in context: ModelContext) async throws -> JourneyTemplate {
        let template = try await client.createJourneyTemplate(CreateJourneyTemplateRequest(
            fromCrs: journey.from.crs,
            toCrs: journey.to.crs,
            departTime: RailTime.hhmm(journey.departsAt),
            days: days,
            trainUid: journey.trainUid,
            travelMinutes: travelMinutes,
            summaryTime: summaryTime,
            journeyId: journey.id
        ))
        journey.templateId = template.id
        journey.travelMinutes = template.travelMinutes
        try? context.save()
        await refresh(in: context)
        return template
    }

    /// "Stop repeating": deletes the regular journey (journeys it made stay on the
    /// server), then this journey. Nothing changes if the template can't be deleted.
    func stopRepeating(_ journey: Journey, in context: ModelContext) async throws {
        if let templateID = journey.templateId {
            do {
                try await client.deleteJourneyTemplate(id: templateID)
            } catch let error as TracksError where error.httpStatus == 404 {
                // Already gone.
            }
        }
        await delete(journey, in: context)
    }

    // MARK: Trips

    /// Links a connecting train after `journey`: the legs of its trip (or `journey`
    /// alone), then `next`. Returns the trip; the legs here take their new trip and connection.
    @discardableResult
    func addConnection(after journey: Journey, next: Journey, in context: ModelContext) async throws -> Trip {
        try await link(legIDs(of: journey, in: context) + [next.id], in: context)
    }

    /// Links journeys, in travelling order, into one trip.
    @discardableResult
    func link(_ journeyIDs: [UUID], in context: ModelContext) async throws -> Trip {
        let trip = try await client.createTrip(journeyIDs: journeyIDs)
        apply(trip, in: context)
        return trip
    }

    /// The trip with its connections and alternatives; its legs here are brought up to date.
    func trip(id: UUID, in context: ModelContext) async throws -> Trip {
        let trip = try await client.trip(id: id)
        apply(trip, in: context)
        return trip
    }

    /// "Switch to this train": leg `leg` of the trip becomes a journey on `departure`.
    /// The server deletes the old leg's journey, so its Live Activity and stop alarm go too.
    @discardableResult
    func switchLeg(tripID: UUID, leg: Int, to departure: Departure, in context: ModelContext) async throws -> Trip {
        let old = try context.fetch(FetchDescriptor<Journey>()).first { $0.trip?.id == tripID && $0.trip?.leg == leg }
        let trip = try await client.replaceTripLeg(tripID: tripID, leg: leg, ReplaceLegRequest(trainUid: departure.trainUid, runDate: departure.runDate))
        if let old, !trip.legs.contains(where: { $0.id == old.id }) {
            let id = old.id
            context.delete(old)
            await LiveActivities.shared.end(journeyID: id)
            alarms?.forget(journeyID: id)
        }
        apply(trip, in: context)
        await alarms?.sync((try? context.fetch(FetchDescriptor<Journey>())) ?? [])
        return trip
    }

    /// Unlinks a trip: its journeys stay, each on its own.
    func unlink(tripID: UUID, in context: ModelContext) async throws {
        do {
            try await client.deleteTrip(id: tripID)
        } catch let error as TracksError where error.code == .tripNotFound {
            // Already gone.
        }
        for journey in try context.fetch(FetchDescriptor<Journey>()) where journey.trip?.id == tripID {
            journey.trip = nil
            journey.connection = nil
        }
        try? context.save()
    }

    /// The cached legs of `journey`'s trip in order, or just `journey`.
    func legIDs(of journey: Journey, in context: ModelContext) -> [UUID] {
        guard let tripID = journey.trip?.id else { return [journey.id] }
        let legs = ((try? context.fetch(FetchDescriptor<Journey>())) ?? [])
            .filter { $0.trip?.id == tripID }
            .sorted { ($0.trip?.leg ?? 0) < ($1.trip?.leg ?? 0) }
        return legs.isEmpty ? [journey.id] : legs.map(\.id)
    }

    /// Caches a trip's legs (each carries its trip link and connection).
    private func apply(_ trip: Trip, in context: ModelContext) {
        // Journeys here that the server says left this trip (moved, unlinked) are on their own now.
        let legIDs = Set(trip.legs.map(\.id))
        for journey in (try? context.fetch(FetchDescriptor<Journey>())) ?? [] where journey.trip?.id == trip.id && !legIDs.contains(journey.id) {
            journey.trip = nil
            journey.connection = nil
        }
        for leg in trip.legs { upsert(leg, in: context) }
        try? context.save()
    }

    /// Refresh soon, e.g. an alert just arrived.
    func requestRefresh() {
        guard let context = context() else { return }
        Task { await refresh(in: context) }
    }

    /// Forgets every journey here (the user deleted their data on the server).
    func removeAll(in context: ModelContext) {
        try? context.delete(model: Journey.self)
        try? context.save()
        alarms?.cancelAll()
        pendingDeletes = []
        nextRefresh = nil
        lastError = nil
    }

    // MARK: - Refresh

    /// Brings the cache up to date. Concurrent calls share one refresh.
    func refresh(in context: ModelContext) async {
        if let refreshing { return await refreshing.value }
        let task = Task { await performRefresh(in: context) }
        refreshing = task
        await task.value
        refreshing = nil
    }

    private func performRefresh(in context: ModelContext) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await uploadLocalJourneys(in: context)
            await retryPendingDeletes()
            let upcoming = try await client.journeys(.upcoming)
            let past = try await client.journeys(.past)
            try await merge(upcoming.journeys + past.journeys, in: context)
            // Anything marked for upload meanwhile (the device registered again mid-refresh).
            try await uploadLocalJourneys(in: context)
            nextRefresh = upcoming.nextPollSeconds.map { Date.now.addingTimeInterval(TimeInterval($0)) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            nextRefresh = Date.now.addingTimeInterval(60) // try again soon
            Logger.tracks.error("Journey refresh failed: \(error.localizedDescription)")
        }
        try? context.save()
        // Stop alarms follow the new times (and go with journeys that went).
        if let alarms, lastError == nil {
            await alarms.sync((try? context.fetch(FetchDescriptor<Journey>())) ?? [])
        }
    }

    /// Journeys saved on the phone before they moved to the server (`syncedAt == nil`)
    /// are uploaded once. Ones the server can't take (no longer in the timetable,
    /// or stations not on the train's route) are dropped.
    private func uploadLocalJourneys(in context: ModelContext) async throws {
        let local = try context.fetch(FetchDescriptor<Journey>(predicate: #Predicate { $0.syncedAt == nil }))
        for journey in local {
            let uid = journey.trainUid
            do {
                let server = try await client.createJourney(CreateJourneyRequest(
                    trainUid: journey.trainUid,
                    runDate: journey.runDate,
                    fromCrs: journey.from.crs,
                    toCrs: journey.to.crs
                ))
                if server.id != journey.id { context.delete(journey) }
                upsert(server, in: context)
                Logger.tracks.info("Uploaded local journey \(uid) as \(server.id)")
            } catch let error as TracksError where [.trainNotRunning, .stationNotOnRoute, .validationFailed].contains(error.code) {
                Logger.tracks.info("Dropped local journey \(uid): \(error.message)")
                context.delete(journey)
            }
        }
    }

    private func retryPendingDeletes() async {
        for id in pendingDeletes {
            do {
                try await client.deleteJourney(id: id)
                pendingDeletes.remove(id)
            } catch let error as TracksError where error.code == .journeyNotFound {
                pendingDeletes.remove(id)
            } catch {
                return // still offline; try next time
            }
        }
    }

    /// Updates cached journeys from the list, fetches any the cache doesn't have,
    /// and removes synced ones the server no longer has (deleted, or beyond the past list).
    private func merge(_ items: [JourneyListItem], in context: ModelContext) async throws {
        let cached = try context.fetch(FetchDescriptor<Journey>())
        let byID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = pendingDeletes
        for item in items where !pending.contains(item.id) {
            if let journey = byID[item.id] {
                journey.update(from: item)
            } else {
                // Not cached (e.g. the app was reinstalled with the same Keychain): fetch the full journey.
                upsert(try await client.journey(id: item.id), in: context)
            }
        }
        let onServer = Set(items.map(\.id))
        for journey in cached where journey.syncedAt != nil && !onServer.contains(journey.id) {
            context.delete(journey)
        }
    }

    @discardableResult
    private func upsert(_ server: ServerJourney, in context: ModelContext) -> Journey {
        let id = server.id
        if let existing = try? context.fetch(FetchDescriptor<Journey>(predicate: #Predicate { $0.id == id })).first {
            existing.update(from: server)
            return existing
        }
        let journey = Journey(server)
        context.insert(journey)
        return journey
    }

    private var pendingDeletes: Set<UUID> {
        get { Set((UserDefaults.standard.stringArray(forKey: pendingDeletesKey) ?? []).compactMap(UUID.init)) }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: pendingDeletesKey) }
    }
}
