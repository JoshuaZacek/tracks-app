import CoreLocation

/// One-off "where am I" for finding nearby stations. Asks for When In Use
/// permission the first time; never tracks in the background.
enum CurrentLocation {
    /// Whether the user already allowed location, so nearby stations can load without asking.
    static var isAuthorized: Bool {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    /// The first location fix, or nil if permission is denied or none arrives within `timeout`.
    static func fetch(timeout: Duration = .seconds(10)) async -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted { return nil }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
