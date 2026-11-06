import SwiftData
import SwiftUI

/// The "+" sheet: pick a date and stations, then tap a departure to save it.
/// Mirrors the web app's Add journey page; titled "Add train".
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
    /// Whether the trains that have already left are shown; they fold into one row by default.
    @State private var showDeparted = false
    /// The journey just saved: the confirmation shows it, with "Repeat on weekdays…".
    @State private var added: Journey?

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
                    DatePicker("Leaving after", selection: $after, displayedComponents: .hourAndMinute)
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
            .navigationTitle("Add train")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .task(id: key) {
                showDeparted = false
                await search()
            }
            .navigationDestination(isPresented: Binding(get: { added != nil }, set: { if !$0 { added = nil } })) {
                if let added {
                    AddedJourneyView(journey: added) { dismiss() }
                }
            }
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
            let left = departures.filter(hasLeft)
            if !left.isEmpty {
                departedToggle(count: left.count)
            }
            ForEach(departures.filter { showDeparted || !hasLeft($0) }) { d in
                row(d)
            }
            // Infinite scroll: reaching the bottom loads the next page. The id
            // gives each page a fresh row, so onAppear fires again while it stays on screen.
            if let cursor = response?.nextCursor {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .id(cursor)
                    .onAppear { Task { await search(appending: true) } }
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

    private func row(_ d: Departure) -> some View {
        Button {
            Task { await save(d) }
        } label: {
            DepartureRow(departure: d, departed: hasLeft(d), saved: isSaved(d), saving: savingID == d.id)
        }
        .tint(.primary)
        .disabled(savingID != nil || isSaved(d))
        .accessibilityIdentifier("departure")
    }

    /// A late train that hasn't left yet still counts as upcoming.
    private func hasLeft(_ d: Departure) -> Bool {
        d.live?.actualDeparture != nil || (d.live?.expectedDeparture ?? d.scheduledDeparture) < .now
    }

    /// "Show 3 departed trains" while folded, "Hide 3 departed trains" while expanded, like the
    /// folded stops on a journey's stop list.
    private func departedToggle(count: Int) -> some View {
        let trains = count == 1 ? "1 departed train" : "\(count) departed trains"
        return Button {
            withAnimation(.snappy) { showDeparted.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(showDeparted ? "Hide \(trains)" : "Show \(trains)")
                    .font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(showDeparted ? 180 : 0))
                Spacer()
            }
            .foregroundStyle(.tint)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("departedTrains")
    }

    private func search(appending: Bool = false) async {
        guard let from else {
            response = nil
            departures = []
            return
        }
        if appending && loading { return }
        let started = key
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
            // A new search started while this page loaded.
            if appending && key != started { return }
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

    /// Saves the journey on the server (which checks the train calls at both stations) and confirms it.
    private func save(_ d: Departure) async {
        guard let from else { return }
        savingID = d.id
        defer { savingID = nil }
        do {
            added = try await JourneySync.shared.save(trainUid: d.trainUid, runDate: d.runDate, fromCrs: from.crs, toCrs: to?.crs, in: context)
            // Now there's a train to be alerted about: ask (once) to allow notifications.
            Task { await PushNotifications.shared.requestAuthorization() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func startOfHour(_ date: Date) -> Date {
        RailTime.calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }
}

/// Add train's confirmation: the journey saved, and the offer to repeat it.
struct AddedJourneyView: View {
    let journey: Journey
    let done: () -> Void
    @State private var repeating = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                JourneyCard(journey: journey)
                if journey.templateId == nil {
                    Button("Repeat on weekdays…", systemImage: "repeat") { repeating = true }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .accessibilityIdentifier("repeatJourney")
                } else {
                    Label("Repeats. Change it in Settings › Regular journeys.", systemImage: "repeat")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Added")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark", action: done)
                    .accessibilityIdentifier("addedDone")
            }
        }
        .sheet(isPresented: $repeating) {
            RepeatJourneyView(journey: journey)
        }
    }
}

#Preview {
    AddJourneyView()
        .modelContainer(for: Journey.self, inMemory: true)
}
