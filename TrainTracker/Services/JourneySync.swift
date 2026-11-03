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
    static let shared = JourneySync()

    private let client: TracksClient
    private(set) var isRefreshing = false
    /// Set when the last refresh couldn't reach the server (the list shows the cache).
    private(set) var lastError: String?
    /// When the journey list could next change on its own, per the server.
    private(set) var nextRefresh: Date?
    private var refreshing: Task<Void, Never>?

    private let pendingDeletesKey = "pendingJourneyDeletes"

    init(client: TracksClient = .shared) {
        self.client = client
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
        context.delete(journey)
        try? context.save()
        await LiveActivities.shared.end(journeyID: id)
        guard wasOnServer else { return }
        do {
            try await client.deleteJourney(id: id)
        } catch let error as TracksError where error.code == .journeyNotFound {
            // Already gone.
        } catch {
            pendingDeletes.insert(id)
            Logger.tracks.info("Delete of \(id) queued: \(error.localizedDescription)")
        }
    }

    func setArchived(_ archived: Bool, for journey: Journey, in context: ModelContext) async throws {
        let server = try await client.updateJourney(id: journey.id, UpdateJourneyRequest(archived: archived))
        journey.archivedAt = server.archivedAt
        journey.live = LiveSummary(server.live)
        journey.syncedAt = .now
        try? context.save()
        // Archived journeys don't update, so their activity would only go stale.
        if archived { await LiveActivities.shared.end(journeyID: journey.id) }
    }

    /// Sets the journey's own alert settings (nil fields follow the device's).
    func setPrefs(_ prefs: JourneyPrefs, for journey: Journey, in context: ModelContext) async throws {
        let server = try await client.updateJourney(id: journey.id, UpdateJourneyRequest(prefs: prefs.replacingAll))
        journey.prefs = server.prefs
        journey.live = LiveSummary(server.live)
        journey.syncedAt = .now
        try? context.save()
    }

    /// Refresh soon, e.g. an alert just arrived.
    func requestRefresh() {
        Task { await refresh(in: JourneyStore.context) }
    }

    /// Forgets every journey here (the user deleted their data on the server).
    func removeAll(in context: ModelContext) {
        try? context.delete(model: Journey.self)
        try? context.save()
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
            nextRefresh = upcoming.nextPollSeconds.map { Date.now.addingTimeInterval(TimeInterval($0)) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            nextRefresh = Date.now.addingTimeInterval(60) // try again soon
            Logger.tracks.error("Journey refresh failed: \(error.localizedDescription)")
        }
        try? context.save()
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
            existing.archivedAt = server.archivedAt
            existing.live = LiveSummary(server.live)
            existing.syncedAt = .now
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
