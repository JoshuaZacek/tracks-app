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

/// A value to send in a PATCH where JSON `null` means "clear it": `.value(x)`
/// sets it, `.null` clears it, and leaving the Optional field nil omits it.
nonisolated enum Nullable<Wrapped: Encodable & Sendable>: Encodable, Sendable {
    case value(Wrapped)
    case null

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .value(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// The device's alert settings (defaults for every journey).
nonisolated struct NotificationPrefs: Codable, Hashable, Sendable {
    var delays: Bool
    var platforms: Bool
    var cancellations: Bool
    var departure: Bool
    var arrival: Bool
    /// 1...60.
    var delayThresholdMinutes: Int
    /// Start a Live Activity by push 30 min before departure.
    var liveActivity: Bool
    /// How a regular journey's train is running, at the time chosen on it.
    var morningSummary: Bool
    /// When to set off for the station, for journeys with a travel time.
    var leaveNow: Bool

    init(delays: Bool, platforms: Bool, cancellations: Bool, departure: Bool, arrival: Bool, delayThresholdMinutes: Int, liveActivity: Bool, morningSummary: Bool = true, leaveNow: Bool = true) {
        self.delays = delays
        self.platforms = platforms
        self.cancellations = cancellations
        self.departure = departure
        self.arrival = arrival
        self.delayThresholdMinutes = delayThresholdMinutes
        self.liveActivity = liveActivity
        self.morningSummary = morningSummary
        self.leaveNow = leaveNow
    }

    private enum CodingKeys: String, CodingKey {
        case delays, platforms, cancellations, departure, arrival, delayThresholdMinutes, liveActivity, morningSummary, leaveNow
    }

    // Servers from before regular journeys don't send the last two: both default to on.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delays = try c.decode(Bool.self, forKey: .delays)
        platforms = try c.decode(Bool.self, forKey: .platforms)
        cancellations = try c.decode(Bool.self, forKey: .cancellations)
        departure = try c.decode(Bool.self, forKey: .departure)
        arrival = try c.decode(Bool.self, forKey: .arrival)
        delayThresholdMinutes = try c.decode(Int.self, forKey: .delayThresholdMinutes)
        liveActivity = try c.decode(Bool.self, forKey: .liveActivity)
        morningSummary = try c.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? true
        leaveNow = try c.decodeIfPresent(Bool.self, forKey: .leaveNow) ?? true
    }

    static let thresholdRange = 1...60

    /// The server's defaults, for display before the device has been fetched.
    static let defaults = NotificationPrefs(delays: true, platforms: true, cancellations: true, departure: true, arrival: true, delayThresholdMinutes: 5, liveActivity: true)
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
    /// The host for all of this device's tokens: sandbox for debug builds.
    var apnsEnvironment: ApnsEnvironment?
    /// Hex; `.null` clears it.
    var apnsToken: Nullable<String>?
    /// Live Activity push-to-start token, hex; `.null` clears it.
    var pushToStartToken: Nullable<String>?
    /// Only the prefs set are changed (the server merges them).
    var prefs: NotificationPrefs?
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

    struct Push: Decodable, Sendable {
        /// False until the server has an APNs key; alerts are then only logged.
        var enabled: Bool
        var sentLastHour: Int
        var failedLastHour: Int
    }

    var version: String
    var serverTime: Date
    var schedule: Schedule
    var worker: Worker
    var push: Push?
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
        case templateNotFound = "template_not_found"
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
    /// Signalling or staff confirmed the train is in it. Only some stations ever
    /// send this (Waterloo and Leeds never do), so unconfirmed isn't unreliable.
    var confirmed: Bool
    /// Darwin knows it but the station hasn't announced it yet (e.g. Euston keeps
    /// platforms off its boards until boarding).
    var hidden: Bool

    init(number: String, source: Source, confirmed: Bool, hidden: Bool = false) {
        self.number = number
        self.source = source
        self.confirmed = confirmed
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case number, source, confirmed, hidden }

    // `hidden` is missing from responses cached before the server sent it.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(String.self, forKey: .number)
        source = try c.decode(Source.self, forKey: .source)
        confirmed = try c.decode(Bool.self, forKey: .confirmed)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
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
/// A journey's own alert settings; nil fields follow the device's (except
/// `stopAlarm`, which only journeys have).
nonisolated struct JourneyPrefs: Codable, Hashable, Sendable {
    var delays: Bool?
    var platforms: Bool?
    var cancellations: Bool?
    var departure: Bool?
    var arrival: Bool?
    var delayThresholdMinutes: Int?
    var liveActivity: Bool?
    /// "Wake me before my stop": journey-only (the device has no default); nil is off.
    var stopAlarm: Bool?
    var morningSummary: Bool?
    var leaveNow: Bool?

    /// What applies to the journey: its own setting where it has one, else the device's.
    func applied(over device: NotificationPrefs) -> NotificationPrefs {
        NotificationPrefs(
            delays: delays ?? device.delays,
            platforms: platforms ?? device.platforms,
            cancellations: cancellations ?? device.cancellations,
            departure: departure ?? device.departure,
            arrival: arrival ?? device.arrival,
            delayThresholdMinutes: delayThresholdMinutes ?? device.delayThresholdMinutes,
            liveActivity: liveActivity ?? device.liveActivity,
            morningSummary: morningSummary ?? device.morningSummary,
            leaveNow: leaveNow ?? device.leaveNow
        )
    }

    /// Every field, with JSON null for the ones following the device, so the
    /// server ends up with exactly these overrides.
    var replacingAll: JourneyPrefsUpdate {
        func n<T>(_ v: T?) -> Nullable<T>? { v.map { .value($0) } ?? .null }
        return JourneyPrefsUpdate(
            delays: n(delays), platforms: n(platforms), cancellations: n(cancellations),
            departure: n(departure), arrival: n(arrival),
            delayThresholdMinutes: n(delayThresholdMinutes), liveActivity: n(liveActivity),
            stopAlarm: n(stopAlarm),
            morningSummary: n(morningSummary), leaveNow: n(leaveNow)
        )
    }
}

/// PATCH a journey's prefs: `.value` overrides, `.null` goes back to the device's, nil leaves it.
nonisolated struct JourneyPrefsUpdate: Encodable, Sendable {
    var delays: Nullable<Bool>?
    var platforms: Nullable<Bool>?
    var cancellations: Nullable<Bool>?
    var departure: Nullable<Bool>?
    var arrival: Nullable<Bool>?
    var delayThresholdMinutes: Nullable<Int>?
    var liveActivity: Nullable<Bool>?
    /// `.null` turns the stop alarm off.
    var stopAlarm: Nullable<Bool>?
    var morningSummary: Nullable<Bool>?
    var leaveNow: Nullable<Bool>?
}

/// PUT /v1/journeys/{id}/live-activity.
nonisolated struct RegisterLiveActivityRequest: Encodable, Sendable {
    /// The activity's push token, hex.
    var pushToken: String
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
    var prefs: JourneyPrefsUpdate?
    /// Minutes to get to the station (0...240); `.null` clears it.
    var travelMinutes: Nullable<Int>?
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
    /// The regular journey this was made from, if any.
    var templateId: UUID?
    /// Minutes to get to the station, for the leave-now alert.
    var travelMinutes: Int?
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
    var templateId: UUID?
    var travelMinutes: Int?
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

// MARK: - Regular journeys (Sprint 1)

/// A regular journey: the server adds a journey for each day in `days`, the
/// day before, choosing the train from `from` to `to` nearest `departTime`.
nonisolated struct JourneyTemplate: Decodable, Hashable, Identifiable, Sendable {
    /// The last time no train matched.
    struct Problem: Decodable, Hashable, Sendable {
        var date: String
        var message: String
    }

    /// The soonest upcoming journey made from it.
    struct NextJourney: Decodable, Hashable, Sendable {
        var id: UUID
        var date: String
        var scheduledDeparture: Date
    }

    var id: UUID
    var from: Station
    var to: Station
    /// "HH:MM", UK time.
    var departTime: String
    /// ISO weekdays, 1 = Monday ... 7 = Sunday.
    var days: [Int]
    /// The last train matched (a hint only; UIDs change with the timetable).
    var trainUid: String?
    var travelMinutes: Int?
    /// "HH:MM" to send the morning summary; nil for none.
    var summaryTime: String?
    var prefs: JourneyPrefs
    var problem: Problem?
    var nextJourney: NextJourney?
    var createdAt: Date
}

nonisolated struct JourneyTemplateList: Decodable, Sendable {
    var templates: [JourneyTemplate]
}

/// POST /v1/journey-templates. Unset fields are left out.
nonisolated struct CreateJourneyTemplateRequest: Encodable, Sendable {
    var fromCrs: String
    var toCrs: String
    var departTime: String
    var days: [Int]
    var trainUid: String?
    var travelMinutes: Int?
    var summaryTime: String?
    var prefs: JourneyPrefs?
    /// The journey it repeats: linked to the new template, and its travel time
    /// and prefs are the defaults.
    var journeyId: UUID?

    private enum CodingKeys: String, CodingKey {
        case fromCrs, toCrs, departTime, days, trainUid, travelMinutes, summaryTime, prefs, journeyId
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fromCrs, forKey: .fromCrs)
        try c.encode(toCrs, forKey: .toCrs)
        try c.encode(departTime, forKey: .departTime)
        try c.encode(days, forKey: .days)
        try c.encodeIfPresent(trainUid, forKey: .trainUid)
        try c.encodeIfPresent(travelMinutes, forKey: .travelMinutes)
        try c.encodeIfPresent(summaryTime, forKey: .summaryTime)
        try c.encodeIfPresent(prefs, forKey: .prefs)
        // Lowercase, as in the server's responses and paths.
        try c.encodeIfPresent(journeyId?.uuidString.lowercased(), forKey: .journeyId)
    }
}

/// PATCH /v1/journey-templates/{id}: only the fields set are changed; `.null` clears.
/// Journeys already made keep their time and days.
nonisolated struct UpdateJourneyTemplateRequest: Encodable, Sendable {
    var departTime: String?
    var days: [Int]?
    var travelMinutes: Nullable<Int>?
    var summaryTime: Nullable<String>?
    var prefs: JourneyPrefsUpdate?
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
