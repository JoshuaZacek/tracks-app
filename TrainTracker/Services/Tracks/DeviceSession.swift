import Foundation

/// This install's identity on the tracks server: the device ID and bearer
/// token from registering anonymously, kept in the Keychain. `TracksClient`
/// registers when there is none, and again if the server rejects it.
final class DeviceSession {
    static let shared = DeviceSession()

    nonisolated struct Credentials: Codable, Equatable, Sendable {
        var deviceId: UUID
        var token: String
    }

    /// Keychain service. Each UI-test launch (`-uiTesting`) gets its own, so it starts
    /// as a brand-new install with no journeys and never touches the real one.
    private let service: String
    private let account = "device"

    init(service: String = DeviceSession.defaultService) {
        self.service = service
    }

    nonisolated static let defaultService: String = {
        let base = "com.joshuazacek.TrainTracker.tracks"
        return ProcessInfo.processInfo.arguments.contains("-uiTesting") ? "\(base).uitest.\(UUID().uuidString)" : base
    }()

    var credentials: Credentials? {
        get {
            Keychain.read(account, service: service).flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Keychain.write(data, account: account, service: service)
            } else {
                Keychain.delete(account, service: service)
            }
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// Development builds get pushes from Apple's sandbox.
    static var apnsEnvironment: ApnsEnvironment {
        #if DEBUG
            .sandbox
        #else
            .production
        #endif
    }
}
