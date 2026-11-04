import ActivityKit
import Foundation

/// A train journey as a Live Activity. Shared by the app (which starts
/// activities and reports their push tokens) and the widget extension (which
/// draws them). The tracks server pushes updates in exactly this shape: the
/// attributes-type is "TrainActivityAttributes", and the field names below
/// are the JSON keys.
nonisolated struct TrainActivityAttributes: ActivityAttributes, Sendable {
    /// Fixed for the activity's life.
    var journeyId: UUID
    var headcode: String
    var operatorName: String
    var fromCrs: String
    var fromName: String
    var toCrs: String
    var toName: String

    /// What changes. Times are ISO 8601 strings with an offset on the wire (as
    /// in the API), not ActivityKit's default seconds-since-2001, so this type
    /// encodes and decodes them itself.
    struct ContentState: Codable, Hashable, Sendable {
        /// The server's live state; anything new decodes as `.unknown`.
        enum Phase: String, Codable, Hashable, Sendable {
            case scheduled, live, departed, arrived, cancelled
            case notFound = "not_found"
            case unknown

            init(from decoder: any Decoder) throws {
                self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        struct Platform: Codable, Hashable, Sendable {
            var number: String
            var confirmed: Bool
            /// Known to Darwin, not yet announced at the station.
            var hidden: Bool

            init(number: String, confirmed: Bool, hidden: Bool = false) {
                self.number = number
                self.confirmed = confirmed
                self.hidden = hidden
            }

            private enum CodingKeys: String, CodingKey { case number, confirmed, hidden }

            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                number = try c.decode(String.self, forKey: .number)
                confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
                hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
            }
        }

        var state: Phase
        var scheduledDeparture: Date
        var expectedDeparture: Date?
        var actualDeparture: Date?
        /// At my destination.
        var scheduledArrival: Date
        var expectedArrival: Date?
        var actualArrival: Date?
        /// Departure delay until the train leaves, then the arrival delay at my destination.
        var delayMinutes: Int?
        /// The boarding platform before departure, then the destination's.
        var platform: Platform?
        var isCancelled: Bool
        var message: String?
        /// While departed: the next stop on my journey and the current leg's times.
        var nextStopName: String?
        var legDepartedAt: Date?
        var nextExpectedAt: Date?

        init(
            state: Phase,
            scheduledDeparture: Date,
            expectedDeparture: Date? = nil,
            actualDeparture: Date? = nil,
            scheduledArrival: Date,
            expectedArrival: Date? = nil,
            actualArrival: Date? = nil,
            delayMinutes: Int? = nil,
            platform: Platform? = nil,
            isCancelled: Bool = false,
            message: String? = nil,
            nextStopName: String? = nil,
            legDepartedAt: Date? = nil,
            nextExpectedAt: Date? = nil
        ) {
            self.state = state
            self.scheduledDeparture = scheduledDeparture
            self.expectedDeparture = expectedDeparture
            self.actualDeparture = actualDeparture
            self.scheduledArrival = scheduledArrival
            self.expectedArrival = expectedArrival
            self.actualArrival = actualArrival
            self.delayMinutes = delayMinutes
            self.platform = platform
            self.isCancelled = isCancelled
            self.message = message
            self.nextStopName = nextStopName
            self.legDepartedAt = legDepartedAt
            self.nextExpectedAt = nextExpectedAt
        }

        private enum CodingKeys: String, CodingKey {
            case state, scheduledDeparture, expectedDeparture, actualDeparture
            case scheduledArrival, expectedArrival, actualArrival
            case delayMinutes, platform, isCancelled, message
            case nextStopName, legDepartedAt, nextExpectedAt
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(Phase.self, forKey: .state)
            scheduledDeparture = try Self.date(c, .scheduledDeparture)
            expectedDeparture = try Self.optionalDate(c, .expectedDeparture)
            actualDeparture = try Self.optionalDate(c, .actualDeparture)
            scheduledArrival = try Self.date(c, .scheduledArrival)
            expectedArrival = try Self.optionalDate(c, .expectedArrival)
            actualArrival = try Self.optionalDate(c, .actualArrival)
            delayMinutes = try c.decodeIfPresent(Int.self, forKey: .delayMinutes)
            platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
            isCancelled = try c.decodeIfPresent(Bool.self, forKey: .isCancelled) ?? false
            message = try c.decodeIfPresent(String.self, forKey: .message)
            nextStopName = try c.decodeIfPresent(String.self, forKey: .nextStopName)
            legDepartedAt = try Self.optionalDate(c, .legDepartedAt)
            nextExpectedAt = try Self.optionalDate(c, .nextExpectedAt)
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(state.rawValue, forKey: .state)
            try c.encode(Self.iso(scheduledDeparture), forKey: .scheduledDeparture)
            try c.encodeIfPresent(expectedDeparture.map(Self.iso), forKey: .expectedDeparture)
            try c.encodeIfPresent(actualDeparture.map(Self.iso), forKey: .actualDeparture)
            try c.encode(Self.iso(scheduledArrival), forKey: .scheduledArrival)
            try c.encodeIfPresent(expectedArrival.map(Self.iso), forKey: .expectedArrival)
            try c.encodeIfPresent(actualArrival.map(Self.iso), forKey: .actualArrival)
            try c.encodeIfPresent(delayMinutes, forKey: .delayMinutes)
            try c.encodeIfPresent(platform, forKey: .platform)
            try c.encode(isCancelled, forKey: .isCancelled)
            try c.encodeIfPresent(message, forKey: .message)
            try c.encodeIfPresent(nextStopName, forKey: .nextStopName)
            try c.encodeIfPresent(legDepartedAt.map(Self.iso), forKey: .legDepartedAt)
            try c.encodeIfPresent(nextExpectedAt.map(Self.iso), forKey: .nextExpectedAt)
        }

        // MARK: ISO 8601 times

        private static func iso(_ date: Date) -> String {
            date.formatted(.iso8601)
        }

        /// "2026-11-03T10:43:00+00:00" (or a number of seconds since 2001, in
        /// case ActivityKit ever hands back its own encoding).
        private static func parse(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date? {
            if try !c.contains(key) || c.decodeNil(forKey: key) { return nil }
            if let text = try? c.decode(String.self, forKey: key) {
                guard let date = try? Date(text, strategy: .iso8601) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not an ISO 8601 time: \(text)")
                }
                return date
            }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self, forKey: key))
        }

        private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
            guard let date = try parse(c, key) else {
                throw DecodingError.valueNotFound(Date.self, .init(codingPath: c.codingPath + [key], debugDescription: "Missing \(key.stringValue)"))
            }
            return date
        }

        private static func optionalDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date? {
            try parse(c, key)
        }
    }
}

// MARK: - What the activity shows

extension TrainActivityAttributes.ContentState {
    var departed: Bool { state == .departed || state == .arrived || actualDeparture != nil }
    var cancelled: Bool { isCancelled || state == .cancelled }
    var finished: Bool { state == .arrived || cancelled || state == .notFound }

    /// Best known departure and arrival.
    var departureTime: Date { actualDeparture ?? expectedDeparture ?? scheduledDeparture }
    var arrivalTime: Date { actualArrival ?? expectedArrival ?? scheduledArrival }

    var isLate: Bool { (delayMinutes ?? 0) > 0 }

    /// "On time", "5 min late", "Cancelled", "Arrived".
    var statusText: String {
        if cancelled { return "Cancelled" }
        switch state {
        case .arrived:
            if let delay = delayMinutes, delay > 0 { return "Arrived \(delay) min late" }
            return "Arrived"
        case .notFound:
            return "No live data"
        default:
            if let delay = delayMinutes, delay > 0 { return "\(delay) min late" }
            if let delay = delayMinutes, delay < 0 { return "\(-delay) min early" }
            return "On time"
        }
    }

    /// 0...1 through the whole journey by time, for the progress bar.
    func journeyProgress(at now: Date) -> Double {
        if state == .arrived { return 1 }
        guard departed else { return 0 }
        let span = arrivalTime.timeIntervalSince(departureTime)
        guard span > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(departureTime) / span))
    }
}
