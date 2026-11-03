import Foundation
import OSLog

/// Client for the tracks server's /v1 API. Authenticated requests carry the
/// install's bearer token (`DeviceSession`), registering the install first if
/// it has none; a 401 (the device was deleted on the server, or its token is
/// no longer valid) registers again once and retries.
///
/// The base URL defaults to the server on this Mac, which the iOS Simulator
/// reaches as localhost. Override it with the `tracksBaseURL` user default,
/// e.g. the launch argument `-tracksBaseURL http://192.168.1.20:3000`.
final class TracksClient {
    static let shared = TracksClient()

    /// Posted after the install registers (again): push tokens need sending to the new device.
    static let didRegister = Notification.Name("TracksClientDidRegister")

    let session: DeviceSession
    private let urlSession: URLSession
    /// One registration at a time, even if several requests need a token at once.
    private var registering: Task<DeviceSession.Credentials, Error>?

    init(session: DeviceSession = .shared, urlSession: URLSession = .shared) {
        self.session = session
        self.urlSession = urlSession
    }

    var baseURL: URL {
        if let custom = UserDefaults.standard.string(forKey: "tracksBaseURL"), let url = URL(string: custom) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: - Endpoints

    func status() async throws -> ServerStatus {
        try await request("GET", "/v1/status", authenticated: false)
    }

    /// At launch: make sure the install is registered and the server knows the
    /// current app version and locale. Failures are logged, not fatal; the next
    /// request tries again.
    func prepareDevice() async {
        do {
            let device = try await updateDevice(UpdateDeviceRequest(
                appVersion: DeviceSession.appVersion,
                locale: Locale.current.identifier,
                apnsEnvironment: DeviceSession.apnsEnvironment
            ))
            Logger.tracks.info("Device \(device.deviceId) ready")
        } catch {
            Logger.tracks.error("Couldn't reach the tracks server: \(error.localizedDescription)")
        }
    }

    func device() async throws -> Device {
        try await request("GET", "/v1/devices/me")
    }

    func updateDevice(_ body: UpdateDeviceRequest) async throws -> Device {
        try await request("PATCH", "/v1/devices/me", body: body)
    }

    /// Deletes the install and everything saved for it on the server.
    func deleteDevice() async throws {
        let _: Empty = try await request("DELETE", "/v1/devices/me")
        session.credentials = nil
    }

    // MARK: - Stations, departures, trains

    func stations(matching query: String, limit: Int = 15) async throws -> [Station] {
        let list: StationList = try await request("GET", "/v1/stations", query: ["q": query, "limit": String(limit)])
        return list.stations
    }

    func nearbyStations(latitude: Double, longitude: Double, limit: Int = 5) async throws -> [NearbyStation] {
        let list: NearbyStationList = try await request("GET", "/v1/stations/nearby", query: [
            "lat": String(latitude), "lon": String(longitude), "limit": String(limit),
        ])
        return list.stations
    }

    /// Timetabled passenger departures on `date` (the date I leave `crs`), from `after` ("HH:MM", UK time).
    func departures(from crs: String, date: String, to: String? = nil, after: String? = nil, cursor: String? = nil, limit: Int? = nil) async throws -> DeparturesResponse {
        try await request("GET", "/v1/stations/\(crs)/departures", query: [
            "date": date, "to": to, "after": after, "cursor": cursor, "limit": limit.map(String.init),
        ])
    }

    /// The train's calling pattern and route on a run date. 404 `train_not_running` if it doesn't run then.
    func train(uid: String, runDate: String) async throws -> TrainDetails {
        try await request("GET", "/v1/trains/\(uid)/\(runDate)")
    }

    // MARK: - Journeys

    /// This install's journeys: `upcoming` soonest first, or `past` newest first.
    func journeys(_ scope: JourneyScope, limit: Int = 100) async throws -> JourneyList {
        try await request("GET", "/v1/journeys", query: ["scope": scope.rawValue, "limit": String(limit)])
    }

    /// Saves a journey (or returns the existing one if this exact trip is already saved).
    /// Errors: `train_not_running` (not in the timetable), `station_not_on_route`.
    func createJourney(_ body: CreateJourneyRequest) async throws -> ServerJourney {
        try await request("POST", "/v1/journeys", body: body)
    }

    func journey(id: UUID) async throws -> ServerJourney {
        try await request("GET", "/v1/journeys/\(id.uuidString.lowercased())")
    }

    func updateJourney(id: UUID, _ body: UpdateJourneyRequest) async throws -> ServerJourney {
        try await request("PATCH", "/v1/journeys/\(id.uuidString.lowercased())", body: body)
    }

    func deleteJourney(id: UUID) async throws {
        let _: Empty = try await request("DELETE", "/v1/journeys/\(id.uuidString.lowercased())")
    }

    /// Starts (or resumes) server pushes to a Live Activity for this journey,
    /// whoever started it. Send again whenever the token rotates.
    func registerLiveActivity(journeyID id: UUID, pushToken: String) async throws {
        let _: Empty = try await request("PUT", "/v1/journeys/\(id.uuidString.lowercased())/live-activity", body: RegisterLiveActivityRequest(pushToken: pushToken))
    }

    /// The user dismissed the activity: stop pushing, and don't push-to-start this journey again.
    func endLiveActivity(journeyID id: UUID) async throws {
        let _: Empty = try await request("DELETE", "/v1/journeys/\(id.uuidString.lowercased())/live-activity")
    }

    func liveStatus(journeyID id: UUID) async throws -> LiveStatus {
        try await request("GET", "/v1/journeys/\(id.uuidString.lowercased())/live")
    }

    /// The OS Open Names place dataset (gzipped JSON on the wire). Pass the ETag
    /// from the last download; nil data means it hasn't changed (304).
    func places(ifNoneMatch etag: String?) async throws -> (data: Data?, etag: String?) {
        var request = URLRequest(url: baseURL.appending(path: "/v1/reference/places"))
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await urlSession.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 304: return (nil, etag)
        case 200: return (data, http?.value(forHTTPHeaderField: "ETag"))
        default:
            let body = try? Self.decoder.decode(TracksErrorBody.self, from: data)
            throw TracksError(code: body?.error.code ?? .unknown, message: body?.error.message ?? "Couldn't download place names", httpStatus: http?.statusCode ?? 0)
        }
    }

    // MARK: - Registration

    /// The bearer token, registering the install first if needed.
    func token() async throws -> String {
        if let credentials = session.credentials { return credentials.token }
        return try await register().token
    }

    private func register() async throws -> DeviceSession.Credentials {
        if let registering { return try await registering.value }
        let task = Task {
            let body = RegisterDeviceRequest(appVersion: DeviceSession.appVersion, locale: Locale.current.identifier)
            let response: RegisterDeviceResponse = try await send("POST", "/v1/devices", query: [:], body: body, token: nil)
            return DeviceSession.Credentials(deviceId: response.deviceId, token: response.token)
        }
        registering = task
        defer { registering = nil }
        let credentials = try await task.value
        session.credentials = credentials
        Logger.tracks.info("Registered device \(credentials.deviceId)")
        // A new device on the server knows none of this install's push tokens yet.
        NotificationCenter.default.post(name: Self.didRegister, object: self)
        return credentials
    }

    // MARK: - Transport

    private struct Empty: Decodable {}

    func request<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String?] = [:],
        body: (any Encodable)? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        var token = authenticated ? try await self.token() : nil
        for attempt in 0..<2 {
            do {
                return try await send(method, path, query: query, body: body, token: token)
            } catch let error as TracksError where error.code == .unauthorized && authenticated && attempt == 0 {
                Logger.tracks.info("Device token rejected; registering again")
                session.credentials = nil
                token = try await register().token
            }
        }
        throw TracksError(code: .unauthorized, message: "Couldn't authenticate with the server", httpStatus: 401)
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [String: String?], body: (any Encodable)?, token: String?) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try Self.encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? Self.decoder.decode(TracksErrorBody.self, from: data)
            throw TracksError(code: body?.error.code ?? .unknown, message: body?.error.message ?? "Request failed (\(status))", httpStatus: status)
        }
        if status == 204 || data.isEmpty {
            return try Self.decoder.decode(Response.self, from: Data("{}".utf8))
        }
        return try Self.decoder.decode(Response.self, from: data)
    }
}

extension Logger {
    static let tracks = Logger(subsystem: "com.joshuazacek.TrainTracker", category: "tracks")
}
