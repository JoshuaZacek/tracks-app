import Foundation
import Observation
import OSLog

/// Live data for the journey detail screen: the journey's live status (state,
/// progress, position) and the train's live calling points (times at every
/// stop, for placing the train on the map). Refreshed at the server's pace.
@Observable
final class JourneyDetailModel {
    let journey: Journey
    private(set) var status: LiveStatus?
    /// The train's calling points with Darwin's live times; the saved snapshot until loaded.
    private(set) var liveCallingPoints: [CallingPoint]
    /// Station messages at my boarding station and destination (from the full
    /// journey, which is fetched less often than the live status).
    private(set) var stationMessages: [StationMessage] = []
    private(set) var error: String?
    /// When the station messages were last fetched.
    private var messagesFetchedAt: Date?
    /// Station messages change slowly and aren't in the live status, so they're fetched this often.
    static let messagesInterval: TimeInterval = 5 * 60

    private let client: TracksClient
    private let alarms: StopAlarm

    init(journey: Journey, client: TracksClient = .shared, alarms: StopAlarm = .shared) {
        self.journey = journey
        self.client = client
        self.alarms = alarms
        liveCallingPoints = journey.callingPoints
    }

    /// Refreshes until cancelled (the screen closing) or the server says nothing more will change.
    func run() async {
        while !Task.isCancelled {
            let next = await refresh()
            guard let next else { return }
            try? await Task.sleep(for: .seconds(next))
        }
    }

    /// Returns the seconds until the next refresh, or nil to stop. `force`
    /// (pull to refresh) fetches the station messages too, however recent.
    @discardableResult
    func refresh(force: Bool = false) async -> Int? {
        do {
            // Plain values, so the requests can run in parallel off the model object.
            let (id, uid, runDate) = (journey.id, journey.trainUid, journey.runDate)
            let wantsMessages = force || messagesFetchedAt.map { -$0.timeIntervalSinceNow >= Self.messagesInterval } ?? true
            async let status = client.liveStatus(journeyID: id)
            async let train = client.train(uid: uid, runDate: runDate)
            async let full = Self.journeyIfWanted(wantsMessages, id: id, client: client)
            let (fetched, t) = try await (status, train)
            if let full = await full {
                stationMessages = full.stationMessages
                messagesFetchedAt = .now
            }
            let s = withDebugSamples(fetched)
            self.status = s
            // Same run, so the same calling pattern as the saved snapshot (kept if it ever differs).
            if t.callingPoints.map(\.crs) == journey.callingPoints.map(\.crs) {
                liveCallingPoints = t.callingPoints
            }
            journey.live = LiveSummary(s) // the list shows the same state when going back
            await alarms.update(journey: journey)
            error = nil
            return s.nextPollSeconds
        } catch {
            if Task.isCancelled { return nil }
            self.error = error.localizedDescription
            Logger.tracks.error("Live status for \(self.journey.id) failed: \(error.localizedDescription)")
            return 60
        }
    }

    /// The full journey, for its station messages; nil when not wanted or it
    /// failed (not worth failing the refresh over: the last messages stay).
    private static func journeyIfWanted(_ wanted: Bool, id: UUID, client: TracksClient) async -> ServerJourney? {
        guard wanted else { return nil }
        return try? await client.journey(id: id)
    }

    /// `-sampleExtras` (Debug): a division, loading and a station message on
    /// every journey, to see them without a dividing train to hand.
    private func withDebugSamples(_ status: LiveStatus) -> LiveStatus {
        #if DEBUG
        guard DebugSeed.sampleExtras else { return status }
        if stationMessages.isEmpty { stationMessages = DebugSeed.sampleMessages(for: journey) }
        return DebugSeed.withSampleExtras(status, for: journey)
        #else
        return status
        #endif
    }

    var geometry: RouteGeometry {
        RouteGeometry(callingPoints: liveCallingPoints, route: journey.route)
    }
}
