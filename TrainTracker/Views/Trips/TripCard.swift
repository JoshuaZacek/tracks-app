import SwiftUI

/// The legs of a trip as one card on the Journeys screen: each train as on its
/// own card, with a strip between them saying how the change looks.
struct TripCard: View {
    let legs: [Journey]
    var now: Date = .now

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(legs.enumerated()), id: \.element.id) { index, leg in
                JourneyCard(journey: leg, now: now, embedded: true)
                if index < legs.count - 1 {
                    ConnectionStrip(connection: leg.connection, station: leg.to.name)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tripCard")
    }
}

/// One line between two legs: "Change at Peterborough · 8 min to change",
/// teal when there's time, amber when tight or at risk, red when missed.
struct ConnectionStrip: View {
    /// Nil until the server has worked it out (e.g. cached before trips existed).
    let connection: Connection?
    /// Where the change is, for when there's no connection yet.
    let station: String

    var body: some View {
        let display = connection.map(ConnectionDisplay.init)
        HStack(spacing: 8) {
            Image(systemName: display?.symbol ?? "arrow.triangle.swap")
                .imageScale(.small)
            Text(display?.title ?? "Change at \(station)")
                .lineLimit(1)
            if let display {
                Spacer(minLength: 8)
                Text(display.detail)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
        }
        .font(.footnote)
        .foregroundStyle(display?.tone.style ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((display?.tone.style ?? AnyShapeStyle(.secondary)).opacity(0.12), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display?.accessibilityLabel ?? "Change at \(station)")
        .accessibilityIdentifier("connectionStrip")
    }
}

extension ConnectionDisplay.Tone {
    /// Teal (the tint) when there's time; amber when tight or at risk; red when missed.
    var style: AnyShapeStyle {
        switch self {
        case .ok: AnyShapeStyle(.tint)
        case .warning: AnyShapeStyle(Color.orange)
        case .bad: AnyShapeStyle(Color.red)
        }
    }
}

#if DEBUG // preview data is Debug-only
#Preview(traits: .sizeThatFitsLayout) {
    let first = Journey.preview(from: ("KGX", "London King's Cross"), to: ("PBO", "Peterborough"), departs: "17:00", arrives: "17:45", platform: "7")
    let second = Journey.preview(from: ("PBO", "Peterborough"), to: ("YRK", "York"), departs: "17:53", arrives: "19:00", platform: "3")
    first.connection = Connection(
        leg: 1, station: Station(crs: "PBO", name: "Peterborough"), status: .tight, message: "3 min to change",
        arrival: first.arrivesAt, departure: second.departsAt, minimumChangeMinutes: 5, marginMinutes: 3, scheduledMarginMinutes: 3, cancelled: false
    )
    return TripCard(legs: [first, second])
        .padding()
        .background(Color(.systemGroupedBackground))
}
#endif
