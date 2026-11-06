import Observation
import OSLog
import SwiftUI
import UserNotifications

/// Alerts from the tracks server: asking permission, registering with APNs
/// and sending the token to the server (every launch, as the server clears
/// dead tokens), showing alerts while the app is open, and opening the
/// journey an alert is about when it's tapped.
@Observable
final class PushNotifications {
    static let shared = PushNotifications()

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Set when an alert is tapped; the Journeys screen opens it and clears it.
    var journeyToOpen: UUID?
    /// Set when a "couldn't find your train" alert is tapped: Settings opens
    /// Regular journeys and clears it.
    var regularJourneysToOpen = false

    private let client: TracksClient
    private var apnsToken: String?
    private var observingRegistration = false

    init(client: TracksClient = .shared) {
        self.client = client
    }

    /// UI tests run without the system permission prompt in the way.
    /// (`-allowNotificationPrompt` lets a test that's about notifications ask.)
    static var promptsAllowed: Bool {
        let args = ProcessInfo.processInfo.arguments
        return !args.contains("-uiTesting") || args.contains("-allowNotificationPrompt")
    }

    /// At launch: register with APNs if alerts are already allowed.
    func prepare() async {
        if !observingRegistration {
            observingRegistration = true
            NotificationCenter.default.addObserver(forName: TracksClient.didRegister, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let token = self.apnsToken else { return }
                    Task { await self.send(token: token) }
                }
            }
        }
        await refreshAuthorization()
        if authorization.allowsAlerts {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks once (after the first journey is saved, or from Settings); does nothing if already decided.
    func requestAuthorization() async {
        await refreshAuthorization()
        guard authorization == .notDetermined, Self.promptsAllowed else { return }
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            Logger.tracks.info("Notifications \(granted ? "allowed" : "declined")")
        } catch {
            Logger.tracks.error("Couldn't ask for notifications: \(error.localizedDescription)")
        }
        await prepare()
    }

    // MARK: - APNs callbacks (from the app delegate)

    func didRegister(deviceToken: Data) {
        let token = deviceToken.hexString
        apnsToken = token
        Task { await send(token: token) }
    }

    func didFailToRegister(_ error: any Error) {
        Logger.tracks.error("APNs registration failed: \(error.localizedDescription)")
    }

    private func send(token: String) async {
        do {
            _ = try await client.updateDevice(UpdateDeviceRequest(apnsEnvironment: DeviceSession.apnsEnvironment, apnsToken: .value(token)))
            Logger.tracks.info("APNs token sent (\(DeviceSession.apnsEnvironment.rawValue))")
        } catch {
            Logger.tracks.error("Couldn't send the APNs token: \(error.localizedDescription)")
        }
    }

    // MARK: - Alerts

    /// Where tapping an alert goes.
    nonisolated enum Destination: Equatable, Sendable {
        case journey(UUID)
        /// `template_unmatched`: no train matched a regular journey.
        case regularJourneys
    }

    /// `template_unmatched` alerts are about a regular journey (no journey yet);
    /// every other kind, `morning_summary`, `leave_now` and `connection` included,
    /// opens its journey. A `connection` alert names the leg arriving at the change,
    /// and a leg of a trip opens the whole trip.
    nonisolated static func destination(in userInfo: [AnyHashable: Any], threadIdentifier: String) -> Destination? {
        if userInfo["kind"] as? String == "template_unmatched" { return .regularJourneys }
        return journeyID(in: userInfo, threadIdentifier: threadIdentifier).map(Destination.journey)
    }

    /// The journey an alert is about: the server's "journeyId" key, else its thread.
    nonisolated static func journeyID(in userInfo: [AnyHashable: Any], threadIdentifier: String) -> UUID? {
        (userInfo["journeyId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: threadIdentifier)
    }

    func open(_ destination: Destination) {
        switch destination {
        case .journey(let id):
            Logger.tracks.info("Alert tapped for journey \(id)")
            journeyToOpen = id
        case .regularJourneys:
            Logger.tracks.info("Alert tapped for regular journeys")
            regularJourneysToOpen = true
        }
    }
}

extension UNAuthorizationStatus {
    var allowsAlerts: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}

/// Receives the APNs token and alert taps for `PushNotifications`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        PushNotifications.shared.didFailToRegister(error)
    }

    /// Background pushes (`content-available`). The server sends `stop_alarm`
    /// when the arrival moves for a journey with the stop alarm on: the alarm
    /// moves from the payload at once, then the journeys refresh if there's
    /// time. (Alerts and Live Activity updates don't come through here.)
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let push = StopAlarmPush(userInfo: userInfo) else {
            completionHandler(.noData)
            return
        }
        Logger.tracks.info("Stop alarm push for \(push.journeyID)")
        let finish = Once { completionHandler(.newData) }
        Task {
            await StopAlarm.shared.apply(push, in: JourneyStore.context)
            // iOS allows about 30 s in all; the alarm has already moved, so the refresh is a bonus.
            Task {
                try? await Task.sleep(for: .seconds(15))
                finish()
            }
            await JourneySync.shared.refresh(in: JourneyStore.context)
            finish()
        }
    }

    /// Runs its action the first time it's called.
    private final class Once {
        private var action: (() -> Void)?
        init(_ action: @escaping () -> Void) { self.action = action }
        func callAsFunction() {
            action?()
            action = nil
        }
    }

    // The completion-handler forms: the async ones finish off the main
    // thread, which UIKit asserts against when opening the app from an alert.

    /// Alerts still show while the app is open; the list refreshes to match.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            JourneySync.shared.requestRefresh()
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Tapping an alert opens its journey (or, for a regular journey, the list of them).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let destination = PushNotifications.destination(in: content.userInfo, threadIdentifier: content.threadIdentifier)
        DispatchQueue.main.async {
            if let destination { PushNotifications.shared.open(destination) }
            completionHandler()
        }
    }
}
