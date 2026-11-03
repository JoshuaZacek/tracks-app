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
    private(set) var error: String?
    private(set) var placeIndex: PlaceIndex?

    private let client: TracksClient

    init(journey: Journey, client: TracksClient = .shared) {
        self.journey = journey
        self.client = client
        liveCallingPoints = journey.callingPoints
    }

    /// Refreshes until cancelled (the screen closing) or the server says nothing more will change.
    func run() async {
        placeIndex = await PlacesStore.shared.placeIndex()
        while !Task.isCancelled {
            let next = await refresh()
            guard let next else { return }
            try? await Task.sleep(for: .seconds(next))
        }
    }

    /// Returns the seconds until the next refresh, or nil to stop.
    @discardableResult
    func refresh() async -> Int? {
        do {
            // Plain values, so the two requests can run in parallel off the model object.
            let (id, uid, runDate) = (journey.id, journey.trainUid, journey.runDate)
            async let status = client.liveStatus(journeyID: id)
            async let train = client.train(uid: uid, runDate: runDate)
            let (s, t) = try await (status, train)
            self.status = s
            // Same run, so the same calling pattern as the saved snapshot (kept if it ever differs).
            if t.callingPoints.map(\.crs) == journey.callingPoints.map(\.crs) {
                liveCallingPoints = t.callingPoints
            }
            journey.live = LiveSummary(s) // the list shows the same state when going back
            error = nil
            return s.nextPollSeconds
        } catch {
            if Task.isCancelled { return nil }
            self.error = error.localizedDescription
            Logger.tracks.error("Live status for \(self.journey.id) failed: \(error.localizedDescription)")
            return 60
        }
    }

    var geometry: RouteGeometry {
        RouteGeometry(callingPoints: liveCallingPoints, route: journey.route)
    }
}
