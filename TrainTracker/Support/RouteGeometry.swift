import CoreLocation

/// The train's route on the map and where along it the train is, ported from
/// the web app (web/src/lib/trainPosition.ts). Routes run through every
/// located station the train stops at or passes; a leg is the stretch from
/// `callingPoints[leg]` to `callingPoints[leg + 1]`, and route points carry
/// how far along their leg (`f`, by timetabled times) they are.
nonisolated struct RouteGeometry: Sendable {
    let callingPoints: [CallingPoint]
    let route: [RoutePoint]

    private struct LegPoint {
        var coordinate: CLLocationCoordinate2D
        var f: Double
    }

    /// The calling points, then the stations passed between them, in order along the leg.
    private func legPoints(_ leg: Int) -> [LegPoint] {
        guard callingPoints.indices.contains(leg), callingPoints.indices.contains(leg + 1) else { return [] }
        var points: [LegPoint] = []
        if let c = callingPoints[leg].coordinate { points.append(LegPoint(coordinate: c, f: 0)) }
        for p in route where p.leg == leg {
            points.append(LegPoint(coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon), f: p.f))
        }
        if let c = callingPoints[leg + 1].coordinate { points.append(LegPoint(coordinate: c, f: 1)) }
        return points.sorted { $0.f < $1.f }
    }

    /// The line from `from` to `to` (calling point indices), through every located station.
    func path(from: Int, to: Int) -> [CLLocationCoordinate2D] {
        var path: [CLLocationCoordinate2D] = []
        for leg in from..<max(from, to) {
            for p in legPoints(leg) where path.last.map({ $0.latitude != p.coordinate.latitude || $0.longitude != p.coordinate.longitude }) ?? true {
                path.append(p.coordinate)
            }
        }
        return path
    }

    /// The point `f` (0...1) of the way along a leg, following the stations passed.
    func point(onLeg leg: Int, fraction f: Double) -> CLLocationCoordinate2D? {
        let points = legPoints(leg)
        guard let first = points.first, let last = points.last else { return nil }
        if f <= first.f { return first.coordinate }
        for (p, q) in zip(points, points.dropFirst()) where f <= q.f {
            let t = q.f == p.f ? 0 : (f - p.f) / (q.f - p.f)
            return CLLocationCoordinate2D(
                latitude: p.coordinate.latitude + (q.coordinate.latitude - p.coordinate.latitude) * t,
                longitude: p.coordinate.longitude + (q.coordinate.longitude - p.coordinate.longitude) * t
            )
        }
        return last.coordinate
    }

    /// The leg between two consecutive calling points, by CRS.
    func leg(from: String, to: String) -> Int? {
        callingPoints.indices.dropLast().first { callingPoints[$0].crs == from && callingPoints[$0 + 1].crs == to }
    }

    /// Where the train is now: on the server's current leg, as far along as the time
    /// is between leaving `legFrom` and arriving at `legTo` (live times where Darwin
    /// has them). Until the arrival is reported it stops just short of the station.
    func trainCoordinate(_ position: TrainPosition, liveCallingPoints: [CallingPoint], now: Date = .now) -> CLLocationCoordinate2D? {
        guard let leg = leg(from: position.legFrom, to: position.legTo) else { return nil }
        let fraction = Self.legFraction(leg: leg, liveCallingPoints: liveCallingPoints, now: now)
        return point(onLeg: leg, fraction: fraction ?? 0.5)
    }

    /// 0...1 through a leg by time; nil if the times aren't known.
    static func legFraction(leg: Int, liveCallingPoints cps: [CallingPoint], now: Date) -> Double? {
        guard cps.indices.contains(leg), cps.indices.contains(leg + 1) else { return nil }
        let a = cps[leg]
        let b = cps[leg + 1]
        guard let left = a.live?.actualDeparture ?? a.live?.expectedDeparture ?? a.scheduledDeparture,
              let due = b.live?.actualArrival ?? b.live?.expectedArrival ?? b.scheduledArrival,
              due > left
        else { return nil }
        let f = now.timeIntervalSince(left) / due.timeIntervalSince(left)
        let arrived = b.live?.actualArrival != nil
        return min(max(f, 0), arrived ? 1 : 0.97)
    }
}

extension CallingPoint {
    nonisolated var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
