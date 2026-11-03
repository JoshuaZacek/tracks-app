import Foundation

/// What a journey card shows, from the journey and the server's live summary.
/// Kept apart from the view so the rules can be tested.
struct JourneyCardModel: Equatable {
    enum Tone: Equatable {
        case normal, late, cancelled
    }

    /// Departure time to show: actual, else expected, else scheduled.
    var time: String
    var timeTone: Tone
    /// Live platform when Darwin has one, else the booked one.
    var platform: String?
    /// Booked, live (and whether confirmed), or changed from the booked platform.
    var platformKind: PlatformBadge.Kind
    /// Share of the trip completed (0...1) once the train has left; nil before.
    var progress: Double?
    /// "in 43 min", "leaves in 12 min", "Arrived 11:27", "Cancelled".
    var status: String?
    var statusTone: Tone
    /// "Last updated 10:17" when the live feed has gone quiet.
    var staleNote: String?

    /// Countdowns start this long before departure (the Live section's window).
    static let countdownWindow: TimeInterval = JourneySections.leavingSoon

    init(journey: Journey, now: Date = .now) {
        let live = journey.live
        let departure = live?.actualDeparture ?? live?.expectedDeparture ?? journey.departsAt
        let arrival = live?.actualArrival ?? live?.expectedArrival ?? journey.arrivesAt
        let late = (live?.delayMinutes ?? 0) > 0
        let cancelled = live?.state == .cancelled || (live?.isCancelled ?? false)

        time = RailTime.hhmm(departure)
        timeTone = cancelled ? .cancelled : late ? .late : .normal
        let booked = journey.from.bookedPlatform
        if let livePlatform = live?.platform {
            platform = livePlatform.number
            if let booked, booked != livePlatform.number {
                platformKind = .changed(from: booked, confirmed: livePlatform.confirmed)
            } else {
                platformKind = .live(confirmed: livePlatform.confirmed)
            }
        } else {
            platform = booked
            platformKind = .booked
        }
        progress = nil
        status = nil
        statusTone = .normal
        staleNote = live.flatMap { $0.stale ? $0.checkedAt.map { "Last updated \(RailTime.hhmm($0))" } : nil }

        if cancelled {
            status = "Cancelled"
            statusTone = .cancelled
            return
        }
        switch live?.state {
        case .arrived:
            progress = 1
            status = "Arrived \(RailTime.hhmm(arrival))"
        case .departed:
            let span = arrival.timeIntervalSince(departure)
            progress = span > 0 ? min(1, max(0, now.timeIntervalSince(departure) / span)) : 1
            let minutes = Self.wholeMinutes(until: arrival, from: now)
            status = minutes > 0 ? "in \(Self.duration(minutes))" : "Arriving"
        default:
            // Not left yet: count down to departure within the hour.
            let untilDeparture = departure.timeIntervalSince(now)
            if untilDeparture <= Self.countdownWindow, journey.arrivesAt > now {
                let minutes = Self.wholeMinutes(until: departure, from: now)
                status = minutes > 0 ? "leaves in \(Self.duration(minutes))" : "Due to leave"
                statusTone = late ? .late : .normal
            }
        }
    }

    /// Minutes until a moment, rounded up so "in 1 min" lasts until it's due.
    private static func wholeMinutes(until date: Date, from now: Date) -> Int {
        Int((date.timeIntervalSince(now) / 60).rounded(.up))
    }

    /// "43 min", "1 h 05 min".
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}
