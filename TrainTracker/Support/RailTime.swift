import Foundation

/// Timetable and Darwin times are UK local wall-clock times ("HH:MM", dates as
/// "YYYY-MM-DD"). Everything here works in Europe/London whatever time zone
/// the phone is in, so a journey's times stay right when travelling abroad.
nonisolated enum RailTime {
    static let zone = TimeZone(identifier: "Europe/London")!

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    /// The moment "HH:MM" on `ymd` plus `days`, in UK time.
    static func date(_ ymd: String, plusDays days: Int = 0, at hhmm: String) -> Date? {
        let d = ymd.split(separator: "-").compactMap { Int($0) }
        let t = hhmm.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 2 else { return nil }
        guard let base = calendar.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1])) else { return nil }
        return calendar.date(byAdding: .day, value: days, to: base)
    }

    /// "YYYY-MM-DD" of a moment, in UK time.
    static func ymd(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// "HH:MM" of a moment, in UK time.
    static func hhmm(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour!, c.minute!)
    }

    /// Backend ISO timestamps ("2026-10-05T19:03:00.000Z").
    static func parseISO(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Day headings: "Yesterday", "Today", "Tomorrow", otherwise the short
    /// date ("Thu Nov 5").
    static func dayLabel(for date: Date, now: Date = .now) -> String {
        let start = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let diff = calendar.dateComponents([.day], from: start, to: day).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return shortDateFormatter.string(from: date)
        }
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = zone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE MMM d"
        return f
    }()
}
