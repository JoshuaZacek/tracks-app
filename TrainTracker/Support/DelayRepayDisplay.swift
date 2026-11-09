import Foundation

/// What the claim card says, worked out apart from the view so it's tested.
extension DelayRepayClaim {
    /// "34 min late · LNER pays 50% of a single fare".
    var summary: String {
        guard !cancelled, let band, let delayMinutes else {
            return "Cancelled · claim from \(`operator`.name) for how late you got there, or a refund if you didn't travel"
        }
        let share = band.maxMinutes == nil ? "\(Self.percent(band.returnPercent)) of a return fare" : "\(Self.percent(band.singlePercent)) of a single fare"
        return "\(delayMinutes) min late · \(`operator`.name) pays \(share)"
    }

    /// What the claim may pay for this ticket, in pence, as the server works it out (rounded down).
    func estimatePence(price: Int?, type: TicketType?) -> Int? {
        guard let band, let price, let type else { return nil }
        let percent: Double
        switch type {
        case .single: percent = band.singlePercent
        case .return: percent = band.returnPercent
        case .unknown: return nil
        }
        return Int((Double(price) * percent / 100).rounded(.down))
    }

    /// The journey as claim forms ask for it, to paste in.
    func details(for journey: Journey) -> String {
        let arrival: String
        if cancelled {
            arrival = "cancelled"
        } else if let actualArrival {
            arrival = RailTime.hhmm(actualArrival) + (delayMinutes.map { " (\($0) min late)" } ?? "")
        } else {
            arrival = delayMinutes.map { "\($0) min late" } ?? "unknown"
        }
        return [
            "Date: \(Self.longDate.string(from: journey.departsAt))",
            "From: \(journey.from.name) (\(journey.from.crs))",
            "To: \(journey.to.name) (\(journey.to.crs))",
            "Booked departure: \(RailTime.hhmm(journey.departsAt))",
            "Booked arrival: \(RailTime.hhmm(journey.arrivesAt))",
            "Actual arrival: \(arrival)",
            "Train: \(journey.headcode), \(`operator`.name)",
        ].joined(separator: "\n")
    }

    private static func percent(_ p: Double) -> String {
        p.rounded() == p ? "\(Int(p))%" : "\(p.formatted(.number.precision(.fractionLength(0...1))))%"
    }

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.calendar = RailTime.calendar
        f.timeZone = RailTime.zone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEEE d MMMM yyyy"
        return f
    }()
}

/// Money typed and shown in pounds, kept in pence.
nonisolated enum Pence {
    /// "45.20", "£45.2", "45", "45,20" → pence; nil for anything else (negative, more than 2 decimals).
    static func parse(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "£", with: "")
        t = t.replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let pounds = Int(parts[0].isEmpty ? "0" : parts[0]) else { return nil }
        var pence = 0
        if parts.count == 2 {
            let fraction = parts[1]
            guard fraction.count <= 2, fraction.isEmpty || Int(fraction) != nil else { return nil }
            pence = Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        return pounds * 100 + pence
    }

    /// "45.20", for the text field.
    static func text(_ pence: Int) -> String { String(format: "%d.%02d", pence / 100, pence % 100) }

    /// "£45.20".
    static func format(_ pence: Int) -> String { "£" + text(pence) }
}
