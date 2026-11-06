import Foundation

/// The days a regular journey runs: ISO weekdays, 1 = Monday ... 7 = Sunday,
/// as the server sends them.
nonisolated enum Weekdays {
    static let all = Array(1...7)
    /// Monday to Friday: the default for "Repeat on weekdays…".
    static let workdays = Array(1...5)

    /// "Mon" ... "Sun".
    static func shortName(_ day: Int) -> String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][(day - 1) % 7]
    }

    /// "Mondays" ... "Sundays".
    static func plural(_ day: Int) -> String {
        ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"][(day - 1) % 7]
    }

    /// One letter, for the day buttons.
    static func initial(_ day: Int) -> String {
        String(shortName(day).prefix(1))
    }

    /// Sorted, without repeats or anything outside 1...7.
    static func normalized(_ days: some Sequence<Int>) -> [Int] {
        Array(Set(days).filter { (1...7).contains($0) }).sorted()
    }

    /// The UK weekday of a moment.
    static func isoWeekday(of date: Date) -> Int {
        // Calendar weekdays start on Sunday (1).
        let weekday = RailTime.calendar.component(.weekday, from: date)
        return weekday == 1 ? 7 : weekday - 1
    }

    /// "Weekdays", "Every day", "Weekends", "Tuesdays", "Mon–Thu", "Mon, Wed, Fri".
    static func label(_ days: [Int]) -> String {
        let days = normalized(days)
        switch days {
        case []: return "Never"
        case all: return "Every day"
        case workdays: return "Weekdays"
        case [6, 7]: return "Weekends"
        case let one where one.count == 1: return plural(one[0])
        default: break
        }
        // Runs of three or more days read as a range.
        var parts: [String] = []
        var start = 0
        while start < days.count {
            var end = start
            while end + 1 < days.count, days[end + 1] == days[end] + 1 { end += 1 }
            if end - start >= 2 {
                parts.append("\(shortName(days[start]))–\(shortName(days[end]))")
            } else {
                parts += days[start...end].map(shortName)
            }
            start = end + 1
        }
        return parts.joined(separator: ", ")
    }
}

/// "HH:MM" times of day (UK), as minutes past midnight.
nonisolated enum ClockTime {
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Wraps round midnight.
    static func hhmm(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// The morning summary's starting time: an hour before the train, on the
    /// five minutes, and no earlier than midnight (it's sent on the day).
    static func defaultSummaryTime(departTime: String) -> String {
        guard let depart = minutes(departTime) else { return "07:00" }
        let earlier = depart - 60
        return hhmm(max(0, earlier - earlier % 5))
    }

    /// A moment at `hhmm` (UK time) on a fixed day, for time pickers; and back.
    static func pickerDate(_ hhmm: String) -> Date {
        RailTime.date("2026-01-05", at: hhmm) ?? .now
    }

    static func fromPicker(_ date: Date) -> String {
        RailTime.hhmm(date)
    }
}

/// How long it takes to get to the station, for the leave-now alert.
nonisolated enum TravelTime {
    /// The server takes 0...240.
    static let range = 0...240
    static let options = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 75, 90, 105, 120, 150, 180, 240]

    /// The picker's choices, with `current` added if it's not one of them.
    static func options(including current: Int?) -> [Int] {
        guard let current, !options.contains(current) else { return options }
        return (options + [current]).sorted()
    }

    /// A directions ETA as a suggestion: whole minutes rounded up to the next
    /// five (getting there early beats missing the train), within the server's range.
    static func suggestedMinutes(eta: TimeInterval) -> Int {
        let minutes = Int((max(0, eta) / 60).rounded(.up))
        let rounded = (minutes + 4) / 5 * 5
        return min(range.upperBound, max(5, rounded))
    }

    /// Walking if the station's close, else driving (directions ETAs don't do buses).
    static func walks(distanceMeters: Double) -> Bool {
        distanceMeters <= 2500
    }

    static func label(_ minutes: Int) -> String {
        "\(minutes) min"
    }
}

/// A regular journey's editable settings, as changed on screen.
nonisolated struct RegularJourneyDraft: Equatable, Sendable {
    var departTime: String
    var days: [Int]
    var travelMinutes: Int?
    /// Nil: no morning summary.
    var summaryTime: String?

    init(departTime: String, days: [Int], travelMinutes: Int?, summaryTime: String?) {
        self.departTime = departTime
        self.days = days
        self.travelMinutes = travelMinutes
        self.summaryTime = summaryTime
    }

    init(_ template: JourneyTemplate) {
        self.init(departTime: template.departTime, days: template.days, travelMinutes: template.travelMinutes, summaryTime: template.summaryTime)
    }

    /// The PATCH that turns `old` into this: only what changed, with JSON null
    /// for what was cleared. Nil when nothing changed.
    func changes(from old: RegularJourneyDraft) -> UpdateJourneyTemplateRequest? {
        var body = UpdateJourneyTemplateRequest()
        var changed = false
        if departTime != old.departTime {
            body.departTime = departTime
            changed = true
        }
        if Weekdays.normalized(days) != Weekdays.normalized(old.days) {
            body.days = Weekdays.normalized(days)
            changed = true
        }
        if travelMinutes != old.travelMinutes {
            body.travelMinutes = travelMinutes.map { .value($0) } ?? .null
            changed = true
        }
        if summaryTime != old.summaryTime {
            body.summaryTime = summaryTime.map { .value($0) } ?? .null
            changed = true
        }
        return changed ? body : nil
    }
}

extension JourneyTemplate {
    /// "07:42 London Bridge → Brighton".
    var title: String { "\(departTime) \(from.name) → \(to.name)" }

    /// "Weekdays · 15 min to the station · Summary at 06:40".
    var summaryLine: String {
        var parts = [Weekdays.label(days)]
        if let travelMinutes { parts.append("\(travelMinutes) min to the station") }
        if let summaryTime { parts.append("Summary at \(summaryTime)") }
        return parts.joined(separator: " · ")
    }
}
