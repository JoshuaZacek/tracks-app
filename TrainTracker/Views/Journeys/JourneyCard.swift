import SwiftUI

/// One journey on the Journeys screen: time box on the left, then origin and
/// destination with the route line between them, filled in teal as the train
/// travels. Underneath: the platform (under the station it's at) and the live
/// status (countdown, arrival or cancellation). Before the train leaves, how
/// busy it is shows under the time.
struct JourneyCard: View {
    let journey: Journey
    var now: Date = .now
    /// Inside a trip's card, which draws the background for all its legs.
    var embedded = false

    var body: some View {
        let model = JourneyCardModel(journey: journey, now: now)
        HStack(alignment: .center, spacing: 14) {
            TimeBox(time: model.time, tone: model.timeTone, busy: model.busy)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(journey.from.crs)
                    // Pulses while the train is under way and the live feed is current.
                    RouteLine(progress: model.progress, pulsing: model.staleNote == nil)
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
                            PlatformBadge(number: platform, confirmed: model.platformConfirmed)
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
        .background(embedded ? Color.clear : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(model))
        .accessibilityIdentifier("journeyCard")
    }

    private func accessibilityText(_ model: JourneyCardModel) -> String {
        var parts = ["\(model.time) from \(journey.from.name) to \(journey.to.name)"]
        if model.timeTone == .late { parts.append("running late") }
        if let platform = model.platform { parts.append("platform \(platform)\(PlatformBadge.note(confirmed: model.platformConfirmed))") }
        if let busy = model.busy?.text { parts.append(busy) }
        if let status = model.status { parts.append(status) }
        if let stale = model.staleNote { parts.append(stale) }
        return parts.joined(separator: ", ")
    }
}

/// The one rhythm for everything that says "live": the Live dot's ring and
/// the under-way bar's fill start together on this clock, on every card.
enum LivePulse {
    /// One beat this often.
    static let period: TimeInterval = 5
    /// Seconds into the current beat (the same for every view at a given moment).
    static func phase(at date: Date) -> TimeInterval {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
    }
    /// Which beat it is, for telling waves apart.
    static func beat(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / period).rounded(.down)
    }
}

/// The under-way fill in two layers: a lighter "shadow" of the whole fill (so
/// the train's position always shows), and waves of solid teal growing through
/// it from the start to the train, like a ride-hailing app's trip bar. A new
/// wave starts on each LivePulse beat (with the Live dot's ring) and grows over
/// the last one, which holds at the train until then and fades as it's covered.
private struct FlowingFill: View {
    let width: CGFloat
    /// Each wave: grows to the train, holds until the next beat, then fades under the next wave.
    private static let grow: TimeInterval = 1.8
    private static let hold: TimeInterval = LivePulse.period - grow
    private static let fade: TimeInterval = 1.0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let newest = LivePulse.beat(at: context.date)
            ZStack(alignment: .leading) {
                // Backed in the card's colour so the grey track doesn't show through.
                Capsule().fill(Color(.secondarySystemGroupedBackground))
                Capsule().fill(.tint.opacity(0.3))
                // The previous wave (fading), then the new one over it.
                ForEach([newest - 1, newest], id: \.self) { wave in
                    let age = t - wave * LivePulse.period
                    Capsule()
                        .fill(.tint)
                        .frame(width: Self.reach(age) * width)
                        .opacity(Self.opacity(age))
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func reach(_ age: TimeInterval) -> Double { fastThenSlow(min(max(age / grow, 0), 1)) }

    /// Rushes through the first 60% of the distance in the first 30% of the
    /// time, then slows gradually through the rest to a stop. The slow part
    /// starts at the fast part's speed, so there's no jolt between them.
    static func fastThenSlow(_ x: Double) -> Double {
        let fastTime = 0.3, fastDistance = 0.6
        if x <= fastTime { return fastDistance * x / fastTime }
        let u = (x - fastTime) / (1 - fastTime)
        // 1 - (1 - u)^k starts at speed k; k matches the fast part's speed.
        let k = (fastDistance / fastTime) * (1 - fastTime) / (1 - fastDistance)
        return fastDistance + (1 - fastDistance) * (1 - pow(1 - u, k))
    }

    private static func opacity(_ age: TimeInterval) -> Double {
        1 - easeInOut(min(max((age - grow - hold) / fade, 0), 1))
    }

    private static func easeInOut(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

/// A soft teal ring that grows out of whatever it's behind and fades, once
/// per LivePulse beat (in step with the under-way bars): "this is live".
/// Nothing when Reduce Motion is on.
struct PulsingHalo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How long the ring takes to go out.
    private static let duration: TimeInterval = 2.4

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { context in
                let x = min(LivePulse.phase(at: context.date) / Self.duration, 1)
                let out = 1 - (1 - x) * (1 - x) // ease out
                Circle()
                    .fill(.tint)
                    .scaleEffect(1 + 1.6 * out)
                    .opacity(0.45 * (1 - out))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Finished journeys: grey and faded, like a disabled control. Flattened
    /// first so the card's layers don't show through each other.
    func completeStyle(_ complete: Bool = true) -> some View {
        compositingGroup()
            .saturation(complete ? 0 : 1)
            .opacity(complete ? 0.5 : 1)
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

/// Grey box with the departure time: amber when late, struck through in red
/// when cancelled. Before the train leaves, how busy it is goes under the time
/// (the row beside it has no room left once the countdown starts).
struct TimeBox: View {
    let time: String
    var tone: JourneyCardModel.Tone = .normal
    var busy: LoadingLevel?

    var body: some View {
        VStack(spacing: 2) {
            Text(time)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(tone == .normal ? AnyShapeStyle(.primary) : tone.style)
                .strikethrough(tone == .cancelled)
            if let busy {
                BusyBadge(level: busy)
            }
        }
        .padding(.vertical, busy == nil ? 0 : 6)
        .frame(minWidth: 74, minHeight: 50)
        .padding(.horizontal, 10)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// "Platform 4" as a small capsule: teal with a tick when Darwin has
/// confirmed it, grey while it's only predicted (from the timetable, or live
/// but not yet confirmed).
struct PlatformBadge: View {
    let number: String
    var confirmed = false

    var body: some View {
        HStack(spacing: 4) {
            if confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
            }
            Text("Platform \(number)")
        }
        .lineLimit(1)
        .fixedSize()
        .font(.footnote.weight(.semibold))
        .foregroundStyle(confirmed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(confirmed ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Platform \(number)\(Self.note(confirmed: confirmed))")
    }

    static func note(confirmed: Bool) -> String { confirmed ? ", confirmed" : ", predicted" }
}

/// How busy the train is at my station, under the departure time: one to
/// three people and "Some seats", amber when busy.
struct BusyBadge: View {
    let level: LoadingLevel

    var body: some View {
        if let text = level.text {
            HStack(spacing: 3) {
                Image(systemName: level.symbol)
                    .imageScale(.small)
                Text(text)
            }
            .lineLimit(1)
            .fixedSize()
            .font(.caption2.weight(.semibold))
            .foregroundStyle(level.tone == .normal ? AnyShapeStyle(.secondary) : level.tone.style)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("busyBadge")
        }
    }
}

/// The line between origin and destination: grey with end dots, filled in teal
/// up to `progress` once the train is under way; both dots teal when it's arrived.
/// Solid colours, so the dots and the line don't show through each other.
struct RouteLine: View {
    var progress: Double?
    /// Solid teal flowing through a lighter copy of the fill while under way.
    var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let dot: CGFloat = 9
            let inset = dot / 2
            let width = max(0, geo.size.width - dot)
            let fill = CGFloat(min(max(progress ?? 0, 0), 1)) * width
            let arrived = (progress ?? 0) >= 1
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Self.track)
                    .frame(height: 4)
                    .padding(.horizontal, inset)
                if pulsing, !reduceMotion, let progress, progress > 0, progress < 1 {
                    // Two layers: a light "shadow" of the fill, with solid teal flowing through it.
                    FlowingFill(width: fill)
                        .frame(width: fill, height: 4, alignment: .leading)
                        .padding(.leading, inset)
                } else if progress != nil {
                    Capsule()
                        .fill(.tint)
                        .frame(width: fill, height: 4)
                        .padding(.leading, inset)
                }
                Circle()
                    .fill(progress != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(Self.track))
                    .frame(width: dot, height: dot)
                Circle()
                    .fill(arrived ? AnyShapeStyle(.tint) : AnyShapeStyle(Self.track))
                    .frame(width: dot, height: dot)
                    .offset(x: width)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    /// The under-way fill's motion curve (see FlowingFill).
    static func fastThenSlow(_ x: Double) -> Double { FlowingFill.fastThenSlow(x) }

    /// Opaque greys matching the old translucent systemFill over a card.
    static let track = Color(light: Color(.systemGray5), dark: Color(.systemGray4))
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
