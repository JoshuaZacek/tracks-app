import SwiftUI

/// One journey on the Journeys screen: time box on the left, then origin and
/// destination with the route line between them.
struct JourneyCard: View {
    let journey: Journey
    /// Share of the trip completed (0...1), shown as the teal fill. Nil before departure.
    var progress: Double? = nil
    /// Teal line under the destination, e.g. "in 43 min".
    var countdown: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            TimeBox(time: RailTime.hhmm(journey.departsAt), platform: journey.from.bookedPlatform)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(journey.from.crs)
                    RouteLine(progress: progress)
                    Text(journey.to.crs)
                }
                .font(.title3.weight(.semibold))
                HStack(alignment: .firstTextBaseline) {
                    Text(journey.from.name)
                    Spacer(minLength: 12)
                    Text(journey.to.name).multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let countdown {
                    Text(countdown)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("journeyCard")
    }

    private var accessibilityText: String {
        var parts = ["\(RailTime.hhmm(journey.departsAt)) from \(journey.from.name) to \(journey.to.name)"]
        if let platform = journey.from.bookedPlatform { parts.append("platform \(platform)") }
        if let countdown { parts.append(countdown) }
        return parts.joined(separator: ", ")
    }
}

/// Grey box with the departure time and, when known, the platform.
struct TimeBox: View {
    let time: String
    let platform: String?

    var body: some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
            if let platform {
                Text("plat. \(platform)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 74, minHeight: 50)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// The line between origin and destination: grey with end dots, filled in teal
/// up to `progress` once the train is under way.
struct RouteLine: View {
    var progress: Double?

    var body: some View {
        GeometryReader { geo in
            let dot: CGFloat = 9
            let inset = dot / 2
            let width = max(0, geo.size.width - dot)
            let fill = CGFloat(min(max(progress ?? 0, 0), 1)) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemFill))
                    .frame(height: 4)
                    .padding(.horizontal, inset)
                if progress != nil {
                    Capsule()
                        .fill(.tint)
                        .frame(width: fill, height: 4)
                        .padding(.leading, inset)
                }
                Circle()
                    .fill(progress != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemFill)))
                    .frame(width: dot, height: dot)
                Circle()
                    .fill(Color(.systemFill))
                    .frame(width: dot, height: dot)
                    .offset(x: width)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

#Preview(traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        JourneyCard(journey: .preview(from: ("YRK", "York"), to: ("KGX", "London King's Cross"), departs: "08:30", platform: "3"), progress: 0.55, countdown: "in 43 min")
        JourneyCard(journey: .preview(from: ("MAN", "Manchester Piccadilly"), to: ("LDS", "Leeds"), departs: "07:15", platform: nil))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
