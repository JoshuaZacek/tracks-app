import SwiftData
import SwiftUI

/// "Repeat on weekdays…": makes a journey a regular one. tracks then adds the
/// train nearest this time on each day chosen, the day before.
struct RepeatJourneyView: View {
    let journey: Journey
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var days = Weekdays.workdays
    @State private var travelMinutes: Int?
    @State private var summaryOn = false
    @State private var summaryTime: String
    @State private var saving = false
    @State private var error: String?

    init(journey: Journey) {
        self.journey = journey
        _travelMinutes = State(initialValue: journey.travelMinutes)
        _summaryTime = State(initialValue: ClockTime.defaultSummaryTime(departTime: RailTime.hhmm(journey.departsAt)))
    }

    private var departTime: String { RailTime.hhmm(journey.departsAt) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DaysPicker(days: $days)
                } header: {
                    Text("Days")
                } footer: {
                    Text("\(Weekdays.label(days)): tracks adds the \(departTime) from \(journey.from.name) the day before, or the train nearest that time.")
                }
                Section {
                    TravelTimeRow(minutes: $travelMinutes, station: journey.from.station, autoSuggest: true)
                } footer: {
                    Text("For a “Leave now” alert. Only the minutes are sent to tracks, not where you are.")
                }
                Section {
                    Toggle("Morning summary", isOn: $summaryOn)
                        .accessibilityIdentifier("morningSummary")
                    if summaryOn {
                        ClockTimePicker(title: "Send at", time: $summaryTime)
                    }
                } footer: {
                    Text("How your train's running, before you set off.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Repeat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Repeat", systemImage: "checkmark") {
                        Task { await save() }
                    }
                    .disabled(saving || days.isEmpty)
                    .accessibilityIdentifier("saveRepeat")
                }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await JourneySync.shared.repeatJourney(journey, days: days, travelMinutes: travelMinutes,
                                                       summaryTime: summaryOn ? summaryTime : nil, in: context)
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
