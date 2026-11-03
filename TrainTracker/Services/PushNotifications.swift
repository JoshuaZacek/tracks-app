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

    /// The journey an alert is about: the server's "journeyId" key, else its thread.
    nonisolated static func journeyID(in userInfo: [AnyHashable: Any], threadIdentifier: String) -> UUID? {
        (userInfo["journeyId"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(uuidString: threadIdentifier)
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

    // The completion-handler forms: the async ones finish off the main
    // thread, which UIKit asserts against when opening the app from an alert.

    /// Alerts still show while the app is open; the list refreshes to match.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            JourneySync.shared.requestRefresh()
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Tapping an alert opens its journey.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        let id = PushNotifications.journeyID(in: content.userInfo, threadIdentifier: content.threadIdentifier)
        DispatchQueue.main.async {
            if let id {
                Logger.tracks.info("Alert tapped for journey \(id)")
                PushNotifications.shared.journeyToOpen = id
            }
            completionHandler()
        }
    }
}
