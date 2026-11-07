import SwiftUI

/// Between the journey card and the stops: where the train divides, how busy
/// it is at my station (until it leaves), major station messages, then the
/// notes (the server's messages and the other station messages). Each is its
/// own panel in the screen's stack.
struct JourneyNotices: View {
    let journey: Journey
    let status: LiveStatus?
    /// The server's message, delay and cancel reasons, a failed refresh.
    var notes: [String] = []
    var stationMessages: [StationMessage] = []

    var body: some View {
        let from = (crs: journey.from.crs, name: journey.from.name)
        let to = (crs: journey.to.crs, name: journey.to.name)
        if let division = status?.divides {
            DivisionBanner(division: division)
        }
        if let loading = BusyDisplay.loading(status: status, summary: journey.live) {
            BusyPanel(loading: loading, station: journey.from.name)
        }
        ForEach(stationMessages.filter(\.isProminent)) { message in
            StationMessageRow(message: message, stations: message.stationsText(from: from, to: to))
                .panel(border: AnyShapeStyle(message.severity == .severe ? Color.red : Color.orange))
        }
        let others = stationMessages.filter { !$0.isProminent }
        if !notes.isEmpty || !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes, id: \.self) { Text($0) }
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(Array(others.enumerated()), id: \.element.id) { index, message in
                    if index > 0 || !notes.isEmpty { Divider() }
                    StationMessageRow(message: message, stations: message.stationsText(from: from, to: to))
                }
            }
            .font(.subheadline)
            .panel()
        }
    }
}

/// "Divides at Horsham": the server's message, then each part's destination,
/// mine marked, with which coaches when Darwin says.
struct DivisionBanner: View {
    let division: TrainDivision

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(division.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(RailTime.hhmm(division.at))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(division.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(division.portions.enumerated()), id: \.offset) { _, portion in
                    PortionRow(portion: portion)
                }
            }
            .padding(.leading, 28)
        }
        .panel(border: AnyShapeStyle(.tint))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(division.accessibilityText)
        .accessibilityIdentifier("divisionBanner")
    }
}

/// One part of the train after the division: where it goes, and whether it's mine.
private struct PortionRow: View {
    let portion: DivisionPortion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: portion.yours ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(portion.yours ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(portion.destName)
                    .font(.subheadline.weight(portion.yours ? .semibold : .regular))
                if let note = portion.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if portion.yours {
                Text("Your part")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.tint.opacity(0.14), in: .capsule)
            }
        }
    }
}

/// How busy at my station: the level with a four-step gauge, the quietest
/// coaches, and each coach's loading front to rear when Darwin has it.
struct BusyPanel: View {
    let loading: TrainLoading
    let station: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: loading.level.symbol)
                    .foregroundStyle(loading.level.tone.style)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loading.level.text ?? "")
                        .font(.headline)
                    Text("How busy at \(station)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                BusyGauge(level: loading.level)
            }
            if let quietest = loading.quietestText {
                Text(quietest)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            if let coaches = loading.coaches, !coaches.isEmpty {
                CoachStrip(coaches: coaches, quietest: loading.quietestCoaches)
            }
        }
        .panel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(loading.accessibilityText)
        .accessibilityIdentifier("busyPanel")
    }
}

/// Four short bars, lit up to the level.
struct BusyGauge: View {
    let level: LoadingLevel

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...4, id: \.self) { step in
                Capsule()
                    .fill(step <= level.segments ? level.tone.style : AnyShapeStyle(RouteLine.track))
                    .frame(width: 12, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Each coach as a bar filled to its loading, front to rear, the quietest in teal.
struct CoachStrip: View {
    let coaches: [CoachLoad]
    let quietest: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(coaches.enumerated()), id: \.offset) { _, coach in
                    VStack(spacing: 3) {
                        GeometryReader { geo in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3).fill(RouteLine.track)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(fill(coach))
                                    .frame(height: max(2, geo.size.height * CGFloat(min(max(coach.percentage, 0), 100)) / 100))
                            }
                        }
                        .frame(height: 26)
                        Text(coach.number)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(quietest.contains(coach.number) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: 34)
                }
            }
            Text("Front of the train on the left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coaches front to rear: " + coaches.map { "\($0.number) \($0.percentage)%" + ($0.coachClass == "First" ? " first class" : "") }.joined(separator: ", "))
    }

    private func fill(_ coach: CoachLoad) -> AnyShapeStyle {
        if quietest.contains(coach.number) { return AnyShapeStyle(.tint) }
        if coach.percentage >= 85 { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Color.secondary.opacity(0.55))
    }
}

/// A station message: which of my stations, the text, and a link for more.
/// Major and severe ones are in their own outlined panel, in full colour.
struct StationMessageRow: View {
    let message: StationMessage
    let stations: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: message.symbol)
                .foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 4) {
                if let stations {
                    Text(stations)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(message.text)
                    .font(message.isProminent ? .subheadline.weight(.medium) : .subheadline)
                    .foregroundStyle(message.isProminent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if let link = message.link {
                    Link("More information", destination: link)
                        .font(.subheadline.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stationMessage")
    }

    private var tone: AnyShapeStyle {
        switch message.severity {
        case .severe: AnyShapeStyle(Color.red)
        case .major: AnyShapeStyle(Color.orange)
        case .minor, .normal: AnyShapeStyle(.secondary)
        }
    }
}

extension View {
    /// The journey screen's panel: grouped background, rounded, optionally outlined.
    func panel(border: AnyShapeStyle? = nil) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay {
                if let border {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(border.opacity(0.5), lineWidth: 1.5)
                }
            }
    }
}

#if DEBUG // preview data is Debug-only
#Preview {
    let journey = Journey.previewDividing()
    ScrollView {
        VStack(spacing: 16) {
            JourneyCard(journey: journey)
            JourneyNotices(journey: journey, status: .previewDividing(for: journey), notes: ["Delayed by a signalling problem"], stationMessages: StationMessage.previews)
        }
        .padding(16)
    }
    .background(Color(.systemGroupedBackground))
}
#endif
