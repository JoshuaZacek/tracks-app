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
                passed: live?.actualDeparture != nil || (i == to && live?.actualArrival != nil),
                cancelled: live?.isCancelled ?? false,
                platform: live?.platform?.number ?? cp.bookedPlatform,
                platformConfirmed: live?.platform?.confirmed ?? false,
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

/// The stops down a track line, with the train between the last stop passed
/// and the next: where it is ("Near Huntingdon"), its last report and the next stop.
struct StopList: View {
    struct Indicator: Equatable {
        var place: String
        var report: String
        var next: String?
    }

    let rows: [StopRow]
    let indicator: Indicator?

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
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24, style: .continuous))
        .background(alignment: .leading) {
            // The track down the left.
            Rectangle()
                .fill(Color(.systemFill))
                .frame(width: 3)
                .padding(.vertical, 30)
                .padding(.leading, 14 + 6)
        }
    }

    private func stop(_ row: StopRow) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(row.passed ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)))
                .stroke(row.cancelled ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint), lineWidth: row.isEnd ? 4 : 2)
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(row.isEnd ? .body.weight(.semibold) : .body)
                    .strikethrough(row.cancelled)
                if row.cancelled {
                    Text("Cancelled").font(.footnote).foregroundStyle(.red)
                } else if let platform = row.platform {
                    Text("Platform \(platform)\(row.platformConfirmed ? " · confirmed" : "")")
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

    private func indicatorRow(_ indicator: Indicator) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tram.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.tint, in: .circle)
                .offset(x: -3.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(indicator.place).font(.subheadline.weight(.semibold))
                if let next = indicator.next {
                    Text(next).font(.footnote).foregroundStyle(.tint)
                }
                Text(indicator.report).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trainIndicator")
    }
}
