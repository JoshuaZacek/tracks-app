import Foundation

// What the journey screens show from Darwin's extras (Sprint 3): where the
// train divides, how busy it is and station messages. Kept apart from the
// views so the rules can be tested.

extension LoadingLevel {
    /// "Quiet", "Some seats", "Busy", "Very busy"; nil for a level this app doesn't know.
    var text: String? {
        switch self {
        case .quiet: "Quiet"
        case .moderate: "Some seats"
        case .busy: "Busy"
        case .veryBusy: "Very busy"
        case .unknown: nil
        }
    }

    /// One, two or three people.
    var symbol: String {
        switch self {
        case .quiet, .unknown: "person.fill"
        case .moderate: "person.2.fill"
        case .busy, .veryBusy: "person.3.fill"
        }
    }

    /// Segments lit on the four-step gauge.
    var segments: Int {
        switch self {
        case .unknown: 0
        case .quiet: 1
        case .moderate: 2
        case .busy: 3
        case .veryBusy: 4
        }
    }

    /// Teal while there are seats, amber when busy.
    var tone: JourneyCardModel.Tone {
        switch self {
        case .busy, .veryBusy: .late
        default: .normal
        }
    }
}

extension TrainLoading {
    /// "Quietest: coaches 7 and 8", "Quietest: coach B1"; nil without coach data.
    var quietestText: String? {
        switch quietestCoaches.count {
        case 0: nil
        case 1: "Quietest: coach \(quietestCoaches[0])"
        default: "Quietest: coaches \(quietestCoaches.dropLast().joined(separator: ", ")) and \(quietestCoaches.last!)"
        }
    }

    /// The busy row's spoken summary: "Busy, 72% full. Quietest: coaches 7 and 8".
    var accessibilityText: String {
        var parts = ["\(level.text ?? "Loading"), \(percentage)% full"]
        if let quietest = quietestText { parts.append(quietest) }
        return parts.joined(separator: ". ")
    }
}

/// How busy the train is at my boarding station, until it leaves.
enum BusyDisplay {
    /// The loading to show: the full live status's if loaded, else the list's
    /// summary. Nil once the train has left my station (or is cancelled), and
    /// for a level this app doesn't know.
    static func loading(status: LiveStatus?, summary: LiveSummary?) -> TrainLoading? {
        let state = status?.state ?? summary?.state
        if let state, [.departed, .arrived, .cancelled].contains(state) { return nil }
        if status?.service?.actualDeparture != nil || summary?.actualDeparture != nil { return nil }
        if status?.service?.isCancelled == true || summary?.isCancelled == true { return nil }
        if status?.progress?.stops.first?.passed == true { return nil }
        guard let loading = status?.loading ?? summary?.loading, loading.level.text != nil else { return nil }
        return loading
    }
}

extension TrainDivision {
    /// "Divides at Horsham".
    var title: String { "Divides at \(atName)" }

    /// The part(s) that go to my destination.
    var mine: [DivisionPortion] { portions.filter(\.yours) }

    /// The banner read as one: title, message, then each part.
    var accessibilityText: String {
        let parts = portions.map { p in
            var text = "\(p.yours ? "Your part" : "Other part") to \(p.destName)"
            if let note = p.note { text += ", \(note.lowercased())" }
            return text + "."
        }
        return ([title + ".", message] + parts).joined(separator: " ")
    }
}

extension StationMessage {
    /// Major and severe messages stand out from the other notes.
    var isProminent: Bool { severity == .major || severity == .severe }

    var symbol: String {
        switch severity {
        case .severe: "exclamationmark.octagon.fill"
        case .major: "exclamationmark.triangle.fill"
        case .minor, .normal: "info.circle"
        }
    }

    var link: URL? {
        guard let url, let link = URL(string: url), link.scheme == "https" || link.scheme == "http" else { return nil }
        return link
    }

    /// "At Nottingham", "At London Victoria and Chichester": which of my stations it's for.
    func stationsText(from: (crs: String, name: String), to: (crs: String, name: String)) -> String? {
        let names = [from, to].filter { stations.contains($0.crs) }.map(\.name)
        guard !names.isEmpty else { return nil }
        return "At " + names.joined(separator: " and ")
    }
}
