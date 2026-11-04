import Foundation

enum JourneySection: Equatable {
    case live, upcoming, past
}

/// Journeys under one day heading ("Today", "Fri Nov 6", ...).
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
    /// Live's day headings ("Today", "Yesterday") only show when a live trip
    /// touches another day: overnight, departed yesterday, or leaving after midnight.
    var liveShowsDays = false

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
        let liveJourneys = buckets[.live, default: []].sorted { $0.departsAt < $1.departsAt }
        live = Self.group(liveJourneys, now: now)
        liveShowsDays = liveJourneys.contains { j in
            !RailTime.calendar.isDate(j.departsAt, inSameDayAs: now) || !RailTime.calendar.isDate(j.arrivesAt, inSameDayAs: now)
        }
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
/// boarding and alighting, the operator (full name, code or the short name
/// passengers use, like "gwr"), or the departure date or time (see `matchesWhen`).
enum JourneyFilter {
    static func matches(_ j: Journey, query: String, now: Date = .now) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let stops = j.callingPoints[j.fromIndex...j.toIndex]
        let operatorNames = [j.operatorName, j.operatorCode, shortOperatorNames[j.operatorCode, default: j.operatorName]]
        let haystack = (stops.flatMap { [$0.crs, $0.name] } + operatorNames).map { $0.lowercased() }
        return words.allSatisfy { word in
            switch matchesWhen(j.departsAt, word: word, now: now) {
            case .match: true
            case .noMatch: false
            // Weekday and month names can also be stations ("mar" for Marylebone).
            case .name(let matched): matched || haystack.contains { $0.contains(word) }
            case nil: haystack.contains { $0.contains(word) }
            }
        }
    }

    enum When: Equatable { case match, noMatch, name(Bool) }

    /// Date and time words, matched against the departure in UK time, or nil
    /// for any other word:
    /// - "today", "tomorrow", "yesterday", "tonight" (today from 17:00)
    /// - a weekday ("fri", "friday") or a month ("nov", "november")
    /// - a day of the month ("6"), so "6 nov" finds 6 November
    /// - "morning" (before 12:00), "afternoon" (12:00–17:00), "evening" (from 17:00)
    /// - a time ("18:00", "9:30") or the start of one ("18:")
    static func matchesWhen(_ departs: Date, word: String, now: Date) -> When? {
        let cal = RailTime.calendar
        let c = cal.dateComponents([.month, .day, .weekday, .hour], from: departs)
        let hour = c.hour ?? 0
        let dayOffset = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: departs)).day ?? 0

        func when(_ b: Bool) -> When { b ? .match : .noMatch }
        switch word {
        case "today": return when(dayOffset == 0)
        case "tomorrow": return when(dayOffset == 1)
        case "yesterday": return when(dayOffset == -1)
        case "tonight": return when(dayOffset == 0 && hour >= 17)
        case "morning": return when(hour < 12)
        case "afternoon": return when((12..<17).contains(hour))
        case "evening": return when(hour >= 17)
        default: break
        }
        if let weekday = symbolIndex(of: word, in: cal.weekdaySymbols) {
            return .name(c.weekday == weekday + 1)
        }
        if let month = symbolIndex(of: word, in: cal.monthSymbols) {
            return .name(c.month == month + 1)
        }
        if word.allSatisfy(\.isNumber), let day = Int(word), (1...31).contains(day) {
            return when(c.day == day)
        }
        // "9:30" → "09:30", then a prefix match on "HH:MM".
        if let colon = word.firstIndex(of: ":"), word[..<colon].allSatisfy(\.isNumber), (1...2).contains(word.distance(from: word.startIndex, to: colon)) {
            let time = colon == word.index(after: word.startIndex) ? "0" + word : word
            return when(RailTime.hhmm(departs).hasPrefix(time))
        }
        return nil
    }

    /// A full English name ("friday") or its first three letters ("fri").
    private static func symbolIndex(of word: String, in symbols: [String]) -> Int? {
        guard word.count >= 3 else { return nil }
        return symbols.firstIndex { name in
            let name = name.lowercased()
            return name == word || (word.count == 3 && name.hasPrefix(word))
        }
    }

    /// What passengers call each operator, by code, so "gwr" or "tpe" finds
    /// journeys whose full name doesn't contain it.
    private static let shortOperatorNames: [String: String] = [
        "AW": "TfW", "CC": "c2c", "CH": "Chiltern", "CS": "Sleeper", "EM": "EMR",
        "ES": "Eurostar", "GC": "Grand Central", "GN": "Great Northern", "GR": "LNER",
        "GW": "GWR", "GX": "Gatwick Exp", "HT": "Hull Trains", "HX": "Heathrow Exp",
        "IL": "Island Line", "LD": "Lumo", "LE": "Greater Anglia", "LM": "WMR",
        "LO": "Overground", "ME": "Merseyrail", "NT": "Northern", "NY": "NYMR",
        "SE": "Southeastern", "SN": "Southern", "SR": "ScotRail", "SW": "SWR",
        "SX": "Stansted Exp", "TL": "Thameslink", "TP": "TPE", "TW": "Metro",
        "VT": "Avanti", "WR": "West Coast", "XC": "CrossCountry", "XR": "Elizabeth line",
    ]
}
