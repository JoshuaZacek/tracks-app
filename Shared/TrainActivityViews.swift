import SwiftUI

// The Live Activity's views, shared so the app can preview and test them
// and the widget extension can draw them. Kept free of app types: everything
// comes from TrainActivityAttributes.

extension Color {
    /// The app's teal (AccentColor), spelled out because the widget extension has its own assets.
    static let trainTeal = Color(light: Color(red: 0.067, green: 0.600, blue: 0.533), dark: Color(red: 0.157, green: 0.749, blue: 0.671))

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }
}

enum ActivityTime {
    /// 24-hour UK time, "09:47", whatever the phone's region and time zone.
    static func hhmm(_ date: Date) -> String {
        date.formatted(style)
    }

    private static let style = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: TimeZone(identifier: "Europe/London") ?? .current,
        calendar: Calendar(identifier: .gregorian)
    )
}

/// The Lock Screen (and banner) presentation.
struct TrainActivityLockScreenView: View {
    let attributes: TrainActivityAttributes
    let state: TrainActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "tram.fill")
                    .foregroundStyle(Color.trainTeal)
                Text("\(attributes.headcode) · \(attributes.operatorName)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ActivityStatusPill(state: state)
            }
            .font(.caption.weight(.semibold))

            HStack(alignment: .center, spacing: 12) {
                ActivityEnd(crs: attributes.fromCrs, time: state.departureTime, late: state.isLate && !state.departed, cancelled: state.cancelled, alignment: .leading)
                ActivityMiddle(state: state)
                ActivityEnd(crs: attributes.toCrs, time: state.arrivalTime, late: state.isLate && state.departed, cancelled: state.cancelled, alignment: .trailing)
            }

            ActivityFooter(attributes: attributes, state: state, isStale: isStale)
        }
        .padding(16)
    }
}

/// "On time", "5 min late", "Cancelled": teal, amber or red.
struct ActivityStatusPill: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        Text(state.statusText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tone.opacity(0.16), in: .capsule)
    }

    private var tone: Color {
        if state.cancelled { return .red }
        if state.isLate { return .orange }
        if state.state == .notFound { return .secondary }
        return .trainTeal
    }
}

/// A station code with its best known time.
struct ActivityEnd: View {
    let crs: String
    let time: Date
    var late = false
    var cancelled = false
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(crs)
                .font(.title2.weight(.bold))
            Text(ActivityTime.hhmm(time))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(cancelled ? AnyShapeStyle(Color.red) : late ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .strikethrough(cancelled)
        }
    }
}

/// Between the station codes: a countdown before departure, then the journey's progress.
struct ActivityMiddle: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.cancelled || state.state == .notFound {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
            } else if state.state == .arrived {
                Capsule().fill(Color.trainTeal).frame(height: 4)
            } else if state.departed {
                // Moves on by itself between pushes.
                ProgressView(timerInterval: state.departureTime...max(state.arrivalTime, state.departureTime.addingTimeInterval(60)), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(.trainTeal)
            } else {
                VStack(spacing: 2) {
                    Text("Leaves in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(timerInterval: Date.now...max(Date.now, state.departureTime), countsDown: true)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The line under the route: platform, then what went wrong, where the train
/// divides, the next stop or arrival.
struct ActivityFooter: View {
    let attributes: TrainActivityAttributes
    let state: TrainActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        HStack(spacing: 8) {
            if let platform = state.platform, !state.cancelled {
                ActivityPlatform(platform: platform)
            }
            detail
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if state.cancelled {
            Text(state.message ?? "This train has been cancelled.")
        } else if isStale {
            Label("Waiting for an update", systemImage: "clock.badge.exclamationmark")
        } else if state.state == .arrived {
            Text("Arrived at \(attributes.toName) \(ActivityTime.hhmm(state.arrivalTime))")
        } else if let message = state.message {
            Text(message)
        } else if let divides = state.divides {
            // Until the train leaves the division station (the server clears it
            // then). Two lines at most, so "· front 4 coaches" isn't cut off.
            Text("\(Image(systemName: "arrow.triangle.branch")) \(divides)")
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(divides)
                .accessibilityIdentifier("activityDivides")
        } else if state.departed, let next = state.nextStopName, let due = state.nextExpectedAt {
            Text("Next: \(next) \(ActivityTime.hhmm(due))")
        } else if state.departed {
            Text("To \(attributes.toName)")
        } else {
            Text("From \(attributes.fromName)")
        }
    }
}

/// "Platform 7": teal with a tick once confirmed, grey while predicted.
struct ActivityPlatform: View {
    let platform: TrainActivityAttributes.ContentState.Platform

    var body: some View {
        HStack(spacing: 3) {
            if platform.confirmed {
                Image(systemName: "checkmark.circle.fill").imageScale(.small)
            }
            Text("Platform \(platform.number)")
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(tone)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.opacity(0.16), in: .capsule)
        .accessibilityLabel("Platform \(platform.number)\(platform.confirmed ? ", confirmed" : ", predicted")")
    }

    private var tone: Color { platform.confirmed ? .trainTeal : .secondary }
}

// MARK: - Dynamic Island pieces

/// Compact trailing: the next time that matters (departure, then arrival).
struct ActivityCompactTime: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        Text(ActivityTime.hhmm(state.departed ? state.arrivalTime : state.departureTime))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(state.cancelled ? Color.red : state.isLate ? .orange : .trainTeal)
            .strikethrough(state.cancelled)
    }
}

/// Compact leading and minimal: the train.
struct ActivityTrainIcon: View {
    let state: TrainActivityAttributes.ContentState

    var body: some View {
        Image(systemName: state.cancelled ? "xmark.circle.fill" : "tram.fill")
            .foregroundStyle(state.cancelled ? Color.red : .trainTeal)
    }
}

#Preview("Lock Screen", traits: .sizeThatFitsLayout) {
    let attributes = TrainActivityAttributes(journeyId: UUID(), headcode: "1H03", operatorName: "LNER", fromCrs: "KGX", fromName: "London Kings Cross", toCrs: "GRA", toName: "Grantham")
    let now = Date.now
    VStack(spacing: 12) {
        TrainActivityLockScreenView(attributes: attributes, state: .init(
            state: .live, scheduledDeparture: now.addingTimeInterval(20 * 60), expectedDeparture: now.addingTimeInterval(25 * 60),
            scheduledArrival: now.addingTimeInterval(80 * 60), delayMinutes: 5, platform: .init(number: "7", confirmed: true)
        ))
        TrainActivityLockScreenView(attributes: attributes, state: .init(
            state: .departed, scheduledDeparture: now.addingTimeInterval(-20 * 60), actualDeparture: now.addingTimeInterval(-20 * 60),
            scheduledArrival: now.addingTimeInterval(40 * 60), platform: .init(number: "1", confirmed: false),
            nextStopName: "Peterborough", legDepartedAt: now.addingTimeInterval(-20 * 60), nextExpectedAt: now.addingTimeInterval(15 * 60)
        ))
        TrainActivityLockScreenView(attributes: attributes, state: .init(
            state: .live, scheduledDeparture: now.addingTimeInterval(20 * 60), scheduledArrival: now.addingTimeInterval(80 * 60),
            platform: .init(number: "15", confirmed: true), divides: "Divides at Horsham · front 4 coaches"
        ))
    }
    .background(Color(.secondarySystemBackground))
}
