import AlarmKit
import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

/// "Wake me before my stop": an AlarmKit alarm a few minutes (the journey's
/// lead time, 5 by default) before the train is expected at my destination.
///
/// The server only knows the journey wants one (`JourneyPrefs.stopAlarm`), so
/// it can send a background push when the arrival moves; the alarm itself, the
/// lead time and which AlarmKit alarm belongs to which journey live here.
/// The alarm is moved whenever new live data arrives (a journey refresh, the
/// detail screen, or that push), and cancelled when it's turned off, or the
/// journey goes, arrives or is cancelled. Without new data it goes off at the
/// last known time.
///
/// Only the alert presentation is used (no countdown), which AlarmKit shows
/// itself, so the widget extension needs no Live Activity for it.
@Observable
final class StopAlarm {
    static let shared = StopAlarm()

    static let leadOptions = [2, 5, 10, 15]
    static let defaultLead = 5

    private(set) var authorization: AlarmManager.AuthorizationState

    private let manager: AlarmManager
    private let defaults: UserDefaults
    private static let recordsKey = "stopAlarms"
    /// Each journey's alarm, kept in user defaults (AlarmKit can't say which alarm is whose).
    private var records: [UUID: Record] {
        didSet { save() }
    }
    /// The last change in progress: changes run one at a time, so two refreshes
    /// landing together can't both set an alarm.
    private var queue: Task<Void, Never>?

    /// The alarm scheduled for a journey: its AlarmKit ID and when it goes off.
    nonisolated struct Record: Codable, Hashable, Sendable {
        var alarmID: UUID
        var fireDate: Date
    }

    init(manager: AlarmManager = .shared, defaults: UserDefaults = .standard) {
        self.manager = manager
        self.defaults = defaults
        authorization = manager.authorizationState
        records = Self.load(defaults)
    }

    // MARK: - Permission

    /// Asks the first time (the toggle being turned on); true if alarms are allowed.
    func requestAuthorization() async -> Bool {
        do {
            authorization = try await manager.requestAuthorization()
        } catch {
            Logger.tracks.error("Couldn't ask for alarms: \(error.localizedDescription)")
            authorization = manager.authorizationState
        }
        return authorization == .authorized
    }

    /// The user said no (or turned alarms off in Settings).
    var isDenied: Bool { authorization == .denied }

    func refreshAuthorization() {
        authorization = manager.authorizationState
    }

    // MARK: - Lead time (kept on the phone; the server doesn't need it)

    func leadMinutes(for journeyID: UUID) -> Int {
        let stored = defaults.integer(forKey: leadKey(journeyID))
        return stored > 0 ? stored : Self.defaultLead
    }

    func setLeadMinutes(_ minutes: Int, for journey: Journey) async {
        defaults.set(minutes, forKey: leadKey(journey.id))
        await update(journey: journey)
    }

    private func leadKey(_ id: UUID) -> String { "stopAlarmLead.\(id.uuidString)" }

    // MARK: - Keeping alarms in step

    /// From the journey's latest live summary (a refresh or the detail screen).
    func update(journey: Journey) async {
        await apply(StopAlarmPlan.Input(journey: journey), for: journey)
    }

    /// Every cached journey after a refresh; alarms for journeys no longer
    /// cached (deleted, here or elsewhere) are cancelled.
    func sync(_ journeys: [Journey]) async {
        for journey in journeys {
            await update(journey: journey)
        }
        let cached = Set(journeys.map(\.id))
        for id in records.keys where !cached.contains(id) {
            forget(journeyID: id)
        }
    }

    /// A `stop_alarm` background push: moves (or cancels) the alarm from the
    /// payload alone, with the journey's other details from the cache.
    func apply(_ push: StopAlarmPush, in context: ModelContext) async {
        let id = push.journeyID
        guard let journey = try? context.fetch(FetchDescriptor<Journey>(predicate: #Predicate { $0.id == id })).first else {
            // Not cached: nothing to say where or when, so just stop any alarm.
            if push.cancelled { cancel(journeyID: id) }
            return
        }
        await apply(StopAlarmPlan.Input(journey: journey).updated(by: push), for: journey)
    }

    /// Cancels the journey's alarm, if it has one.
    func cancel(journeyID: UUID) {
        guard let record = records[journeyID] else { return }
        do {
            try manager.cancel(id: record.alarmID)
        } catch {
            // Usually already gone (it went off and was stopped).
            Logger.tracks.info("Stop alarm for \(journeyID) not cancelled: \(error.localizedDescription)")
        }
        records[journeyID] = nil
        Logger.tracks.info("Stop alarm for \(journeyID) cancelled")
    }

    /// The journey is gone: its alarm and lead time too.
    func forget(journeyID: UUID) {
        cancel(journeyID: journeyID)
        defaults.removeObject(forKey: leadKey(journeyID))
    }

    /// Every alarm, e.g. when the user deletes their data.
    func cancelAll() {
        for id in records.keys { forget(journeyID: id) }
    }

    /// When the journey's alarm goes off, if one is set.
    func fireDate(for journeyID: UUID) -> Date? { records[journeyID]?.fireDate }

    // MARK: - Scheduling

    private func apply(_ input: StopAlarmPlan.Input, for journey: Journey) async {
        let previous = queue
        let task = Task {
            await previous?.value
            let id = journey.id
            let action = StopAlarmPlan.action(input, leadMinutes: leadMinutes(for: id), current: records[id]?.fireDate, now: .now)
            switch action {
            case .leave:
                break
            case .cancel:
                cancel(journeyID: id)
            case .schedule(let fireDate):
                await schedule(at: fireDate, for: journey)
            }
        }
        queue = task
        await task.value
    }

    private func schedule(at fireDate: Date, for journey: Journey) async {
        let id = journey.id
        guard manager.authorizationState == .authorized else {
            Logger.tracks.info("Stop alarm for \(id) not set: alarms aren't allowed")
            return
        }
        // A new alarm each time; the old one goes once the new one is set.
        let old = records[id]
        let alarmID = UUID()
        let attributes = AlarmAttributes<StopAlarmMetadata>(
            presentation: AlarmPresentation(alert: Self.alert(for: journey, lead: leadMinutes(for: id))),
            metadata: StopAlarmMetadata(journeyId: id),
            tintColor: .trainTeal
        )
        do {
            _ = try await manager.schedule(id: alarmID, configuration: .alarm(schedule: .fixed(fireDate), attributes: attributes))
            if let old { try? manager.cancel(id: old.alarmID) }
            records[id] = Record(alarmID: alarmID, fireDate: fireDate)
            Logger.tracks.info("Stop alarm for \(id) set for \(fireDate)")
        } catch {
            Logger.tracks.error("Couldn't set the stop alarm for \(id): \(error.localizedDescription)")
        }
    }

    /// "Peterborough in 5 min".
    private static func alert(for journey: Journey, lead: Int) -> AlarmPresentation.Alert {
        let title: LocalizedStringResource = "\(journey.to.name) in \(lead) min"
        if #available(iOS 26.1, *) {
            return AlarmPresentation.Alert(title: title)
        }
        return AlarmPresentation.Alert(title: title, stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"))
    }

    // MARK: - Storage

    private static func load(_ defaults: UserDefaults) -> [UUID: Record] {
        guard let data = defaults.data(forKey: recordsKey),
              let stored = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: records.map { ($0.key.uuidString, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.recordsKey)
    }
}

/// Carried with each alarm so it can be traced back to its journey.
nonisolated struct StopAlarmMetadata: AlarmMetadata {
    var journeyId: UUID
}

/// When a journey's stop alarm should go off. Pure, so it can be tested.
nonisolated enum StopAlarmPlan {
    enum Action: Equatable {
        /// Nothing to change.
        case leave
        /// Cancel any alarm (none is wanted, or it can't go off in time).
        case cancel
        /// Set (or move) the alarm to this time.
        case schedule(Date)
    }

    struct Input: Equatable {
        /// The journey has the alarm turned on (and isn't archived).
        var enabled: Bool
        var scheduledArrival: Date
        var expectedArrival: Date?
        /// The train has reached (or passed) my stop.
        var arrived: Bool
        var cancelled: Bool
    }

    /// Too close to set: the alarm would go off as it's set, or not at all.
    static let minimumNotice: TimeInterval = 60
    /// Smaller moves leave the alarm alone (Darwin times are to the minute anyway).
    static let tolerance: TimeInterval = 30

    /// - Parameter current: when the journey's alarm is set to go off, if it has one.
    static func action(_ input: Input, leadMinutes: Int, current: Date?, now: Date) -> Action {
        let arrival = input.expectedArrival ?? input.scheduledArrival
        guard input.enabled, !input.cancelled, !input.arrived, arrival > now else { return .cancel }
        // It's already gone off: don't wake anyone twice because the train slipped afterwards.
        if let current, current <= now { return .leave }
        let fire = arrival.addingTimeInterval(-TimeInterval(leadMinutes) * 60)
        if let current, abs(fire.timeIntervalSince(current)) < tolerance { return .leave }
        guard fire.timeIntervalSince(now) >= minimumNotice else { return .cancel }
        return .schedule(fire)
    }
}

extension StopAlarmPlan.Input {
    /// From a journey's cached state and live summary.
    init(journey: Journey) {
        let live = journey.live
        self.init(
            enabled: journey.prefs?.stopAlarm == true && journey.archivedAt == nil,
            scheduledArrival: journey.arrivesAt,
            expectedArrival: live?.expectedArrival,
            arrived: live?.state == .arrived || live?.actualArrival != nil,
            cancelled: live?.state == .cancelled || live?.isCancelled == true
        )
    }

    /// With the newer arrival time from a push. (The server only pushes while the alarm is on.)
    nonisolated func updated(by push: StopAlarmPush) -> Self {
        var input = self
        input.expectedArrival = push.expectedArrival
        input.cancelled = push.cancelled
        return input
    }
}

/// The server's `stop_alarm` background push:
/// `{"aps":{"content-available":1},"journeyId":…,"kind":"stop_alarm","expectedArrival":…|null,"cancelled":…}`.
nonisolated struct StopAlarmPush: Equatable, Sendable {
    static let kind = "stop_alarm"

    var journeyID: UUID
    /// At my destination; nil when the server has no live time (the timetable's applies).
    var expectedArrival: Date?
    var cancelled: Bool

    /// Nil for any other push.
    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["kind"] as? String == Self.kind,
              let id = (userInfo["journeyId"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        journeyID = id
        expectedArrival = (userInfo["expectedArrival"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        cancelled = userInfo["cancelled"] as? Bool ?? false
    }

    init(journeyID: UUID, expectedArrival: Date?, cancelled: Bool) {
        self.journeyID = journeyID
        self.expectedArrival = expectedArrival
        self.cancelled = cancelled
    }
}
