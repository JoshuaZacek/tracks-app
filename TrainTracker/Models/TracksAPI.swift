import Foundation

// Types for the tracks server's /v1 API (~/Desktop/tracks-server,
// openapi/openapi.json). Names and fields match the OpenAPI components; dates
// are ISO 8601 with the UK offset and no fractional seconds, decoded with
// `.iso8601`.

nonisolated struct RegisterDeviceRequest: Encodable, Sendable {
    var appVersion: String
    var locale: String?
}

nonisolated struct RegisterDeviceResponse: Decodable, Sendable {
    var deviceId: UUID
    var token: String
}

nonisolated enum ApnsEnvironment: String, Codable, Sendable {
    case sandbox, production
}

nonisolated struct NotificationPrefs: Codable, Hashable, Sendable {
    var delays: Bool
    var platforms: Bool
    var cancellations: Bool
    var departure: Bool
    var arrival: Bool
    var delayThresholdMinutes: Int
}

nonisolated struct Device: Decodable, Sendable {
    var deviceId: UUID
    var apnsTokenRegistered: Bool
    var apnsEnvironment: ApnsEnvironment
    var pushToStartTokenRegistered: Bool
    var appVersion: String
    var locale: String?
    var prefs: NotificationPrefs
    var createdAt: Date
}

/// PATCH /v1/devices/me: only the fields set are sent (and changed).
nonisolated struct UpdateDeviceRequest: Encodable, Sendable {
    var appVersion: String?
    var locale: String?
    var apnsEnvironment: ApnsEnvironment?
}

nonisolated struct ServerStatus: Decodable, Sendable {
    struct Schedule: Decodable, Sendable {
        var loaded: Bool
        var importedAt: Date?
    }

    struct Worker: Decodable, Sendable {
        var lastHeartbeatAt: Date?
        var healthy: Bool
    }

    var version: String
    var serverTime: Date
    var schedule: Schedule
    var worker: Worker
}

/// The server's error body: `{ "error": { "code", "message", "details"? } }`.
nonisolated struct TracksError: LocalizedError, Sendable {
    /// Stable codes from the API; anything new decodes as `.unknown`.
    enum Code: String, Decodable, Sendable {
        case validationFailed = "validation_failed"
        case invalidJson = "invalid_json"
        case payloadTooLarge = "payload_too_large"
        case unauthorized
        case notFound = "not_found"
        case stationNotFound = "station_not_found"
        case trainNotRunning = "train_not_running"
        case journeyNotFound = "journey_not_found"
        case stationNotOnRoute = "station_not_on_route"
        case scheduleNotLoaded = "schedule_not_loaded"
        case rateLimited = "rate_limited"
        case notImplemented = "not_implemented"
        case serviceUnavailable = "service_unavailable"
        case internalError = "internal"
        case unknown

        init(from decoder: Decoder) throws {
            self = Code(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    var code: Code
    var message: String
    var httpStatus: Int

    var errorDescription: String? { message }
}

nonisolated struct TracksErrorBody: Decodable, Sendable {
    struct Inner: Decodable, Sendable {
        var code: TracksError.Code
        var message: String
    }

    var error: Inner
}

// MARK: - Reference data (Phase 2)

nonisolated struct Station: Codable, Hashable, Identifiable, Sendable {
    var crs: String
    var name: String
    var lat: Double?
    var lon: Double?
    var id: String { crs }
}

nonisolated struct NearbyStation: Codable, Hashable, Identifiable, Sendable {
    var crs: String
    var name: String
    var lat: Double?
    var lon: Double?
    var distanceMeters: Int
    var id: String { crs }
    var station: Station { Station(crs: crs, name: name, lat: lat, lon: lon) }
}

nonisolated struct Operator: Codable, Hashable, Sendable {
    var code: String
    var name: String
}

/// A platform, either from the timetable (booked) or from Darwin (live, possibly confirmed).
nonisolated struct Platform: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case booked, live }
    var number: String
    var source: Source
    var confirmed: Bool
}

nonisolated struct LiveDepartureInfo: Codable, Hashable, Sendable {
    var expectedDeparture: Date?
    var actualDeparture: Date?
    var delayMinutes: Int?
    var platform: Platform?
    var isCancelled: Bool
}

nonisolated struct Departure: Codable, Hashable, Identifiable, Sendable {
    struct Arrival: Codable, Hashable, Sendable {
        var station: Station
        var scheduledArrival: Date
    }

    var trainUid: String
    /// Date the train started its run (the day before the searched date for after-midnight calls).
    var runDate: String
    var headcode: String
    var `operator`: Operator
    var scheduledDeparture: Date
    var bookedPlatform: String?
    /// The train's final stop.
    var destination: Station
    /// Only set when the search had an arrival station.
    var arrival: Arrival?
    var live: LiveDepartureInfo?
    var id: String { "\(trainUid)|\(runDate)" }
}

nonisolated struct DeparturesResponse: Codable, Sendable {
    var date: String
    var from: Station
    var to: Station?
    var departures: [Departure]
    /// Pass back as `cursor` for the next page; nil on the last page.
    var nextCursor: String?
}

nonisolated struct CallingPointLive: Codable, Hashable, Sendable {
    var expectedArrival: Date?
    var expectedDeparture: Date?
    var actualArrival: Date?
    var actualDeparture: Date?
    var platform: Platform?
    var isCancelled: Bool
}

nonisolated struct CallingPoint: Codable, Hashable, Sendable {
    var crs: String
    var name: String
    var lat: Double?
    var lon: Double?
    /// Nil at the origin.
    var scheduledArrival: Date?
    /// Nil at the final stop.
    var scheduledDeparture: Date?
    var bookedPlatform: String?
    var live: CallingPointLive?
}

/// A station the train passes without stopping, `f` (0...1) of the way along
/// the leg that starts at `callingPoints[leg]`, by timetabled times.
nonisolated struct RoutePoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    var leg: Int
    var f: Double
}

nonisolated struct TrainDetails: Codable, Sendable {
    var trainUid: String
    var runDate: String
    var headcode: String
    var `operator`: Operator
    var callingPoints: [CallingPoint]
    var route: [RoutePoint]
}

nonisolated struct StationList: Decodable, Sendable {
    var stations: [Station]
}

nonisolated struct NearbyStationList: Decodable, Sendable {
    var stations: [NearbyStation]
}

// MARK: - Live summary (filled in from server Phase 4)

nonisolated enum LiveState: String, Codable, Sendable {
    case scheduled, live, departed, arrived, cancelled
    case notFound = "not_found"
}

/// The short live state carried by each journey in the list.
nonisolated struct LiveSummary: Codable, Hashable, Sendable {
    var state: LiveState
    var expectedDeparture: Date?
    var actualDeparture: Date?
    /// At my destination.
    var expectedArrival: Date?
    var actualArrival: Date?
    var delayMinutes: Int?
    /// Live platform at my boarding station.
    var platform: Platform?
    var isCancelled: Bool
    var stale: Bool
    var checkedAt: Date?
}

// MARK: - Journeys (Phase 3)

/// Per-journey notification overrides; unset fields follow the device's prefs.
nonisolated struct JourneyPrefs: Codable, Hashable, Sendable {
    var delays: Bool?
    var platforms: Bool?
    var cancellations: Bool?
    var departure: Bool?
    var arrival: Bool?
    var delayThresholdMinutes: Int?
}

nonisolated struct CreateJourneyRequest: Encodable, Sendable {
    var trainUid: String
    var runDate: String
    var fromCrs: String
    /// Omitted: the train's final stop.
    var toCrs: String?
}

/// PATCH /v1/journeys/{id}. (Per-journey notification prefs come with push, in Phase 5.)
nonisolated struct UpdateJourneyRequest: Encodable, Sendable {
    var archived: Bool?
}

/// A saved journey as the server stores it, with its calling pattern snapshot and live status.
nonisolated struct ServerJourney: Decodable, Sendable {
    var id: UUID
    var trainUid: String
    var runDate: String
    /// The UK date I leave my station.
    var date: String
    var headcode: String
    var `operator`: Operator
    var from: Station
    var to: Station
    var scheduledDeparture: Date
    var scheduledArrival: Date
    var bookedPlatform: String?
    var prefs: JourneyPrefs
    var createdAt: Date
    var archivedAt: Date?
    var callingPoints: [CallingPoint]
    var fromIndex: Int
    var toIndex: Int
    var route: [RoutePoint]
    var live: LiveStatus
}

/// A journey in the list: everything a card needs, without the calling pattern.
nonisolated struct JourneyListItem: Decodable, Sendable {
    var id: UUID
    var trainUid: String
    var runDate: String
    var date: String
    var headcode: String
    var `operator`: Operator
    var from: Station
    var to: Station
    var scheduledDeparture: Date
    var scheduledArrival: Date
    var bookedPlatform: String?
    var prefs: JourneyPrefs
    var createdAt: Date
    var archivedAt: Date?
    var live: LiveSummary
}

nonisolated struct JourneyList: Decodable, Sendable {
    var journeys: [JourneyListItem]
    /// The soonest the list could change on its own; nil when nothing upcoming will.
    var nextPollSeconds: Int?
}

nonisolated enum JourneyScope: String, Sendable {
    case upcoming, past
}

// MARK: - Live status (filled in by Darwin from server Phase 4)

nonisolated struct LiveService: Codable, Hashable, Sendable {
    var rid: String?
    var scheduledDeparture: Date
    var expectedDeparture: Date?
    var actualDeparture: Date?
    var delayMinutes: Int?
    var platform: Platform?
    var isCancelled: Bool
    var cancelReason: String?
    var delayReason: String?
}

nonisolated struct ProgressStop: Codable, Hashable, Sendable {
    var crs: String
    var name: String
    var scheduled: Date
    var expected: Date?
    var actual: Date?
    var passed: Bool
    var isCancelled: Bool
    var delayMinutes: Int?
    var platform: Platform?
}

nonisolated struct JourneyProgress: Codable, Hashable, Sendable {
    /// My boarding station first, my destination last.
    var stops: [ProgressStop]
    var lastPassedIndex: Int
    var nextIndex: Int?
    var arrived: Bool
}

/// Where the train is: its latest report and next expected location. The app
/// moves the marker between them along the route by time.
nonisolated struct TrainPosition: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable { case darwin, trust }

    struct Report: Codable, Hashable, Sendable {
        enum Event: String, Codable, Sendable { case arrival, departure, pass }
        var tiploc: String
        var crs: String?
        var name: String
        var lat: Double?
        var lon: Double?
        var time: Date
        var event: Event
    }

    struct Next: Codable, Hashable, Sendable {
        var tiploc: String
        var crs: String?
        var name: String
        var lat: Double?
        var lon: Double?
        var expectedTime: Date
    }

    var source: Source
    var last: Report
    var next: Next?
    var legFrom: String
    var legTo: String
}

nonisolated struct LiveStatus: Codable, Hashable, Sendable {
    var state: LiveState
    var checkedAt: Date
    /// When to ask again; nil means it won't change on its own.
    var nextPollSeconds: Int?
    /// The live feed has stopped; this is the last known data.
    var stale: Bool
    var message: String?
    var service: LiveService?
    var progress: JourneyProgress?
    var position: TrainPosition?
}
