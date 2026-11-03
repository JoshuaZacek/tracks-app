import SwiftUI

/// One journey on the Journeys screen: time box on the left, then origin and
/// destination with the route line between them, filled in teal as the train
/// travels. Underneath: the platform (under the station it's at) and the live
/// status (countdown, arrival or cancellation).
struct JourneyCard: View {
    let journey: Journey
    var now: Date = .now

    var body: some View {
        let model = JourneyCardModel(journey: journey, now: now)
        HStack(alignment: .center, spacing: 14) {
            TimeBox(time: model.time, tone: model.timeTone)
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
                if model.platform != nil || model.status != nil {
                    HStack(alignment: .center) {
                        if let platform = model.platform {
                            PlatformBadge(number: platform, kind: model.platformKind)
                        }
                        Spacer(minLength: 8)
                        if let status = model.status {
                            Text(status)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(model.statusTone.style)
                        }
                    }
                    .padding(.top, 6)
                }
                if let stale = model.staleNote {
                    Label(stale, systemImage: "clock.badge.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        if let platform = model.platform { parts.append("platform \(platform)\(model.platformKind.accessibilityNote)") }
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

/// Grey box with the departure time: amber when late, struck through in red when cancelled.
struct TimeBox: View {
    let time: String
    var tone: JourneyCardModel.Tone = .normal

    var body: some View {
        Text(time)
            .font(.system(.title3, design: .monospaced).weight(.semibold))
            .foregroundStyle(tone == .normal ? AnyShapeStyle(.primary) : tone.style)
            .strikethrough(tone == .cancelled)
            .frame(minWidth: 74, minHeight: 50)
            .padding(.horizontal, 10)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// "Platform 4" as a small capsule: grey when booked (from the timetable),
/// teal when Darwin shows it (with a tick once confirmed), amber when it has
/// changed from the booked one.
struct PlatformBadge: View {
    enum Kind: Equatable {
        case booked
        case live(confirmed: Bool)
        case changed(from: String, confirmed: Bool)

        var accessibilityNote: String {
            switch self {
            case .booked: ""
            case .live(let confirmed): confirmed ? ", confirmed" : ""
            case .changed(let from, let confirmed): ", changed from \(from)\(confirmed ? ", confirmed" : "")"
            }
        }
    }

    let number: String
    var kind: Kind = .booked

    var body: some View {
        HStack(spacing: 4) {
            if confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
            }
            Text("Platform \(number)")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(background, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Platform \(number)\(kind.accessibilityNote)")
    }

    private var confirmed: Bool {
        switch kind {
        case .booked: false
        case .live(let confirmed), .changed(_, let confirmed): confirmed
        }
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .booked: AnyShapeStyle(.secondary)
        case .live: AnyShapeStyle(.tint)
        case .changed: AnyShapeStyle(Color.orange)
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .booked: AnyShapeStyle(Color(.tertiarySystemFill))
        case .live: AnyShapeStyle(Color.accentColor.opacity(0.14))
        case .changed: AnyShapeStyle(Color.orange.opacity(0.14))
        }
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

#if DEBUG // preview data is Debug-only
#Preview(traits: .sizeThatFitsLayout) {
    VStack(spacing: 12) {
        JourneyCard(journey: .preview(from: ("YRK", "York"), to: ("KGX", "London King's Cross"), departs: "08:30", platform: "3"))
        JourneyCard(journey: .preview(from: ("MAN", "Manchester Piccadilly"), to: ("LDS", "Leeds"), departs: "07:15", platform: nil))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
#endif
