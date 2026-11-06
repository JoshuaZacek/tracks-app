import Foundation

/// How a change between two trains of a trip is shown: the colour, symbol and
/// words. Kept apart from the views so the rules can be tested.
struct ConnectionDisplay: Equatable {
    enum Tone: Equatable {
        /// Teal: plenty of time.
        case ok
        /// Amber: tight, or at risk.
        case warning
        /// Red: missed, or a train cancelled.
        case bad
    }

    var tone: Tone
    var symbol: String
    /// "Change at Peterborough".
    var title: String
    /// The server's summary: "8 min to change", "The 17:55 is cancelled".
    var detail: String
    /// Whether to offer later trains (the server sends them only then).
    var offersAlternatives: Bool

    init(_ c: Connection) {
        switch c.status {
        case .ok:
            tone = .ok
            symbol = "arrow.triangle.swap"
        case .tight:
            tone = .warning
            symbol = "timer"
        case .atRisk:
            tone = .warning
            symbol = "exclamationmark.triangle.fill"
        case .missed:
            tone = .bad
            symbol = "xmark.octagon.fill"
        }
        title = "Change at \(c.station.name)"
        detail = c.message
        offersAlternatives = c.status == .atRisk || c.status == .missed
    }

    /// "Arrive 17:52 · platform 3 → leave 17:58 · platform 1".
    static func times(_ c: Connection) -> String {
        func platform(_ p: Platform?) -> String { p.map { " · platform \($0.number)" } ?? "" }
        return "Arrive \(RailTime.hhmm(c.arrival))\(platform(c.arrivalPlatform)) → leave \(RailTime.hhmm(c.departure))\(platform(c.departurePlatform))"
    }

    /// For VoiceOver: "Change at Peterborough, 8 min to change".
    var accessibilityLabel: String { "\(title), \(detail)" }
}
