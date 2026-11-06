import CoreLocation
import MapKit
import OSLog

/// Suggests how long it takes to get to a station: an Apple Maps ETA from
/// where the phone is now. The location stays on the phone; only the minutes
/// are ever sent to the server.
enum TravelTimeSuggestion {
    /// Minutes, rounded up to the next five; nil without a location, the
    /// station's position, or directions.
    static func minutes(to station: Station) async -> Int? {
        guard let lat = station.lat, let lon = station.lon else { return nil }
        return await minutes(to: CLLocation(latitude: lat, longitude: lon))
    }

    private static func minutes(to destination: CLLocation) async -> Int? {
        guard let here = await CurrentLocation.fetch() else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: here, address: nil)
        request.destination = MKMapItem(location: destination, address: nil)
        request.transportType = TravelTime.walks(distanceMeters: here.distance(from: destination)) ? .walking : .automobile
        do {
            let eta = try await MKDirections(request: request).calculateETA()
            return TravelTime.suggestedMinutes(eta: eta.expectedTravelTime)
        } catch {
            Logger.tracks.error("No directions to the station: \(error.localizedDescription)")
            return nil
        }
    }
}
