import Foundation
import Observation
import OSLog
import SwiftData

/// A trip's changes for the trip screen: each connection with the later trains
/// to switch to when it's at risk or missed. Refreshed at the pace of the legs'
/// live status (each leg's stops have their own JourneyDetailModel).
@Observable
final class TripDetailModel {
    let tripID: UUID
    private(set) var trip: Trip?
    private(set) var error: String?
    /// The alternative being switched to (`Departure.id`), while the server does it.
    private(set) var switching: String?

    private let sync: JourneySync

    init(tripID: UUID, sync: JourneySync = .shared) {
        self.tripID = tripID
        self.sync = sync
    }

    /// The latest for the change after leg `leg` (1 = the first train), with its alternatives.
    func connection(after leg: Int) -> TripConnection? {
        trip?.connections.first { $0.connection.leg == leg }
    }

    /// Refreshes until cancelled (the screen closing) or nothing more will change.
    func run(in context: ModelContext) async {
        while !Task.isCancelled {
            guard let next = await refresh(in: context) else { return }
            try? await Task.sleep(for: .seconds(next))
        }
    }

    /// Returns the seconds until the next refresh, or nil to stop.
    @discardableResult
    func refresh(in context: ModelContext) async -> Int? {
        do {
            let trip = try await sync.trip(id: tripID, in: context)
            self.trip = trip
            error = nil
            // Final once no leg will change on its own.
            return trip.legs.compactMap(\.live.nextPollSeconds).min()
        } catch let error as TracksError where error.code == .tripNotFound {
            // Unlinked elsewhere: the next list refresh shows the trains on their own.
            trip = nil
            sync.requestRefresh()
            return nil
        } catch {
            if Task.isCancelled { return nil }
            self.error = error.localizedDescription
            Logger.tracks.error("Trip \(self.tripID) failed: \(error.localizedDescription)")
            return 60
        }
    }

    /// "Switch to this train": the leg after the change becomes a journey on `departure`.
    func switchTo(_ departure: Departure, after connection: Connection, in context: ModelContext) async {
        switching = departure.id
        defer { switching = nil }
        do {
            trip = try await sync.switchLeg(tripID: tripID, leg: connection.leg + 1, to: departure, in: context)
            error = nil
        } catch {
            self.error = "Couldn't switch: \(error.localizedDescription)"
        }
    }
}
