import ActivityKit
import Foundation
import Observation
import OSLog

/// Live Activities for journeys. The server drives them by push: it can start
/// one itself (push-to-start, 30 min before departure) and sends every
/// update and the end. The app's part:
/// - send the device's push-to-start token, and each activity's push token
///   (on start and on every rotation), whoever started the activity;
/// - start one by hand from a journey;
/// - tell the server when the user dismisses one, so it stops pushing and
///   doesn't start that journey again;
/// - end the activity itself when its journey is deleted or archived.
@Observable
final class LiveActivities {
    static let shared = LiveActivities()

    /// Journeys with an activity on screen (active or ended but still showing).
    private(set) var journeyIDs: Set<UUID> = []
    private(set) var lastError: String?

    private let client: TracksClient
    private var observing = false
    /// Per activity: the tasks watching its token and state.
    private var watchers: [String: [Task<Void, Never>]] = [:]
    /// Activities that ended (by the server or the app) before being dismissed:
    /// dismissing those isn't the user turning the journey's activity off.
    private var ended: Set<String> = []
    /// The latest push-to-start token, re-sent when the device registers again.
    private var pushToStartToken: String?

    init(client: TracksClient = .shared) {
        self.client = client
    }

    var areEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isRunning(for journeyID: UUID) -> Bool { journeyIDs.contains(journeyID) }

    /// At launch: watch for push-to-start tokens and for activities started by
    /// push, and pick up the ones already running.
    func start() {
        guard !observing else { return }
        observing = true
        for activity in Activity<TrainActivityAttributes>.activities {
            watch(activity)
        }
        Task {
            for await activity in Activity<TrainActivityAttributes>.activityUpdates {
                watch(activity)
            }
        }
        Task {
            for await data in Activity<TrainActivityAttributes>.pushToStartTokenUpdates {
                // The stream can repeat the same token; send only new ones.
                let token = data.hexString
                guard token != pushToStartToken else { continue }
                pushToStartToken = token
                await sendPushToStartToken(token)
            }
        }
        NotificationCenter.default.addObserver(forName: TracksClient.didRegister, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resendTokens() }
        }
    }

    /// Starts an activity for the journey now (the server takes over updates once it has the token).
    func start(for journey: Journey) throws {
        if let existing = activity(for: journey.id), existing.activityState == .active { return }
        let content = ActivityContent(state: Self.initialState(for: journey), staleDate: nil, relevanceScore: 50)
        let activity: Activity<TrainActivityAttributes>
        do {
            activity = try Activity.request(attributes: Self.attributes(for: journey), content: content, pushType: .token)
        } catch {
            // No push entitlement (e.g. a build signed by a free Personal Team): show it anyway, without server updates.
            Logger.tracks.error("Live Activity with push failed (\(error.localizedDescription)); starting it without")
            activity = try Activity.request(attributes: Self.attributes(for: journey), content: content, pushType: nil)
        }
        Logger.tracks.info("Started Live Activity \(activity.id) for \(journey.id)")
        watch(activity)
    }

    /// Ends the journey's activity, e.g. it was deleted or archived. The server
    /// forgets the token with the journey, so nothing is sent.
    func end(journeyID: UUID) async {
        for activity in Activity<TrainActivityAttributes>.activities where activity.attributes.journeyId == journeyID {
            ended.insert(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        journeyIDs.remove(journeyID)
    }

    /// The user turned it off from the journey: end it and stop the server pushing.
    func stop(journeyID: UUID) async {
        await end(journeyID: journeyID)
        do {
            try await client.endLiveActivity(journeyID: journeyID)
        } catch {
            Logger.tracks.error("Couldn't stop Live Activity pushes for \(journeyID): \(error.localizedDescription)")
        }
    }

    /// Everything, e.g. when the user deletes their data.
    func endAll() async {
        for activity in Activity<TrainActivityAttributes>.activities {
            ended.insert(activity.id)
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        journeyIDs.removeAll()
    }

    // MARK: - Watching activities

    private func activity(for journeyID: UUID) -> Activity<TrainActivityAttributes>? {
        Activity<TrainActivityAttributes>.activities.first { $0.attributes.journeyId == journeyID }
    }

    private func watch(_ activity: Activity<TrainActivityAttributes>) {
        let id = activity.id
        guard watchers[id] == nil else { return }
        let journeyID = activity.attributes.journeyId
        if activity.activityState == .ended { ended.insert(id) }
        if activity.activityState == .active || activity.activityState == .stale || activity.activityState == .ended {
            journeyIDs.insert(journeyID)
        }
        let tokens = Task {
            var last: String?
            for await data in activity.pushTokenUpdates {
                let token = data.hexString
                guard token != last else { continue }
                last = token
                await register(token: token, journeyID: journeyID)
            }
        }
        let states = Task {
            for await state in activity.activityStateUpdates {
                handle(state, of: id, journeyID: journeyID)
            }
        }
        watchers[id] = [tokens, states]
    }

    private func handle(_ state: ActivityState, of id: String, journeyID: UUID) {
        switch state {
        case .active, .stale:
            journeyIDs.insert(journeyID)
        case .ended:
            ended.insert(id)
        case .dismissed:
            journeyIDs.remove(journeyID)
            watchers.removeValue(forKey: id)?.forEach { $0.cancel() }
            // Swiped away while still running: the user doesn't want it for this journey.
            if !ended.contains(id) {
                Task {
                    do {
                        try await client.endLiveActivity(journeyID: journeyID)
                    } catch {
                        Logger.tracks.error("Couldn't report dismissed Live Activity for \(journeyID): \(error.localizedDescription)")
                    }
                }
            }
            ended.remove(id)
        default:
            break // e.g. pending: nothing to do until it's shown
        }
    }

    private func register(token: String, journeyID: UUID) async {
        do {
            try await client.registerLiveActivity(journeyID: journeyID, pushToken: token)
            lastError = nil
            Logger.tracks.info("Live Activity token sent for \(journeyID)")
        } catch let error as TracksError where error.code == .journeyNotFound {
            // The journey went (deleted elsewhere): nothing will update it.
            await end(journeyID: journeyID)
        } catch {
            lastError = error.localizedDescription
            Logger.tracks.error("Couldn't send Live Activity token (\(token.count) hex chars) for \(journeyID): \(error.localizedDescription)")
        }
    }

    private func sendPushToStartToken(_ token: String) async {
        do {
            _ = try await client.updateDevice(UpdateDeviceRequest(apnsEnvironment: DeviceSession.apnsEnvironment, pushToStartToken: .value(token)))
            Logger.tracks.info("Push-to-start token sent")
        } catch {
            Logger.tracks.error("Couldn't send the push-to-start token (\(token.count) hex chars): \(error.localizedDescription)")
        }
    }

    /// After the device registers again (new ID), its tokens are unknown to the server.
    private func resendTokens() {
        Task {
            if let pushToStartToken { await sendPushToStartToken(pushToStartToken) }
            for activity in Activity<TrainActivityAttributes>.activities where activity.activityState == .active {
                if let token = activity.pushToken?.hexString {
                    await register(token: token, journeyID: activity.attributes.journeyId)
                }
            }
        }
    }

    // MARK: - Content from a saved journey

    static func attributes(for journey: Journey) -> TrainActivityAttributes {
        TrainActivityAttributes(
            journeyId: journey.id,
            headcode: journey.headcode,
            operatorName: journey.operatorName,
            fromCrs: journey.from.crs,
            fromName: journey.from.name,
            toCrs: journey.to.crs,
            toName: journey.to.name
        )
    }

    /// A first state from what the app knows; the server sends the full one
    /// within a tick of getting the token.
    static func initialState(for journey: Journey) -> TrainActivityAttributes.ContentState {
        let live = journey.live
        let phase = live.map { TrainActivityAttributes.ContentState.Phase(rawValue: $0.state.rawValue) ?? .unknown } ?? .scheduled
        let departed = live?.actualDeparture != nil
        let platform: TrainActivityAttributes.ContentState.Platform?
        if departed {
            platform = journey.to.bookedPlatform.map { .init(number: $0, confirmed: false) }
        } else if let p = live?.platform {
            platform = .init(number: p.number, confirmed: p.confirmed, hidden: p.hidden)
        } else {
            platform = journey.from.bookedPlatform.map { .init(number: $0, confirmed: false) }
        }
        return .init(
            state: phase,
            scheduledDeparture: journey.departsAt,
            expectedDeparture: live?.expectedDeparture,
            actualDeparture: live?.actualDeparture,
            scheduledArrival: journey.arrivesAt,
            expectedArrival: live?.expectedArrival,
            actualArrival: live?.actualArrival,
            delayMinutes: live?.delayMinutes,
            platform: platform,
            isCancelled: live?.isCancelled ?? false
        )
    }
}

extension Data {
    /// APNs tokens as the server wants them.
    nonisolated var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
