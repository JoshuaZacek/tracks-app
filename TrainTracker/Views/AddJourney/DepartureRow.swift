import SwiftUI

/// One train in the Add journey list, with Darwin's live times, platform and
/// cancellations for trains running today.
struct DepartureRow: View {
    let departure: Departure
    var departed = false
    var saved = false
    var saving = false

    var body: some View {
        HStack(spacing: 12) {
            timeColumn
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

    /// Scheduled time, or the live time over the struck-through scheduled one when they differ.
    @ViewBuilder
    private var timeColumn: some View {
        let scheduled = RailTime.hhmm(departure.scheduledDeparture)
        let live = departure.live
        let liveTime = (live?.actualDeparture ?? live?.expectedDeparture).map(RailTime.hhmm)
        VStack(spacing: 0) {
            if live?.isCancelled == true {
                Text(scheduled)
                    .font(.body.monospaced().weight(.semibold))
                    .strikethrough()
                    .foregroundStyle(.red)
            } else if let liveTime, liveTime != scheduled {
                Text(liveTime)
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle((live?.delayMinutes ?? 0) > 0 ? .orange : .primary)
                Text(scheduled)
                    .font(.caption.monospaced())
                    .strikethrough()
                    .foregroundStyle(.secondary)
            } else {
                Text(scheduled)
                    .font(.body.monospaced().weight(.semibold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(timeAccessibility(scheduled: scheduled, liveTime: liveTime))
    }

    private func timeAccessibility(scheduled: String, liveTime: String?) -> String {
        if departure.live?.isCancelled == true { return "\(scheduled), cancelled" }
        if let liveTime, liveTime != scheduled { return "\(scheduled), expected \(liveTime)" }
        return scheduled
    }

    private var details: String {
        var parts = [departure.operator.name, departure.headcode]
        if departure.live?.isCancelled == true {
            parts.append("Cancelled")
        } else if let platform = departure.live?.platform {
            parts.append("plat. \(platform.number)\(platform.confirmed ? " ✓" : "")")
        } else if let platform = departure.bookedPlatform {
            parts.append("plat. \(platform)")
        }
        return parts.joined(separator: " · ")
    }
}
