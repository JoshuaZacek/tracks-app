import MapKit
import SwiftUI

/// A journey in full: the route on a map with the train's position, the
/// journey card, and every stop with live times and where the train is now.
struct JourneyDetailView: View {
    @State private var model: JourneyDetailModel
    @State private var showingAlerts = false

    init(journey: Journey) {
        _model = State(initialValue: JourneyDetailModel(journey: journey))
    }

    private var journey: Journey { model.journey }

    var body: some View {
        // Redrawn every few seconds so the train moves smoothly between updates.
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let now = timeline.date
            let train = model.status?.position.flatMap { model.geometry.trainCoordinate($0, liveCallingPoints: model.liveCallingPoints, now: now) }
            ScrollView {
                VStack(spacing: 16) {
                    JourneyRouteMap(geometry: model.geometry, fromIndex: journey.fromIndex, toIndex: journey.toIndex, train: train, headcode: journey.headcode)
                        .frame(height: 300)
                        .clipShape(.rect(cornerRadius: 24, style: .continuous))
                    JourneyCard(journey: journey, now: now)
                    notes
                    let rows = StopRow.rows(for: journey, liveCallingPoints: model.liveCallingPoints, now: now)
                    StopList(
                        rows: rows,
                        indicator: indicator(train: train, now: now),
                        trainFraction: trainFraction(rows: rows, now: now)
                    )
                    if train != nil, let attribution = model.placeIndex?.attribution {
                        Text("Place names: \(attribution)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle("\(journey.from.crs) → \(journey.to.crs)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Alerts", systemImage: LiveActivities.shared.isRunning(for: journey.id) ? "bell.badge.fill" : "bell") {
                    showingAlerts = true
                }
                .accessibilityIdentifier("journeyAlerts")
            }
        }
        .sheet(isPresented: $showingAlerts) {
            JourneyAlertsView(journey: journey)
                .presentationDetents([.medium, .large])
        }
        .refreshable { await model.refresh() }
        .task { await model.run() }
    }

    /// The server's message ("No longer calling at X", feed gaps) and any connection problem.
    @ViewBuilder
    private var notes: some View {
        let messages = [model.status?.message, model.status?.service?.delayReason, model.status?.service?.cancelReason, model.error].compactMap { $0 }
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(messages, id: \.self) { Text($0) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
        }
    }

    /// How far the train is from the last of my stops it reached to the next, by
    /// time (as on the map); nil unless it's under way on my part of the route.
    private func trainFraction(rows: [StopRow], now: Date) -> Double? {
        guard model.status?.state == .departed, let last = rows.lastIndex(where: \.passed), last < rows.count - 1 else { return nil }
        // Row ids are calling point indexes, and my stops are consecutive calling points.
        return RouteGeometry.legFraction(leg: rows[last].id, liveCallingPoints: model.liveCallingPoints, now: now) ?? 0.5
    }

    /// Between the last stop passed and the next, while the train is on my part of the route.
    private func indicator(train: CLLocationCoordinate2D?, now: Date) -> StopList.Indicator? {
        guard let status = model.status, status.state == .departed, let position = status.position else { return nil }
        let place = train.flatMap { model.placeIndex?.describe(latitude: $0.latitude, longitude: $0.longitude) }
        let verb = switch position.last.event {
        case .arrival: "At"
        case .departure: "Left"
        case .pass: "Passed"
        }
        var next: String?
        if let n = position.next {
            let minutes = Int((n.expectedTime.timeIntervalSince(now) / 60).rounded(.up))
            next = minutes > 0 ? "\(n.name) in \(JourneyCardModel.duration(minutes))" : "Approaching \(n.name)"
        }
        return StopList.Indicator(
            place: place ?? "Between \(position.legFrom) and \(position.legTo)",
            report: "\(verb) \(position.last.name) \(RailTime.hhmm(position.last.time))",
            next: next
        )
    }
}

/// The train's whole route faintly, my part of it in teal, my stations, and the train.
struct JourneyRouteMap: View {
    let geometry: RouteGeometry
    let fromIndex: Int
    let toIndex: Int
    let train: CLLocationCoordinate2D?
    let headcode: String
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let mine = geometry.path(from: fromIndex, to: toIndex)
        Map(position: $camera) {
            MapPolyline(coordinates: geometry.path(from: 0, to: geometry.callingPoints.count - 1))
                .stroke(Color.secondary.opacity(0.35), lineWidth: 3)
            MapPolyline(coordinates: mine)
                .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            ForEach(Array(geometry.callingPoints.enumerated()).filter { $0.offset >= fromIndex && $0.offset <= toIndex }, id: \.offset) { index, stop in
                if let c = stop.coordinate {
                    let end = index == fromIndex || index == toIndex
                    Annotation(end ? stop.name : "", coordinate: c, anchor: .center) {
                        Circle()
                            .fill(Color(.systemBackground))
                            .stroke(.tint, lineWidth: end ? 4 : 2)
                            .frame(width: end ? 14 : 9, height: end ? 14 : 9)
                    }
                }
            }
            if let train {
                Annotation(headcode, coordinate: train, anchor: .center) {
                    TrainMarker()
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
        .accessibilityLabel("Map of the route")
    }
}

/// A pulsing teal train marker.
struct TrainMarker: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(.tint.opacity(0.25))
                .frame(width: 34, height: 34)
                .scaleEffect(pulse ? 1.3 : 0.8)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(Color(.systemBackground))
                .stroke(.tint, lineWidth: 3)
                .frame(width: 26, height: 26)
            Image(systemName: "tram.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tint)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("Train")
    }
}
