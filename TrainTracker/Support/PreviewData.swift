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
}
#endif
