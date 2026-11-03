import SwiftUI

/// Searches stations by name or CRS code and returns the one tapped. With an
/// empty search it offers the stations nearest the user.
struct StationPicker: View {
    let title: String
    @Binding var selection: Station?
    /// Offer "Any station" (for the optional destination).
    var allowsAny = false

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Station] = []
    @State private var nearby: Nearby = .notAsked
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    private enum Nearby {
        case notAsked, locating, found([NearbyStation]), unavailable(String)
    }

    var body: some View {
        List {
            if allowsAny && selection != nil {
                Button("Any station") {
                    selection = nil
                    dismiss()
                }
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if query.isEmpty {
                nearbySection
            }
            ForEach(results) { station in
                stationButton(station)
            }
        }
        .overlay {
            if results.isEmpty && !query.isEmpty && error == nil {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station name or CRS")
        .searchFocused($searchFocused)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .onAppear { searchFocused = true }
        .task {
            // Don't prompt for location on opening; only load straight away if already allowed.
            if CurrentLocation.isAuthorized { await findNearby() }
        }
        .task(id: query) {
            // Wait for a pause in typing before asking the server.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else {
                results = []
                return
            }
            do {
                results = try await TracksClient.shared.stations(matching: q)
                error = nil
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var nearbySection: some View {
        Section("Nearby") {
            switch nearby {
            case .notAsked:
                Button("Find stations near me", systemImage: "location") {
                    Task { await findNearby() }
                }
            case .locating:
                HStack {
                    Text("Finding stations near you…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            case .found(let stations):
                ForEach(stations) { station in
                    stationButton(station.station, distance: station.distanceMeters)
                }
            case .unavailable(let reason):
                Text(reason).foregroundStyle(.secondary)
            }
        }
    }

    private func stationButton(_ station: Station, distance: Int? = nil) -> some View {
        Button {
            selection = station
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                    if let distance {
                        Text(Self.distanceText(distance))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(station.crs)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
        .accessibilityIdentifier("station-\(station.crs)")
    }

    private func findNearby() async {
        nearby = .locating
        guard let location = await CurrentLocation.fetch() else {
            nearby = .unavailable("Location isn't available. You can allow it in Settings.")
            return
        }
        do {
            let stations = try await TracksClient.shared.nearbyStations(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
            // Outside Great Britain the "nearest" stations are hundreds of miles away.
            let close = stations.filter { $0.distanceMeters <= 50_000 }
            nearby = close.isEmpty ? .unavailable("No stations within 50 km.") : .found(close)
        } catch {
            nearby = .unavailable(error.localizedDescription)
        }
    }

    /// UK road units: "140 yd", "0.5 mi", "12 mi".
    static func distanceText(_ meters: Int) -> String {
        Measurement(value: Double(meters), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.significantDigits(1...2))).locale(Locale(identifier: "en_GB")))
    }
}
