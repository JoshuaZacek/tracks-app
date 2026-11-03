import SwiftData
import SwiftUI

/// The "+" sheet: pick a date and stations, then tap a departure to save it.
/// Mirrors the web app's Add journey page.
struct AddJourneyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var saved: [Journey]

    @State private var date = Date.now
    @State private var after = AddJourneyView.startOfHour(.now)
    @State private var from: Station?
    @State private var to: Station?
    @State private var response: DeparturesResponse?  // the last page loaded
    @State private var departures: [Departure] = []
    @State private var loading = false
    @State private var error: String?
    @State private var savingID: String?

    /// Everything a search depends on; a change re-runs it.
    private struct SearchKey: Equatable {
        var date: String
        var after: String
        var from: String?
        var to: String?
    }

    private var key: SearchKey {
        SearchKey(date: RailTime.ymd(date), after: RailTime.hhmm(after), from: from?.crs, to: to?.crs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $date, in: RailTime.calendar.startOfDay(for: .now)..., displayedComponents: .date)
                    DatePicker("From time", selection: $after, displayedComponents: .hourAndMinute)
                    NavigationLink {
                        StationPicker(title: "From", selection: $from)
                    } label: {
                        LabeledContent("From", value: from.map { "\($0.name) (\($0.crs))" } ?? "Choose a station")
                    }
                    .accessibilityIdentifier("fromStation")
                    NavigationLink {
                        StationPicker(title: "To", selection: $to, allowsAny: true)
                    } label: {
                        LabeledContent("To", value: to.map { "\($0.name) (\($0.crs))" } ?? "Any")
                    }
                    .accessibilityIdentifier("toStation")
                }
                // Timetable times are UK times on a 24-hour clock, whatever the phone's settings.
                .environment(\.timeZone, RailTime.zone)
                .environment(\.locale, Locale(identifier: "en_GB"))

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                if from != nil {
                    departuresSection
                }
            }
            .navigationTitle("Add journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: key) { await search() }
            .onChange(of: RailTime.ymd(date)) { _, newDate in
                // Today starts around now; a future day starts at midnight.
                after = newDate == RailTime.ymd(.now) ? Self.startOfHour(.now) : RailTime.calendar.startOfDay(for: date)
            }
        }
    }

    private var departuresSection: some View {
        Section {
            if departures.isEmpty && !loading {
                Text("No passenger trains found. Try an earlier time or another date.")
                    .foregroundStyle(.secondary)
            }
            ForEach(departures) { d in
                Button {
                    Task { await save(d) }
                } label: {
                    DepartureRow(
                        departure: d,
                        // A late train that hasn't left yet isn't dimmed.
                        departed: d.live?.actualDeparture != nil || (d.live?.expectedDeparture ?? d.scheduledDeparture) < .now,
                        saved: isSaved(d),
                        saving: savingID == d.id
                    )
                }
                .tint(.primary)
                .disabled(savingID != nil || isSaved(d))
                .accessibilityIdentifier("departure")
            }
            if response?.nextCursor != nil {
                Button("Later trains") { Task { await search(appending: true) } }
                    .disabled(loading)
            }
        } header: {
            HStack {
                if let response {
                    Text(response.to.map { "Calling at \($0.name)" } ?? "Departures from \(response.from.name)")
                }
                if loading {
                    Spacer()
                    ProgressView()
                }
            }
        }
    }

    private func search(appending: Bool = false) async {
        guard let from else {
            response = nil
            departures = []
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let r = try await TracksClient.shared.departures(
                from: from.crs,
                date: key.date,
                to: to?.crs,
                after: key.after,
                cursor: appending ? response?.nextCursor : nil
            )
            response = r
            if appending {
                let seen = Set(departures.map(\.id))
                departures += r.departures.filter { !seen.contains($0.id) }
            } else {
                departures = r.departures
            }
        } catch is CancellationError {
            // A newer search replaced this one.
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }

    private func isSaved(_ d: Departure) -> Bool {
        saved.contains { $0.trainUid == d.trainUid && $0.runDate == d.runDate && $0.from.crs == from?.crs }
    }

    /// Saves the journey on the server (which checks the train calls at both stations) and closes the sheet.
    private func save(_ d: Departure) async {
        guard let from else { return }
        savingID = d.id
        defer { savingID = nil }
        do {
            try await JourneySync.shared.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: from.crs, toCrs: to?.crs, in: context)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func startOfHour(_ date: Date) -> Date {
        RailTime.calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }
}

#Preview {
    AddJourneyView()
        .modelContainer(for: Journey.self, inMemory: true)
}
