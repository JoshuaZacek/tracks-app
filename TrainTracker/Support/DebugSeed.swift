#if DEBUG
import Foundation
import SwiftData

/// Launch with `-seedJourneys` to replace this install's journeys (on the server
/// too) with real trains, laid out like the Journeys mockup: one under way, one leaving
/// soon, more later today and over the coming week, and one already finished.
enum DebugSeed {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-seedJourneys") }

    private struct Spec {
        var daysAhead: Int
        var from: String
        var to: String
        /// Minutes from now (same day) or a fixed "HH:MM".
        var after: Either
        enum Either { case minutesFromNow(Int), at(String) }
    }

    private static let specs: [Spec] = [
        Spec(daysAhead: 0, from: "LDS", to: "YRK", after: .minutesFromNow(-180)), // finished: Past
        Spec(daysAhead: 0, from: "KGX", to: "YRK", after: .minutesFromNow(-40)), // under way: Live
        Spec(daysAhead: 0, from: "YRK", to: "KGX", after: .minutesFromNow(25)), // leaving soon: Live
        Spec(daysAhead: 0, from: "KGX", to: "YRK", after: .minutesFromNow(180)),
        Spec(daysAhead: 1, from: "MAN", to: "LDS", after: .at("07:15")),
        Spec(daysAhead: 4, from: "LDS", to: "NCL", after: .at("13:30")),
        Spec(daysAhead: 4, from: "NCL", to: "EDB", after: .at("19:00")),
        Spec(daysAhead: 5, from: "EUS", to: "GLC", after: .at("09:30")),
    ]

    static func run(into context: ModelContext) async {
        let sync = JourneySync.shared
        for journey in (try? context.fetch(FetchDescriptor<Journey>())) ?? [] {
            await sync.delete(journey, in: context)
        }
        let api = TracksClient.shared
        let now = Date.now
        for spec in specs {
            let day = RailTime.calendar.date(byAdding: .day, value: spec.daysAhead, to: now)!
            var date = RailTime.ymd(day)
            let after: String
            switch spec.after {
            case .at(let hhmm): after = hhmm
            case .minutesFromNow(let m):
                let t = now.addingTimeInterval(TimeInterval(m * 60))
                date = RailTime.ymd(t)
                after = RailTime.hhmm(t)
            }
            do {
                let r = try await api.departures(from: spec.from, date: date, to: spec.to, after: after, limit: 1)
                guard let d = r.departures.first else { continue }
                try await sync.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: spec.from, toCrs: spec.to, in: context)
            } catch {
                print("Seed \(spec.from)-\(spec.to) failed: \(error.localizedDescription)")
            }
        }
        try? context.save()
    }
}
#endif
