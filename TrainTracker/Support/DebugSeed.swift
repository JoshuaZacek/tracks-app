#if DEBUG
import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Launch with `-seedJourneys` to replace this install's journeys (on the server
/// too) with real trains, laid out like the Journeys mockup: one under way, one leaving
/// soon, more later today and over the coming week, and one already finished.
/// One is a Southern train from Victoria to Chichester, which usually divides at Horsham.
///
/// `-sampleExtras` adds a division, loading and a station message to every
/// journey screen (and so its card), for when no real dividing train is running.
enum DebugSeed {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-seedJourneys") }
    static var sampleExtras: Bool { ProcessInfo.processInfo.arguments.contains("-sampleExtras") }

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
        Spec(daysAhead: 0, from: "VIC", to: "CCH", after: .minutesFromNow(50)), // divides at Horsham (Arun Valley trains)
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
        if ProcessInfo.processInfo.arguments.contains("-debugAlert") { await scheduleAlert(in: context) }
    }

    /// The live status with the sample division (two thirds of the way along)
    /// and loading, where the server has none, until the train leaves.
    static func withSampleExtras(_ status: LiveStatus, for journey: Journey) -> LiveStatus {
        var status = status
        let departed = status.service?.actualDeparture != nil || [.departed, .arrived, .cancelled].contains(status.state)
        if status.divides == nil, !departed {
            var division = TrainDivision.preview(at: journey.departsAt.addingTimeInterval(journey.arrivesAt.timeIntervalSince(journey.departsAt) * 2 / 3))
            division.atName = "Horsham"
            division.message = "This train divides at Horsham. Sit in the front 4 coaches for \(journey.to.name)."
            status.divides = division
        }
        if status.loading == nil { status.loading = .preview }
        return status
    }

    static func sampleMessages(for journey: Journey) -> [StationMessage] {
        StationMessage.previews.enumerated().map { index, message in
            var message = message
            message.stations = [index == 0 ? journey.from.crs : journey.to.crs]
            message.text = message.text.replacingOccurrences(of: "Chichester", with: journey.to.name)
            return message
        }
    }

    /// `-debugAlert`: an alert shaped like the server's (journeyId key, thread
    /// per journey) about the first live journey, once the app is in the background, so UI tests
    /// can tap it and check it opens the journey.
    private static func scheduleAlert(in context: ModelContext) async {
        let journeys = (try? context.fetch(FetchDescriptor<Journey>(sortBy: [SortDescriptor(\.departsAt)]))) ?? []
        guard let journey = journeys.first(where: { $0.live?.state == .departed }) ?? journeys.first else { return }
        // Wait for the test to allow notifications; anything added before then is dropped.
        for _ in 0..<90 {
            if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .authorized { break }
            try? await Task.sleep(for: .seconds(1))
        }
        // Then for the app to be in the background, as when a real alert arrives.
        for _ in 0..<90 where UIApplication.shared.applicationState != .background {
            try? await Task.sleep(for: .seconds(1))
        }
        let content = UNMutableNotificationContent()
        content.title = "\(RailTime.hhmm(journey.departsAt)) \(journey.from.name) to \(journey.to.name)"
        content.body = "Test alert: platform change."
        content.threadIdentifier = journey.id.uuidString.lowercased()
        content.userInfo = ["journeyId": journey.id.uuidString.lowercased(), "kind": "platform"]
        let request = UNNotificationRequest(identifier: "debugAlert", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
