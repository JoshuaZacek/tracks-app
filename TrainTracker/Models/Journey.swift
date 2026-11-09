import Foundation
import SwiftData

/// A saved journey: one train, from my boarding station to where I get off.
/// The tracks server is the source of truth (journeys are stored per device);
/// this is the app's cache of it, with the calling pattern and route snapshot,
/// so the list and map work without the network.
@Model
final class Journey {
    @Attribute(.unique) var id: UUID
    var savedAt: Date
    /// The date I depart from my boarding station ("YYYY-MM-DD").
    var date: String
    var trainUid: String
    /// Date the train started its run ("YYYY-MM-DD").
    var runDate: String
    var headcode: String
    var operatorCode: String
    var operatorName: String
    /// The train's full public calling pattern.
    var callingPoints: [CallingPoint]
    /// Index into callingPoints where I board.
    var fromIndex: Int
    /// Index where I get off (the final stop if no arrival station was given).
    var toIndex: Int
    /// Stations passed between calls, for the map.
    var route: [RoutePoint]
    /// Scheduled departure from my station; stored so lists can sort on it.
    var departsAt: Date
    /// When the server last confirmed this journey. Nil: saved on the phone
    /// before journeys moved to the server, still to be uploaded.
    var syncedAt: Date?
    /// Archived journeys show under Past.
    var archivedAt: Date?
    /// The server's live summary (state, delay, platform) from the last refresh.
    var live: LiveSummary?
    /// This journey's own alert settings (nil fields follow the device's).
    var prefs: JourneyPrefs?
    /// The regular journey this was made from (nil for one-off journeys).
    var templateId: UUID?
    /// Minutes to get to the station, for the leave-now alert.
    var travelMinutes: Int?
    /// The trip (a journey with changes) this is a leg of; nil on its own.
    var trip: TripLink?
    /// The change from this leg to the next of its trip; nil for the last leg, or no trip.
    var connection: Connection?
    /// Delay Repay this journey may be able to claim, once it's over.
    var claim: DelayRepayClaim?
    /// The public link while the journey is shared.
    var share: JourneyShare?

    init(id: UUID = UUID(), savedAt: Date = .now, date: String, train: TrainDetails, fromIndex: Int, toIndex: Int) {
        self.id = id
        self.savedAt = savedAt
        self.date = date
        self.trainUid = train.trainUid
        self.runDate = train.runDate
        self.headcode = train.headcode
        self.operatorCode = train.operator.code
        self.operatorName = train.operator.name
        self.callingPoints = train.callingPoints
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        self.route = train.route
        let from = train.callingPoints[fromIndex]
        self.departsAt = from.scheduledDeparture ?? from.scheduledArrival ?? .distantFuture
    }

    /// A journey as returned by the server.
    convenience init(_ server: ServerJourney, syncedAt: Date = .now) {
        let train = TrainDetails(
            trainUid: server.trainUid,
            runDate: server.runDate,
            headcode: server.headcode,
            operator: server.operator,
            callingPoints: server.callingPoints,
            route: server.route
        )
        self.init(id: server.id, savedAt: server.createdAt, date: server.date, train: train, fromIndex: server.fromIndex, toIndex: server.toIndex)
        self.syncedAt = syncedAt
        self.archivedAt = server.archivedAt
        self.live = LiveSummary(server.live)
        self.prefs = server.prefs
        self.templateId = server.templateId
        self.travelMinutes = server.travelMinutes
        self.trip = server.trip
        self.connection = server.connection
        self.claim = server.claim
        self.share = server.share
    }

    /// Takes the latest state from a full journey (after a save or change).
    func update(from server: ServerJourney, syncedAt: Date = .now) {
        archivedAt = server.archivedAt
        live = LiveSummary(server.live)
        prefs = server.prefs
        templateId = server.templateId
        travelMinutes = server.travelMinutes
        trip = server.trip
        connection = server.connection
        claim = server.claim
        share = server.share
        self.syncedAt = syncedAt
    }

    /// Takes the latest state from the journey list.
    func update(from item: JourneyListItem, syncedAt: Date = .now) {
        departsAt = item.scheduledDeparture
        archivedAt = item.archivedAt
        live = item.live
        prefs = item.prefs
        templateId = item.templateId
        travelMinutes = item.travelMinutes
        trip = item.trip
        connection = item.connection
        claim = item.claim
        share = item.share
        self.syncedAt = syncedAt
    }

    var from: CallingPoint { callingPoints[fromIndex] }
    var to: CallingPoint { callingPoints[toIndex] }

    /// Scheduled arrival at my destination.
    var arrivesAt: Date { to.scheduledArrival ?? to.scheduledDeparture ?? departsAt }

    /// Expected (else scheduled) arrival at my destination, from the last refresh.
    var expectedArrival: Date { live?.actualArrival ?? live?.expectedArrival ?? arrivesAt }

    /// The last train of its trip, or a journey on its own: a connecting train can follow it.
    var isLastLeg: Bool { trip.map { $0.leg == $0.legs } ?? true }

    /// "You may be able to claim": a claim the user hasn't marked as made.
    var showsClaimCard: Bool { claim.map { !$0.claimed } ?? false }

    /// A share link works until 6 hours after the scheduled arrival (the server's rule), so
    /// sharing is offered until then: not once the train has arrived, or the journey was put away.
    func canShare(now: Date = .now) -> Bool {
        archivedAt == nil && live?.state != .arrived && now < arrivesAt.addingTimeInterval(Self.shareAfterArrival)
    }

    static let shareAfterArrival: TimeInterval = 6 * 3600

    /// Calling points between boarding and alighting (exclusive).
    var intermediateStops: Int { max(0, toIndex - fromIndex - 1) }
}

extension LiveSummary {
    /// The list's summary, from a full live status (as returned when a journey is saved).
    init(_ status: LiveStatus) {
        self.init(
            state: status.state,
            expectedDeparture: status.service?.expectedDeparture,
            actualDeparture: status.service?.actualDeparture,
            expectedArrival: status.progress?.stops.last?.expected,
            actualArrival: status.progress?.stops.last?.actual,
            delayMinutes: status.service?.delayMinutes,
            platform: status.service?.platform,
            isCancelled: status.service?.isCancelled ?? (status.state == .cancelled),
            stale: status.stale,
            checkedAt: status.checkedAt,
            loading: status.loading
        )
    }
}
