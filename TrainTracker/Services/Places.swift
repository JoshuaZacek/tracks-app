import Foundation
import OSLog

/// The OS Open Names place dataset from `/v1/reference/places`:
/// `[name, lat × 1e5, lon × 1e5, type index, (south, west, north, east × 1e5 for cities and towns)]`.
nonisolated struct PlacesDataset: Decodable, Sendable {
    struct Place: Decodable, Sendable {
        var name: String
        var lat: Double
        var lon: Double
        var type: Int
        /// South, west, north, east in degrees (cities and towns only).
        var extent: (s: Double, w: Double, n: Double, e: Double)?

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            name = try c.decode(String.self)
            lat = Double(try c.decode(Int.self)) / 1e5
            lon = Double(try c.decode(Int.self)) / 1e5
            type = try c.decode(Int.self)
            if !c.isAtEnd {
                extent = (
                    Double(try c.decode(Int.self)) / 1e5, Double(try c.decode(Int.self)) / 1e5,
                    Double(try c.decode(Int.self)) / 1e5, Double(try c.decode(Int.self)) / 1e5
                )
            }
        }
    }

    var attribution: String
    var types: [String]
    var places: [Place]
}

/// Nearest-town lookup, ported from the web app (web/src/lib/places.ts):
/// a 0.2° grid for nearest places, plus city and town extents so anywhere in
/// London is "London", not "near Ewell".
nonisolated struct PlaceIndex: Sendable {
    struct Place: Sendable, Equatable {
        var name: String
        var type: String
        var distanceKm: Double
    }

    struct Nearest: Sendable, Equatable {
        /// Smallest city or town whose extent contains the position.
        var within: Place?
        /// Closest city or town.
        var town: Place?
        /// Closest village or suburb.
        var local: Place?
    }

    let attribution: String
    private let dataset: PlacesDataset
    private let grid: [GridKey: [Int]]
    private static let cell = 0.2
    private static let townTypes: Set<String> = ["City", "Town"]

    private struct GridKey: Hashable, Sendable {
        var row: Int
        var col: Int
    }

    init(_ dataset: PlacesDataset) {
        self.dataset = dataset
        attribution = dataset.attribution
        var grid: [GridKey: [Int]] = [:]
        for (i, p) in dataset.places.enumerated() {
            grid[GridKey(row: Int((p.lat / Self.cell).rounded(.down)), col: Int((p.lon / Self.cell).rounded(.down))), default: []].append(i)
        }
        self.grid = grid
    }

    func nearest(latitude: Double, longitude: Double) -> Nearest {
        var best = Nearest()
        var withinArea = Double.infinity
        for p in dataset.places {
            guard let e = p.extent, latitude >= e.s, latitude <= e.n, longitude >= e.w, longitude <= e.e else { continue }
            let area = (e.n - e.s) * (e.e - e.w)
            if area < withinArea {
                withinArea = area
                best.within = Place(name: p.name, type: dataset.types[p.type], distanceKm: 0)
            }
        }
        let row = Int((latitude / Self.cell).rounded(.down))
        let col = Int((longitude / Self.cell).rounded(.down))
        for r in (row - 2)...(row + 2) {
            for c in (col - 2)...(col + 2) {
                for i in grid[GridKey(row: r, col: c)] ?? [] {
                    let p = dataset.places[i]
                    let type = dataset.types[p.type]
                    let d = Self.distanceKm(latitude, longitude, p.lat, p.lon)
                    guard d <= 40 else { continue }
                    let candidate = Place(name: p.name, type: type, distanceKm: d)
                    if Self.townTypes.contains(type) {
                        if best.town.map({ d < $0.distanceKm }) ?? true { best.town = candidate }
                    } else if best.local.map({ d < $0.distanceKm }) ?? true {
                        best.local = candidate
                    }
                }
            }
        }
        return best
    }

    /// "In London" / "South Wimbledon, London" inside a town's extent; otherwise
    /// "Near Retford" / "Weston, near Retford" within 10 km of a town; otherwise
    /// the closest village. Nil out at sea or outside Great Britain.
    func describe(latitude: Double, longitude: Double) -> String? {
        let n = nearest(latitude: latitude, longitude: longitude)
        let localNearby = n.local.flatMap { $0.distanceKm <= 2 ? $0 : nil }
        if let within = n.within {
            if let local = localNearby, local.name != within.name { return "\(local.name), \(within.name)" }
            return "In \(within.name)"
        }
        if let town = n.town, town.distanceKm <= 10 {
            if let local = localNearby, local.name != town.name { return "\(local.name), near \(town.name)" }
            return "Near \(town.name)"
        }
        if let local = n.local { return "Near \(local.name)" }
        return n.town.map { "Near \($0.name)" }
    }

    private static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let x = (lon2 - lon1) * .pi / 180 * cos((lat1 + lat2) / 2 * .pi / 180)
        let y = (lat2 - lat1) * .pi / 180
        return (x * x + y * y).squareRoot() * 6371
    }
}

/// Keeps the place dataset on the device: downloaded once, cached in Caches,
/// and revalidated with its ETag at most once per launch, so nearest-town
/// labels also work offline.
final class PlacesStore {
    static let shared = PlacesStore()

    private var index: PlaceIndex?
    private var refreshed = false
    private let cacheURL = URL.cachesDirectory.appending(path: "places.json")
    private let etagKey = "placesETag"

    /// The lookup, from memory, the disk cache or the server (in that order).
    func placeIndex() async -> PlaceIndex? {
        if index == nil, let data = try? Data(contentsOf: cacheURL) {
            index = await Self.decode(data)
        }
        if index == nil || !refreshed {
            await refresh()
        }
        return index
    }

    private func refresh() async {
        refreshed = true
        do {
            let etag = index == nil ? nil : UserDefaults.standard.string(forKey: etagKey)
            let result = try await TracksClient.shared.places(ifNoneMatch: etag)
            guard let data = result.data else { return } // 304: the cached copy is current
            guard let fresh = await Self.decode(data) else { return }
            index = fresh
            try data.write(to: cacheURL, options: .atomic)
            UserDefaults.standard.set(result.etag, forKey: etagKey)
            Logger.tracks.info("Place names updated")
        } catch {
            Logger.tracks.error("Couldn't update place names: \(error.localizedDescription)")
        }
    }

    /// Decoding and indexing ~27,000 places happens off the main thread.
    @concurrent private static func decode(_ data: Data) async -> PlaceIndex? {
        (try? JSONDecoder().decode(PlacesDataset.self, from: data)).map(PlaceIndex.init)
    }
}
