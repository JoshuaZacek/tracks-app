import Foundation

enum JourneySection: Equatable {
    case live, upcoming, past
}

/// Journeys under one day heading ("Today", "Friday", ...).
struct JourneyGroup: Identifiable {
    let label: String
    let journeys: [Journey]
    var id: String { label }
}

/// The Journeys screen's sections, each grouped by the day I depart.
struct JourneySections {
    var live: [JourneyGroup] = []
    var upcoming: [JourneyGroup] = []
    var past: [JourneyGroup] = []

    /// "Leaving soon" journeys join Live this long before departure.
    static let leavingSoon: TimeInterval = 60 * 60

    /// Live states meaning the train is still running, so a late train stays out
    /// of Past after its timetabled arrival (as in the web app).
    private static let stillRunning: Set<LiveState> = [.live, .departed]

    init(journeys: [Journey], statuses: [UUID: LiveSummary] = [:], now: Date = .now) {
        var buckets: [JourneySection: [Journey]] = [:]
        for j in journeys {
            buckets[Self.section(of: j, status: statuses[j.id], now: now), default: []].append(j)
        }
        live = Self.group(buckets[.live, default: []].sorted { $0.departsAt < $1.departsAt }, now: now)
        upcoming = Self.group(buckets[.upcoming, default: []].sorted { $0.departsAt < $1.departsAt }, now: now)
        past = Self.group(buckets[.past, default: []].sorted { $0.departsAt > $1.departsAt }, now: now)
    }

    var isEmpty: Bool { live.isEmpty && upcoming.isEmpty && past.isEmpty }

    /// Live: underway, or leaving within the hour. Past: archived, arrived, or past
    /// the timetabled arrival with no live data saying the train is still running
    /// (the server's `scope=past` rule, applied here too so the list works offline).
    static func section(of j: Journey, status: LiveSummary?, now: Date) -> JourneySection {
        if j.archivedAt != nil { return .past }
        switch status?.state {
        case .arrived: return .past
        case .departed: return .live
        default: break
        }
        if j.arrivesAt <= now {
            let cancelled = status?.isCancelled ?? false
            if let state = status?.state, stillRunning.contains(state), !cancelled { return .live }
            return .past
        }
        if j.departsAt.timeIntervalSince(now) <= leavingSoon { return .live }
        return .upcoming
    }

    private static func group(_ journeys: [Journey], now: Date) -> [JourneyGroup] {
        var groups: [JourneyGroup] = []
        for j in journeys {
            let label = RailTime.dayLabel(for: j.departsAt, now: now)
            if let last = groups.last, last.label == label {
                groups[groups.count - 1] = JourneyGroup(label: label, journeys: last.journeys + [j])
            } else {
                groups.append(JourneyGroup(label: label, journeys: [j]))
            }
        }
        return groups
    }
}

/// The search filter: every word must match a station (CRS or name) between
/// boarding and alighting, the headcode or the operator.
enum JourneyFilter {
    static func matches(_ j: Journey, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let stops = j.callingPoints[j.fromIndex...j.toIndex]
        let haystack = (stops.flatMap { [$0.crs, $0.name] } + [j.headcode, j.operatorName, j.operatorCode]).map { $0.lowercased() }
        return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
    }
}
