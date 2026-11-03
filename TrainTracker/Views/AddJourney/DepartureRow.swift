import SwiftUI

/// One train in the Add journey list.
struct DepartureRow: View {
    let departure: Departure
    var departed = false
    var saved = false
    var saving = false

    var body: some View {
        HStack(spacing: 12) {
            Text(RailTime.hhmm(departure.scheduledDeparture))
                .font(.body.monospaced().weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(departure.destination.name)
                    .font(.body.weight(.semibold))
                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if let arrival = departure.arrival {
                let time = RailTime.hhmm(arrival.scheduledArrival)
                let nextDay = RailTime.ymd(arrival.scheduledArrival) != RailTime.ymd(departure.scheduledDeparture)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(nextDay ? "arr +1 day" : "arr")
                        .font(.caption2)
                    Text(time)
                        .font(.subheadline.monospaced())
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("arrives \(time)\(nextDay ? " the next day" : "")")
            }
            if saving {
                ProgressView()
            } else if saved {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Saved")
            }
        }
        .opacity(departed ? 0.5 : 1)
    }

    private var details: String {
        var parts = [departure.operator.name, departure.headcode]
        if let platform = departure.bookedPlatform { parts.append("plat. \(platform)") }
        return parts.joined(separator: " · ")
    }
}
