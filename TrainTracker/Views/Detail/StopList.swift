import SwiftUI

/// One stop on my journey with its live times.
struct StopRow: Identifiable, Equatable {
    var id: Int
    var name: String
    /// Best known time: actual, else expected, else scheduled.
    var time: String
    /// The timetabled time, when the best known time differs from it.
    var scheduled: String?
    var late: Bool
    var passed: Bool
    var cancelled: Bool
    var platform: String?
    var platformConfirmed: Bool
    /// Known to Darwin, not yet announced at the station.
    var platformHidden = false
    var isEnd: Bool

    /// My stops (boarding to alighting) from the train's calling points, with live data where Darwin has it.
    static func rows(for journey: Journey, liveCallingPoints cps: [CallingPoint], now: Date) -> [StopRow] {
        let from = journey.fromIndex
        let to = journey.toIndex
        guard cps.indices.contains(from), cps.indices.contains(to), from <= to else { return [] }
        var rows = (from...to).map { i in
            let cp = cps[i]
            let live = cp.live
            // Boarding: departure; destination: arrival; others: arrival if known, else departure.
            let scheduledTime = i == from ? cp.scheduledDeparture : (cp.scheduledArrival ?? cp.scheduledDeparture)
            let actual = i == from ? live?.actualDeparture : (live?.actualArrival ?? live?.actualDeparture)
            let expected = i == from ? live?.expectedDeparture : (live?.expectedArrival ?? live?.expectedDeparture)
            let best = actual ?? expected ?? scheduledTime
            let bestText = best.map(RailTime.hhmm) ?? "--:--"
            let scheduledText = scheduledTime.map(RailTime.hhmm)
            return StopRow(
                id: i,
                name: cp.name,
                time: bestText,
                scheduled: scheduledText != bestText ? scheduledText : nil,
                late: (best ?? .distantPast) > (scheduledTime ?? .distantFuture).addingTimeInterval(59),
                // Reached: the train has arrived (or left, or passed through).
                passed: live?.actualDeparture != nil || live?.actualArrival != nil,
                cancelled: live?.isCancelled ?? false,
                platform: live?.platform?.number ?? cp.bookedPlatform,
                platformConfirmed: live?.platform?.confirmed ?? false,
                platformHidden: live?.platform?.hidden ?? false,
                isEnd: i == from || i == to
            )
        }
        // A stop with no report of its own (e.g. it fell in a gap in the live feed)
        // has still been passed if the train has been reported at a later one.
        if let last = rows.lastIndex(where: \.passed) {
            for i in 0..<last { rows[i].passed = true }
        }
        return rows
    }
}

/// The stops down a track line: grey, filled in teal from my station to where
/// the train is now (by time between the last stop it reached and the next),
/// with the train on the line and, beside it, where it is ("Near Huntingdon"),
/// its last report and the next stop.
struct StopList: View {
    struct Indicator: Equatable {
        var place: String
        var report: String
        var next: String?
    }

    let rows: [StopRow]
    let indicator: Indicator?
    /// 0...1 from the last stop reached to the next, while the train is between them.
    var trainFraction: Double?

    private static let dot: CGFloat = 15
    private static let lineWidth: CGFloat = 3

    var body: some View {
        let lastPassed = rows.lastIndex { $0.passed }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                stop(row)
                if let indicator, index == lastPassed, index < rows.count - 1 {
                    indicatorRow(indicator)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        // The track behind the dots, and the train on it.
        .backgroundPreferenceValue(DotCenters.self) { centers in
            GeometryReader { geo in track(centers.mapValues { geo[$0] }, lastPassed: lastPassed) }
        }
        .overlayPreferenceValue(DotCenters.self) { centers in
            GeometryReader { geo in train(centers.mapValues { geo[$0] }, lastPassed: lastPassed) }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
    }

    // MARK: Track

    /// How far down the track the teal reaches: the train's position between
    /// the last stop it reached and the next, or the last stop reached.
    private func fillY(_ centers: [Int: CGPoint], lastPassed: Int?) -> CGFloat? {
        guard let lastPassed, let reached = centers[rows[lastPassed].id] else { return nil }
        guard lastPassed < rows.count - 1, let next = centers[rows[lastPassed + 1].id], let f = trainFraction else {
            return reached.y
        }
        return reached.y + (next.y - reached.y) * CGFloat(min(max(f, 0), 1))
    }

    private func track(_ centers: [Int: CGPoint], lastPassed: Int?) -> some View {
        let points = rows.compactMap { centers[$0.id] }
        return ZStack(alignment: .topLeading) {
            if let first = points.first, let last = points.last {
                segment(x: first.x, from: first.y, to: last.y).fill(RouteLine.track)
                if let y = fillY(centers, lastPassed: lastPassed) {
                    segment(x: first.x, from: first.y, to: y).fill(.tint)
                }
            }
        }
    }

    private func segment(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Path {
        Path(CGRect(x: x - Self.lineWidth / 2, y: top, width: Self.lineWidth, height: max(0, bottom - top)))
    }

    @ViewBuilder
    private func train(_ centers: [Int: CGPoint], lastPassed: Int?) -> some View {
        if indicator != nil, trainFraction != nil, let lastPassed, lastPassed < rows.count - 1,
           let x = rows.first.flatMap({ centers[$0.id]?.x }), let y = fillY(centers, lastPassed: lastPassed) {
            Image(systemName: "tram.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.tint, in: .circle)
                .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                .position(x: x, y: y)
                .accessibilityHidden(true)
        }
    }

    // MARK: Rows

    private func stop(_ row: StopRow) -> some View {
        HStack(spacing: 12) {
            // Grey until the train reaches it; ends are rings.
            Circle()
                .fill(row.passed ? AnyShapeStyle(.tint) : AnyShapeStyle(row.isEnd ? Color(.secondarySystemGroupedBackground) : RouteLine.track))
                .stroke(row.cancelled ? AnyShapeStyle(Color.red) : row.passed ? AnyShapeStyle(.tint) : AnyShapeStyle(RouteLine.track), lineWidth: row.isEnd ? 4 : 0)
                .frame(width: row.isEnd ? Self.dot : 11, height: row.isEnd ? Self.dot : 11)
                .frame(width: Self.dot)
                .anchorPreference(key: DotCenters.self, value: .center) { [row.id: $0] }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(row.isEnd ? .body.weight(.semibold) : .body)
                    .strikethrough(row.cancelled)
                if row.cancelled {
                    Text("Cancelled").font(.footnote).foregroundStyle(.red)
                } else if let platform = row.platform {
                    Text("Platform \(platform)\(row.platformHidden ? " · not yet announced" : row.platformConfirmed ? " · confirmed" : "")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(row.passed ? .secondary : .primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.time)
                    .font(.body.monospaced().weight(row.isEnd ? .semibold : .regular))
                    .foregroundStyle(row.late && !row.cancelled ? AnyShapeStyle(Color.orange) : row.passed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let scheduled = row.scheduled {
                    Text(scheduled)
                        .font(.caption.monospaced())
                        .strikethrough()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// Beside the track (the train itself is drawn on it).
    private func indicatorRow(_ indicator: Indicator) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: Self.dot, height: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(indicator.place).font(.subheadline.weight(.semibold))
                if let next = indicator.next {
                    Text(next).font(.footnote).foregroundStyle(.tint)
                }
                Text(indicator.report).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trainIndicator")
    }
}

/// Where each stop's dot is, by row id, for drawing the track through them.
private struct DotCenters: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGPoint>] = [:]
    static func reduce(value: inout [Int: Anchor<CGPoint>], nextValue: () -> [Int: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}
