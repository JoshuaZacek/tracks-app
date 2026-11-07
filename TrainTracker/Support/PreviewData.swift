#if DEBUG
import Foundation

extension Journey {
    /// A two-stop journey for SwiftUI previews and tests. Times are "HH:MM" on
    /// `date` (UK time); an arrival earlier than the departure is the next day.
    static func preview(
        from: (crs: String, name: String),
        to: (crs: String, name: String),
        date: String = RailTime.ymd(.now),
        departs: String,
        arrives: String? = nil,
        platform: String? = nil,
        headcode: String = "1A23",
        operatorName: String = "LNER"
    ) -> Journey {
        let departure = RailTime.date(date, at: departs)!
        var arrival = arrives.flatMap { RailTime.date(date, at: $0) } ?? departure.addingTimeInterval(2 * 3600)
        if arrival <= departure { arrival = RailTime.calendar.date(byAdding: .day, value: 1, to: arrival)! }
        let train = TrainDetails(
            trainUid: "P\(abs(from.crs.hashValue % 10000))",
            runDate: date,
            headcode: headcode,
            operator: Operator(code: "GR", name: operatorName),
            callingPoints: [
                CallingPoint(crs: from.crs, name: from.name, scheduledDeparture: departure, bookedPlatform: platform),
                CallingPoint(crs: to.crs, name: to.name, scheduledArrival: arrival),
            ],
            route: []
        )
        return Journey(date: date, train: train, fromIndex: 0, toIndex: 1)
    }

    /// Southern's Victoria to Chichester, leaving in 25 minutes: the train
    /// divides at Horsham, it's moderately busy, and there's a station message.
    static func previewDividing(now: Date = .now) -> Journey {
        let journey = Journey.preview(
            from: ("VIC", "London Victoria"), to: ("CCH", "Chichester"),
            date: RailTime.ymd(now.addingTimeInterval(25 * 60)), departs: RailTime.hhmm(now.addingTimeInterval(25 * 60)),
            arrives: RailTime.hhmm(now.addingTimeInterval(25 * 60 + 104 * 60)),
            platform: "15", headcode: "1C46", operatorName: "Southern"
        )
        journey.live = LiveSummary(state: .live, expectedDeparture: journey.departsAt, delayMinutes: 0, isCancelled: false, stale: false, checkedAt: now, loading: .preview)
        return journey
    }
}

extension TrainDivision {
    /// 1C46 dividing at Horsham (from the Darwin capture, 7 Nov 2026).
    static func preview(at date: Date) -> TrainDivision {
        TrainDivision(
            atCrs: "HRH", atName: "Horsham", at: date,
            portions: [
                DivisionPortion(destCrs: "PMH", destName: "Portsmouth Harbour", yours: true, note: "Front 4 coaches"),
                DivisionPortion(destCrs: "BOG", destName: "Bognor Regis", yours: false, note: "Rear 4 coaches"),
            ],
            message: "This train divides at Horsham. Sit in the front 4 coaches for Chichester."
        )
    }
}

extension TrainLoading {
    static let preview = TrainLoading(
        percentage: 42, level: .moderate,
        coaches: [
            CoachLoad(number: "1", percentage: 64, coachClass: "Standard"),
            CoachLoad(number: "2", percentage: 51, coachClass: "Standard"),
            CoachLoad(number: "3", percentage: 47, coachClass: "First"),
            CoachLoad(number: "4", percentage: 58, coachClass: "Standard"),
            CoachLoad(number: "5", percentage: 40, coachClass: "Standard"),
            CoachLoad(number: "6", percentage: 33, coachClass: "Standard"),
            CoachLoad(number: "7", percentage: 18, coachClass: "Standard"),
            CoachLoad(number: "8", percentage: 22, coachClass: nil),
        ],
        quietestCoaches: ["7", "8"]
    )
}

extension StationMessage {
    /// One major and one minor message (text from the Darwin capture).
    static let previews: [StationMessage] = [
        StationMessage(
            id: "190200", stations: ["VIC"], category: "Train", severity: .major,
            text: "Disruption between Clapham Junction and Gatwick Airport: some lines are blocked. Trains may be cancelled or delayed by up to 20 minutes.",
            url: "https://www.nationalrail.co.uk/service-disruptions/", updatedAt: .now.addingTimeInterval(-15 * 60)
        ),
        StationMessage(
            id: "190196", stations: ["CCH"], category: "Station", severity: .minor,
            text: "The lift to platform 2 at Chichester is out of order.",
            url: nil, updatedAt: .now.addingTimeInterval(-90 * 60)
        ),
    ]
}

extension LiveStatus {
    /// Before departure, with a division at Horsham and loading at the boarding station.
    static func previewDividing(for journey: Journey) -> LiveStatus {
        LiveStatus(
            state: .live, checkedAt: .now, nextPollSeconds: 30, stale: false, message: nil,
            service: LiveService(scheduledDeparture: journey.departsAt, expectedDeparture: journey.departsAt, delayMinutes: 0, isCancelled: false),
            progress: nil, position: nil,
            divides: .preview(at: journey.departsAt.addingTimeInterval(57 * 60)),
            loading: .preview
        )
    }
}
#endif
