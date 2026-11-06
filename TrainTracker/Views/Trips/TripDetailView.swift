import SwiftData
import SwiftUI

/// A trip in full ("Will I make it?"): each train with its stops, one after the
/// other, and between them the change: how much time there is and, when it's
/// at risk or missed, later trains to switch to in one tap.
struct TripDetailView: View {
    let tripID: UUID
    @Query(sort: \Journey.departsAt) private var journeys: [Journey]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var model: TripDetailModel
    @State private var addingConnection = false
    @State private var confirmingUnlink = false

    init(tripID: UUID) {
        self.tripID = tripID
        _model = State(initialValue: TripDetailModel(tripID: tripID))
    }

    /// The trip's legs here, in travelling order.
    private var legs: [Journey] {
        journeys.filter { $0.trip?.id == tripID }.sorted { ($0.trip?.leg ?? 0) < ($1.trip?.leg ?? 0) }
    }

    var body: some View {
        let legs = legs
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            ScrollView {
                VStack(spacing: 16) {
                    if legs.isEmpty {
                        ContentUnavailableView("No longer linked", systemImage: "arrow.triangle.swap",
                                               description: Text("These trains are on their own now."))
                    }
                    ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                        TripLegSection(journey: leg, number: index + 1, of: legs.count, now: timeline.date)
                        if index < legs.count - 1 {
                            ConnectionPanel(
                                connection: model.connection(after: index + 1)?.connection ?? leg.connection,
                                station: leg.to.name,
                                alternatives: model.connection(after: index + 1)?.alternatives ?? [],
                                loaded: model.trip != nil,
                                switching: model.switching
                            ) { departure, connection in
                                Task { await model.switchTo(departure, after: connection, in: context) }
                            }
                        }
                    }
                    if let error = model.error {
                        Label(error, systemImage: "wifi.slash")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let last = legs.last, canAddConnection(after: last) {
                        Button("Add connecting train", systemImage: "arrow.triangle.branch") { addingConnection = true }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                            .accessibilityIdentifier("addConnection")
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
        }
        .navigationTitle(legs.first.map { "\($0.from.crs) → \(legs.last!.to.crs)" } ?? "Trip")
        .navigationSubtitle(legs.count > 2 ? "\(legs.count - 1) changes" : "1 change")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Unlink trains", systemImage: "link.badge.plus") { confirmingUnlink = true }
                }
                .accessibilityIdentifier("tripMenu")
            }
        }
        .confirmationDialog("Unlink these trains?", isPresented: $confirmingUnlink, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) {
                Task {
                    try? await JourneySync.shared.unlink(tripID: tripID, in: context)
                    dismiss()
                }
            }
        } message: {
            Text("The trains stay saved, each on its own, and changes between them are no longer followed.")
        }
        .sheet(isPresented: $addingConnection) {
            if let last = legs.last {
                AddJourneyView(connectingFrom: last)
            }
        }
        .refreshable { await model.refresh(in: context) }
        .task { await model.run(in: context) }
    }

    private func canAddConnection(after leg: Journey) -> Bool {
        guard leg.archivedAt == nil else { return false }
        if let state = leg.live?.state, [.arrived, .cancelled, .notFound].contains(state) { return false }
        return leg.expectedArrival > .now
    }
}

/// One train of a trip: its card (opening the journey, with its map and alerts),
/// any message from the server, and its stops with live times.
private struct TripLegSection: View {
    let number: Int
    let total: Int
    let now: Date
    @State private var model: JourneyDetailModel

    init(journey: Journey, number: Int, of total: Int, now: Date) {
        self.number = number
        self.total = total
        self.now = now
        _model = State(initialValue: JourneyDetailModel(journey: journey))
    }

    private var journey: Journey { model.journey }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Train \(number) of \(total) · \(journey.operatorName)")
                .font(.headline.weight(.regular))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
            NavigationLink {
                JourneyDetailView(journey: journey)
            } label: {
                JourneyCard(journey: journey, now: now)
            }
            .buttonStyle(.plain)
            let messages = [model.status?.message, model.status?.service?.delayReason, model.status?.service?.cancelReason].compactMap { $0 }
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
            let rows = StopRow.rows(for: journey, liveCallingPoints: model.liveCallingPoints, now: now)
            StopList(rows: rows, trainFraction: model.trainFraction(rows: rows, now: now))
        }
        .task { await model.run() }
    }
}

/// The change between two trains: the times and platforms, how it looks, and
/// when it's at risk or missed, the later trains to switch to.
struct ConnectionPanel: View {
    let connection: Connection?
    let station: String
    let alternatives: [Departure]
    /// The trip has been fetched, so an empty list of alternatives means there are none.
    let loaded: Bool
    /// The alternative being switched to.
    let switching: String?
    let onSwitch: (Departure, Connection) -> Void

    var body: some View {
        let display = connection.map(ConnectionDisplay.init)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: display?.symbol ?? "arrow.triangle.swap")
                    .foregroundStyle(display?.tone.style ?? AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(display?.title ?? "Change at \(station)")
                        .font(.headline)
                    if let display {
                        Text(display.detail)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(display.tone.style)
                    }
                    if let connection {
                        Text(ConnectionDisplay.times(connection))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connectionPanel")
            if let connection, let display, display.offersAlternatives {
                alternativesList(connection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder((display?.tone.style ?? AnyShapeStyle(.clear)).opacity(display?.tone == .ok ? 0 : 0.5), lineWidth: 1.5)
        }
    }

    @ViewBuilder
    private func alternativesList(_ connection: Connection) -> some View {
        Divider()
        if alternatives.isEmpty {
            Text(loaded ? "No later trains found that you can still make." : "Looking for later trains…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Text("Later trains")
                .font(.subheadline.bold())
            ForEach(alternatives) { d in
                AlternativeRow(departure: d, switching: switching == d.id, disabled: switching != nil) {
                    onSwitch(d, connection)
                }
            }
        }
    }
}

/// A later train from the change station: when it leaves (live if known),
/// where it gets me and when, and the one-tap switch.
private struct AlternativeRow: View {
    let departure: Departure
    let switching: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        let leaves = departure.live?.expectedDeparture ?? departure.scheduledDeparture
        let late = leaves > departure.scheduledDeparture.addingTimeInterval(59)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(RailTime.hhmm(leaves))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(late ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                Text("to \(departure.destination.name)")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let platform = departure.live?.platform?.number ?? departure.bookedPlatform {
                    PlatformBadge(number: platform, confirmed: departure.live?.platform?.confirmed ?? false)
                }
            }
            if let arrival = departure.arrival {
                Text("Arrives \(arrival.station.name) \(RailTime.hhmm(arrival.scheduledArrival)) · \(departure.operator.name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(action: action) {
                HStack(spacing: 6) {
                    if switching { ProgressView().controlSize(.small) }
                    Text("Switch to this train")
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(disabled)
            .accessibilityLabel("Switch to the \(RailTime.hhmm(departure.scheduledDeparture)) to \(departure.destination.name)")
            .accessibilityIdentifier("switchTrain")
        }
        .padding(.vertical, 4)
    }
}
