import SwiftUI

/// One journey on the Journeys screen: time box on the left, then origin and
/// destination with the route line between them, filled in teal as the train
/// travels, and a live status line (countdown, arrival or cancellation).
struct JourneyCard: View {
    let journey: Journey
    var now: Date = .now

    var body: some View {
        let model = JourneyCardModel(journey: journey, now: now)
        HStack(alignment: .center, spacing: 14) {
            TimeBox(time: model.time, tone: model.timeTone, platform: model.platform, platformConfirmed: model.platformConfirmed)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(journey.from.crs)
                    RouteLine(progress: model.progress)
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
                if model.status != nil || model.staleNote != nil {
                    HStack(alignment: .firstTextBaseline) {
                        if let stale = model.staleNote {
                            Label(stale, systemImage: "clock.badge.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if let status = model.status {
                            Text(status)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(model.statusTone.style)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(model))
        .accessibilityIdentifier("journeyCard")
    }

    private func accessibilityText(_ model: JourneyCardModel) -> String {
        var parts = ["\(model.time) from \(journey.from.name) to \(journey.to.name)"]
        if model.timeTone == .late { parts.append("running late") }
        if let platform = model.platform { parts.append("platform \(platform)\(model.platformConfirmed ? ", confirmed" : "")") }
        if let status = model.status { parts.append(status) }
        if let stale = model.staleNote { parts.append(stale) }
        return parts.joined(separator: ", ")
    }
}

extension JourneyCardModel.Tone {
    /// Teal (the tint) normally; amber when late; red when cancelled.
    var style: AnyShapeStyle {
        switch self {
        case .normal: AnyShapeStyle(.tint)
        case .late: AnyShapeStyle(Color.orange)
        case .cancelled: AnyShapeStyle(Color.red)
        }
    }
}

/// Grey box with the departure time and, when known, the platform (in full
/// strength once Darwin confirms it).
struct TimeBox: View {
    let time: String
    var tone: JourneyCardModel.Tone = .normal
    let platform: String?
    var platformConfirmed = false

    var body: some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(tone == .normal ? AnyShapeStyle(.primary) : tone.style)
                .strikethrough(tone == .cancelled)
            if let platform {
                Text("plat. \(platform)")
                    .font(.footnote.weight(platformConfirmed ? .semibold : .regular))
                    .foregroundStyle(platformConfirmed ? .primary : .secondary)
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
        JourneyCard(journey: .preview(from: ("YRK", "York"), to: ("KGX", "London King's Cross"), departs: "08:30", platform: "3"))
        JourneyCard(journey: .preview(from: ("MAN", "Manchester Piccadilly"), to: ("LDS", "Leeds"), departs: "07:15", platform: nil))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
